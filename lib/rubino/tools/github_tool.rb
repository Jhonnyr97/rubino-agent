# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Rubino
  module Tools
    # Tool for GitHub/GitLab operations: PRs, issues, reviews.
    # Uses GitHub CLI (gh) if available, otherwise uses the API directly.
    class GitHubTool < Base
      def name
        "github"
      end

      def description
        "Interact with GitHub: create/list PRs, issues, reviews, check status. " \
        "Requires GITHUB_TOKEN or gh CLI authenticated."
      end

      def input_schema
        {
          type: "object",
          properties: {
            action: {
              type: "string",
              enum: %w[pr_create pr_list pr_view issue_create issue_list issue_view
                       pr_checks pr_diff repo_view release_list],
              description: "The GitHub action to perform"
            },
            title: {
              type: "string",
              description: "Title (for pr_create, issue_create)"
            },
            body: {
              type: "string",
              description: "Body/description (for pr_create, issue_create)"
            },
            number: {
              type: "integer",
              description: "PR or issue number (for view/checks/diff)"
            },
            repo: {
              type: "string",
              description: "Repository in owner/name format (optional, auto-detects from git remote)"
            },
            base: {
              type: "string",
              description: "Base branch for PR (default: main)"
            },
            labels: {
              type: "string",
              description: "Comma-separated labels"
            }
          },
          required: %w[action]
        }
      end

      def risk_level
        :medium
      end

      def call(arguments)
        action = arguments["action"] || arguments[:action]

        if gh_available?
          execute_gh(action, arguments)
        else
          execute_api(action, arguments)
        end
      end

      private

      def gh_available?
        # Memoized — avoid spawning a subprocess on every call()
        return @gh_available unless @gh_available.nil?

        @gh_available = system("which gh > /dev/null 2>&1")
      end

      def execute_gh(action, args)
        case action
        when "pr_create"
          title = args["title"] || args[:title] || "New PR"
          body = args["body"] || args[:body] || ""
          base = args["base"] || args[:base] || "main"
          cmd = "gh pr create --title '#{escape(title)}' --body '#{escape(body)}' --base '#{base}'"
          run_gh(cmd)
        when "pr_list"
          run_gh("gh pr list --limit 20")
        when "pr_view"
          number = args["number"] || args[:number]
          run_gh("gh pr view #{number}")
        when "pr_checks"
          number = args["number"] || args[:number]
          run_gh("gh pr checks #{number}")
        when "pr_diff"
          number = args["number"] || args[:number]
          run_gh("gh pr diff #{number}")
        when "issue_create"
          title = args["title"] || args[:title] || "New Issue"
          body = args["body"] || args[:body] || ""
          labels = args["labels"] || args[:labels]
          cmd = "gh issue create --title '#{escape(title)}' --body '#{escape(body)}'"
          cmd += " --label '#{labels}'" if labels
          run_gh(cmd)
        when "issue_list"
          run_gh("gh issue list --limit 20")
        when "issue_view"
          number = args["number"] || args[:number]
          run_gh("gh issue view #{number}")
        when "repo_view"
          run_gh("gh repo view")
        when "release_list"
          run_gh("gh release list --limit 10")
        else
          "Unknown GitHub action: #{action}"
        end
      end

      def execute_api(action, args)
        token = ENV["GITHUB_TOKEN"] || ENV["GH_TOKEN"]
        unless token
          return "Error: No GitHub authentication. Set GITHUB_TOKEN or install gh CLI."
        end

        repo = args["repo"] || args[:repo] || detect_repo

        case action
        when "pr_list"
          api_get("/repos/#{repo}/pulls?state=open&per_page=20", token)
        when "pr_view"
          number = args["number"] || args[:number]
          api_get("/repos/#{repo}/pulls/#{number}", token)
        when "issue_list"
          api_get("/repos/#{repo}/issues?state=open&per_page=20", token)
        when "issue_view"
          number = args["number"] || args[:number]
          api_get("/repos/#{repo}/issues/#{number}", token)
        when "pr_create"
          title = args["title"] || args[:title]
          body_text = args["body"] || args[:body] || ""
          base = args["base"] || args[:base] || "main"
          head = current_branch
          api_post("/repos/#{repo}/pulls", token, {
            title: title, body: body_text, head: head, base: base
          })
        when "issue_create"
          title = args["title"] || args[:title]
          body_text = args["body"] || args[:body] || ""
          api_post("/repos/#{repo}/issues", token, {
            title: title, body: body_text
          })
        else
          "Action '#{action}' requires gh CLI"
        end
      end

      def run_gh(cmd)
        output = `#{cmd} 2>&1`
        output.empty? ? "(no output)" : output
      end

      def api_get(path, token)
        uri = URI("https://api.github.com#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        request = Net::HTTP::Get.new(uri.request_uri)
        request["Authorization"] = "Bearer #{token}"
        request["Accept"] = "application/vnd.github+json"

        response = http.request(request)
        format_api_response(response)
      end

      def api_post(path, token, body)
        uri = URI("https://api.github.com#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        request = Net::HTTP::Post.new(uri.request_uri)
        request["Authorization"] = "Bearer #{token}"
        request["Accept"] = "application/vnd.github+json"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)

        response = http.request(request)
        format_api_response(response)
      end

      def format_api_response(response)
        data = JSON.parse(response.body)
        case data
        when Array
          data.first(10).map { |item| format_item(item) }.join("\n\n")
        when Hash
          if data["message"]
            "API Error: #{data["message"]}"
          else
            format_item(data)
          end
        end
      rescue StandardError
        response.body[0..500]
      end

      def format_item(item)
        parts = []
        parts << "##{item["number"]} #{item["title"]}" if item["number"]
        parts << "State: #{item["state"]}" if item["state"]
        parts << "URL: #{item["html_url"]}" if item["html_url"]
        parts << "Author: #{item.dig("user", "login")}" if item.dig("user", "login")
        parts.join("\n")
      end

      def detect_repo
        remote = `git remote get-url origin 2>/dev/null`.strip
        if remote.match?(%r{github\.com[:/](.+?)(?:\.git)?$})
          remote.match(%r{github\.com[:/](.+?)(?:\.git)?$})[1]
        else
          ""
        end
      end

      def current_branch
        `git branch --show-current 2>/dev/null`.strip
      end

      def escape(str)
        str.gsub("'", "'\\''")
      end
    end
  end
end
