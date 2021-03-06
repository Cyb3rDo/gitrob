require "sinatra/base"
require "thin"

module Gitrob
  class WebApp < Sinatra::Base
    CONTENT_SECURITY_POLICY = "default-src *; script-src 'self'; " \
                              "style-src 'self' 'unsafe-inline'; " \
                              "font-src 'self'; connect-src 'self'"

    set :server, :thin
    set :environment, :production
    set :logging, false
    set :sessions, true
    set :app_file, __FILE__
    set :root, File.expand_path("#{File.dirname(__FILE__)}/../../")
    set :public_folder, proc { File.join(root, "public") }
    set :views, proc { File.join(root, "views") }
    set :run, proc { false }

    helpers do
      HUMAN_PREFIXES = %w(TB GB MB KB B).freeze

      alias_method :h, :escape_html

      def number_to_human_size(number)
        s = number.to_f
        i = HUMAN_PREFIXES.length - 1
        while s > 512 && i > 0
          i -= 1
          s /= 1024
        end
        ((s > 9 || s.modulo(1) < 0.1 ? "%d" : "%.1f") % s) + "<strong>#{HUMAN_PREFIXES[i]}</strong>" # rubocop:disable Metrics/LineLength
      end

      def format_path(path)
        dirname  = File.dirname(path)
        basename = File.basename(path)
        if dirname == "."
          "<strong>#{h basename}</strong>"
        else
          "#{h ellipsisize(dirname, 60, 25)}/<strong>#{h basename}</strong>"
        end
      end

      def ellipsisize(string, minimum_length=4, edge_length=3)
        return string if string.length < minimum_length || string.length <= edge_length * 2 # rubocop:disable Metrics/LineLength
        edge = "." * edge_length
        mid_length = string.length - edge_length * 2
        string.gsub(/(#{edge}).{#{mid_length},}(#{edge})/, '\1...\2')
      end

      def format_url(url)
        return url if url.start_with?("http")
        "http://#{url}"
      end

      def protect_from_request_forgery!
        session[:csrf] ||= SecureRandom.hex(32)
        halt(403, "CSRF attack prevented") if csrf_attack?
      end

      def csrf_token_from_request
        csrf_token = env["HTTP_X_CSRF_TOKEN"] || params["_csrf"]
        halt(403, "CSRF token not present in request") if csrf_token.to_s.empty?
        csrf_token
      end

      def csrf_attack?
        !request.safe? && csrf_token_from_request != session[:csrf]
      end

      def find_assessment(id)
        Gitrob::Models::Assessment.first(
          :id       => id.to_i,
          :finished => true,
          :deleted  => false
        ) || halt(404)
      end

      def find_comparison(id)
        Gitrob::Models::Comparison.first(
          :id       => id.to_i,
          :finished => true,
          :deleted  => false
        ) || halt(404)
      end
    end

    before do
      response.headers["Content-Security-Policy"] = CONTENT_SECURITY_POLICY
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["X-XSS-Protection"] = "1; mode=block"
      response.headers["X-Frame-Options"] = "deny"
      protect_from_request_forgery!
    end

    get "/" do
      @assessments =
        Gitrob::Models::Assessment
        .where(:deleted => false)
        .order(:created_at)
        .reverse.all
      erb :index
    end

    get "/assessments/_table" do
      @assessments =
        Gitrob::Models::Assessment
        .where(:deleted => false)
        .order(:created_at)
        .reverse.all
      erb :"assessments/_assessments", :layout => false
    end

    post "/assessments" do
      if params[:assessment][:verify_ssl]
        verify_ssl = true
      else
        verify_ssl = false
      end
      options = {
        :endpoint      => params[:assessment][:endpoint],
        :site          => params[:assessment][:site],
        :verify_ssl    => verify_ssl,
        :access_tokens => params[:assessment][:github_access_tokens]
      }

      Gitrob::Jobs::Assessment.perform_async(
        params[:assessment][:targets],
        options
      )
      status 202 # Accepted
    end

    get "/assessments/:id" do
      redirect "/assessments/#{params[:id].to_i}/findings"
    end

    delete "/assessments/:id" do
      @assessment = Gitrob::Models::Assessment.first(
        :id       => params[:id].to_i,
        :deleted  => false
      ) || halt(404)
      @assessment.deleted = true
      @assessment.save
      @assessment.destroy
    end

    get "/assessments/:id/findings" do
      @assessment = find_assessment(params[:id])
      @findings = @assessment.blobs_dataset.where("flags_count != 0")
        .order(:path).eager(:repository, :flags).all
      erb :"assessments/findings"
    end

    get "/assessments/:id/users" do
      @assessment = find_assessment(params[:id])
      @owners = @assessment.owners_dataset.order(:type)
      erb :"assessments/users"
    end

    get "/assessments/:id/repositories" do
      @assessment = find_assessment(params[:id])
      @repositories = @assessment.repositories_dataset.order(:full_name).all
      erb :"assessments/repositories"
    end

    get "/assessments/:id/compare" do
      @assessment = find_assessment(params[:id])
      @primary_comparisons = @assessment.primary_comparisons_dataset
                                        .order(:created_at)
                                        .reverse.all
      @secondary_comparisons = @assessment.secondary_comparisons_dataset
                                          .order(:created_at)
                                          .reverse.all
      @assessments = @assessment.comparable_assessments
      erb :"assessments/compare"
    end

    get "/assessments/:id/compare/_comparables" do
      @assessment = find_assessment(params[:id])
      @assessments = @assessment.comparable_assessments
      erb :"assessments/_comparable_assessments", :layout => false
    end

    get "/assessments/:id/compare/_comparisons" do
      @assessment = find_assessment(params[:id])
      @primary_comparisons = @assessment.primary_comparisons_dataset
                                        .order(:created_at)
                                        .reverse.all
      @secondary_comparisons = @assessment.secondary_comparisons_dataset
                                          .order(:created_at)
                                          .reverse.all
      erb :"assessments/_comparisons", :layout => false
    end

    get "/users/:id" do
      @owner = Gitrob::Models::Owner.first(:id => params[:id].to_i) || halt(404)
      @assessment = @owner.assessment
      @repositories = @owner.repositories_dataset.order(:name).all
      erb :"users/show", :layout => !request.xhr?
    end

    get "/repositories/:id" do
      @repository = Gitrob::Models::Repository.first(
        :id => params[:id].to_i
      ) || halt(404)
      @assessment = @repository.assessment
      @blobs = @repository.blobs_dataset.order(:path).eager(:flags).all
      erb :"repositories/show"
    end

    get "/blobs/:id" do
      @blob = Gitrob::Models::Blob.first(:id => params[:id].to_i) || halt(404)
      @assessment = @blob.assessment

      if !@blob.large?
        client_manager = Gitrob::Github::ClientManager.new(
          :endpoint      => @assessment.endpoint,
          :site          => @assessment.site,
          :ssl           => {
            :verify => @assessment.verify_ssl
          },
          :access_tokens => @assessment.github_access_tokens.map(&:token)
        )
        @content = Base64.decode64(
          client_manager.sample.repos.contents.get(
            @blob.repository.owner.login,
            @blob.repository.name,
            @blob.path).content
        )
      else
        @content = nil
      end

      erb :"blobs/show", :layout => false
    end

    post "/comparisons" do
      @assessment = find_assessment(params[:assessment_id])
      @other_assessment = find_assessment(params[:other_assessment_id])

      if @assessment.created_at > @other_assessment.created_at
        Gitrob::Jobs::Comparison.perform_async(
          @assessment, @other_assessment)
      else
        Gitrob::Jobs::Comparison.perform_async(
          @other_assessment, @assessment)
      end
      status 202 # Accepted
    end

    get "/comparisons/:id" do
      @comparison = find_comparison(params[:id])
      @blobs = @comparison.blobs_dataset.order(:path)
                          .eager(:flags, :repository).all
      @repositories = @comparison.repositories_dataset.order(:full_name).all
      @owners = @comparison.owners_dataset.order(:type).all
      erb :"comparisons/show"
    end

    delete "/comparisons/:id" do
      @comparison = Gitrob::Models::Comparison.first(
        :id       => params[:id].to_i,
        :deleted  => false
      ) || halt(404)
      @comparison.deleted = true
      @comparison.save
      @comparison.destroy
    end

    not_found do
      status 404
      erb :"errors/not_found"
    end

    error do
      status 500
      @error = env["sinatra.error"]
      @error_details = JSON.pretty_generate(
        :error => @error.class.to_s,
        :message => @error.message,
        :backtrace => @error.backtrace,
        :request_method => env["REQUEST_METHOD"],
        :request_path => env["REQUEST_PATH"],
        :referer => env["HTTP_REFERER"],
        :gitrob_version => Gitrob::VERSION
      )
      erb :"errors/internal_server_error"
    end
  end
end
