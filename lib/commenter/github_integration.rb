# frozen_string_literal: true

require "octokit"
require "liquid"
require "yaml"
require "dotenv/load"

module Commenter
  class GitHubIssueCreator
    THROTTLE_SECONDS = 1
    RATE_LIMIT_RETRY_DELAY = 60
    RATE_LIMIT_MAX_RETRIES = 3
    MARKER_PREFIX = "urn:commenter"

    def initialize(config_path, title_template_path = nil, body_template_path = nil, client: nil)
      @session = GitHubSession.new(config_path)
      @config = @session.config
      @github_client = client || @session.client
      @repo = @session.repo

      @title_template = load_liquid_template(title_template_path || default_title_template_path)
      @body_template = load_liquid_template(body_template_path || default_body_template_path)
      @unique_id_template = load_unique_id_template
    end

    def create_issues_from_yaml(yaml_file, options = {})
      comment_sheet = CommentSheet.from_yaml(File.read(yaml_file))

      # Override stage if provided
      comment_sheet.stage = options[:stage] if options[:stage]

      results = []
      comment_sheet.comments.each do |comment|
        results << if options[:dry_run]
                     preview_issue(comment, comment_sheet)
                   else
                     create_issue(comment, comment_sheet, options)
                   end
      end

      # Update YAML with GitHub info after creation (unless dry run)
      update_yaml_with_github_info(yaml_file, comment_sheet, results, options) unless options[:dry_run]

      results
    end

    private

    def default_title_template_path
      File.join(__dir__, "../../data/github_issue_title_template.liquid")
    end

    def default_body_template_path
      File.join(__dir__, "../../data/github_issue_body_template.liquid")
    end

    def load_liquid_template(template_path)
      content = File.read(template_path)
      Liquid::Template.parse(content)
    rescue Errno::ENOENT
      raise "Template file not found: #{template_path}"
    end

    def load_unique_id_template
      unique_id_config = @config.dig("github", "templates", "unique_id")

      if unique_id_config
        # Check if it's a file path or inline template
        if File.exist?(unique_id_config)
          load_liquid_template(unique_id_config)
        else
          Liquid::Template.parse(unique_id_config)
        end
      else
        # Default unique_id pattern: "[STAGE] COMMENT_ID"
        Liquid::Template.parse("[{{ stage | upcase }}] {{ comment_id }}")
      end
    end

    def template_variables(comment, comment_sheet)
      # Render unique_id first so it can be used in other templates
      unique_id = render_unique_id(comment, comment_sheet)

      {
        # Comment sheet variables
        "stage" => comment_sheet.stage || "",
        "document" => comment_sheet.document || "",
        "project" => comment_sheet.project || "",
        "date" => comment_sheet.date || "",
        "version" => comment_sheet.version || "",

        # Comment variables
        "comment_id" => comment.id || "",
        "body" => comment.body || "",
        "type" => comment.type || "",
        "type_full_name" => CommentType.display_name(comment.type),
        "comments" => comment.comments || "",
        "proposed_change" => comment.proposed_change || "",
        "observations" => comment.observations || "",
        "brief_summary" => comment.brief_summary,

        # Locality variables
        "clause" => comment.clause || "",
        "element" => comment.element || "",
        "line_number" => comment.line_number || "",

        # Computed variables
        "unique_id" => unique_id,
        "has_observations" => !comment.observations.nil? && !comment.observations.strip.empty?,
        "has_proposed_change" => !comment.proposed_change.nil? && !comment.proposed_change.strip.empty?,
        "locality_summary" => format_locality(comment)
      }
    end

    def render_unique_id(comment, comment_sheet)
      base_variables = {
        "stage" => comment_sheet.stage || "",
        "document" => comment_sheet.document || "",
        "project" => comment_sheet.project || "",
        "comment_id" => comment.id || "",
        "body" => comment.body || "",
        "type" => comment.type || ""
      }
      @unique_id_template.render(base_variables).strip
    end

    def format_locality(comment)
      parts = []
      parts << "Clause #{comment.clause}" if comment.clause && !comment.clause.strip.empty?
      parts << comment.element if comment.element && !comment.element.strip.empty?
      parts << "Line #{comment.line_number}" if comment.line_number && !comment.line_number.strip.empty?
      parts.join(", ")
    end

    def create_issue(comment, comment_sheet, options = {})
      puts "[GitHubIssueCreator] Creating issue for comment ID: #{comment.id}"
      begin
        # The recorded issue number is verified with a consistent GET; the
        # title search alone cannot see issues GitHub has not indexed yet.
        existing_issue = recorded_issue(comment, comment_sheet) ||
                         find_existing_issue(comment, comment_sheet)
        if existing_issue
          puts "[GitHubIssueCreator] Issue already exists for comment ID: #{comment.id} " \
               "at stage #{comment_sheet.stage}, skipping creation."
          return {
            comment_id: comment.id,
            status: :skipped,
            message: "Issue already exists",
            issue_number: existing_issue.number,
            issue_url: existing_issue.html_url,
            issue_status: existing_issue.state,
            issue_created_at: existing_issue.created_at
          }
        end

        title = @title_template.render(template_variables(comment, comment_sheet))
        body = body_with_marker(comment, comment_sheet)

        issue_options = {
          labels: determine_labels(comment, comment_sheet),
          assignees: determine_assignees(comment, comment_sheet, options),
          milestone: determine_milestone(comment, comment_sheet, options)
        }.compact

        puts "[GitHubIssueCreator] Creating issue with title: #{title}"
        issue = create_issue_with_retry(title, body, issue_options)
        puts "[GitHubIssueCreator] Issue created successfully: #{issue.html_url}"
        {
          comment_id: comment.id,
          status: :created,
          issue_number: issue.number,
          issue_url: issue.html_url
        }
      rescue Octokit::Error => e
        puts "[GitHubIssueCreator] Error creating issue for comment ID: #{comment.id} - #{e.message}"
        {
          comment_id: comment.id,
          status: :error,
          message: e.message
        }
      end
    end

    # Deterministic marker embedded in every created issue body, independent
    # of the user's templates, so duplicate detection never has to rely on
    # title matching alone (#1).
    def issue_marker(comment, comment_sheet)
      "#{MARKER_PREFIX}:#{@repo.downcase}:#{comment_sheet.stage.to_s.downcase}:#{comment.id}"
    end

    def body_with_marker(comment, comment_sheet)
      rendered = @body_template.render(template_variables(comment, comment_sheet))
      "#{rendered}\n\n---\n`#{issue_marker(comment, comment_sheet)}`"
    end

    def recorded_issue(comment, comment_sheet)
      return nil unless comment.has_github_issue?

      number = comment.github_issue_number
      puts "[GitHubIssueCreator] Verifying recorded issue ##{number} for comment ID: #{comment.id}"
      issue = @github_client.issue(@repo, number)
      if issue.title.include?(render_unique_id(comment, comment_sheet)) ||
         issue.body.to_s.include?(issue_marker(comment, comment_sheet))
        issue
      else
        puts "[GitHubIssueCreator] Recorded issue ##{number} does not match, falling back to title search."
        nil
      end
    rescue Octokit::NotFound
      puts "[GitHubIssueCreator] Recorded issue ##{number} no longer exists, falling back to title search."
      nil
    end

    def create_issue_with_retry(title, body, issue_options)
      attempts = 0
      begin
        attempts += 1
        issue = @github_client.create_issue(@repo, title, body, issue_options)
        sleep(THROTTLE_SECONDS) if THROTTLE_SECONDS.positive?
        issue
      rescue Octokit::TooManyRequests, Octokit::Forbidden => e
        delay = rate_limit_retry_delay(e)
        if delay && attempts < RATE_LIMIT_MAX_RETRIES
          puts "[GitHubIssueCreator] Rate limited (attempt #{attempts}/#{RATE_LIMIT_MAX_RETRIES}), retrying in #{delay}s: #{e.message}"
          sleep(delay)
          retry
        end
        raise
      end
    end

    def rate_limit_retry_delay(error)
      headers = error.response_headers
      retry_after = headers && (headers[:retry_after] || headers["retry-after"])
      return retry_after.to_i if retry_after.to_i.positive?

      return RATE_LIMIT_RETRY_DELAY if error.is_a?(Octokit::TooManyRequests)

      # Secondary ("abuse") rate limits are a 403 whose body names them; a
      # permissions 403 must not be retried.
      RATE_LIMIT_RETRY_DELAY if error.message.to_s.include?("secondary rate limit")
    end

    def preview_issue(comment, comment_sheet)
      puts "[GitHubIssueCreator] Previewing issue for comment ID: #{comment.id}"

      title = @title_template.render(template_variables(comment, comment_sheet))
      body = @body_template.render(template_variables(comment, comment_sheet))

      {
        comment_id: comment.id,
        title: title,
        body: body,
        labels: determine_labels(comment, comment_sheet),
        assignees: determine_assignees(comment, comment_sheet, {}),
        milestone: determine_milestone(comment, comment_sheet, {})
      }
    end

    def find_existing_issue(comment, comment_sheet)
      unique_id = render_unique_id(comment, comment_sheet)
      puts "[GitHubIssueCreator] Searching for existing issue with unique_id: #{unique_id}"

      # The marker search is exact and template-independent (#1); the title
      # search remains as a fallback for issues created before the marker.
      marker = issue_marker(comment, comment_sheet)
      marker_results = @github_client.search_issues("repo:#{@repo} in:body \"#{marker}\"")
      return marker_results.items.first if marker_results.items.any?

      query = "repo:#{@repo} in:title \"#{unique_id}\""
      results = @github_client.search_issues(query)
      results.items.first
    end

    def determine_labels(comment, comment_sheet)
      labels = []

      # Add default labels
      labels.concat(@config.dig("github", "default_labels") || [])

      # Add stage-specific labels
      if comment_sheet.stage
        stage_labels = @config.dig("github", "stage_labels", comment_sheet.stage)
        labels.concat(stage_labels) if stage_labels
      end

      # Comment type label: only for a recognized single type — combined or
      # free-form values ("ge/te") must not mint labels (#3).
      labels << comment.type if CommentType.known?(comment.type)

      labels.uniq
    end

    def determine_assignees(_comment, _comment_sheet, options)
      assignees = []

      # Check for override in options
      if options[:assignee]
        assignees << options[:assignee]
      else
        # Use default assignee from config
        default_assignee = @config.dig("github", "default_assignee")
        assignees << default_assignee if default_assignee
      end

      assignees.compact.uniq
    end

    def determine_milestone(_comment, _comment_sheet, _options)
      # # Check for stage-specific milestone
      # if comment_sheet.stage
      #   stage_milestone = @config.dig("github", "stage_milestones", comment_sheet.stage)
      #   if stage_milestone
      #     milestone_number = resolve_milestone_by_name_or_number(stage_milestone)
      #     return milestone_number if milestone_number
      #   end
      # end

      # Use configured milestone
      milestone_config = @config.dig("github", "milestone")
      return nil unless milestone_config

      if milestone_config["number"]
        puts "[GitHubIssueCreator] Using milestone number: #{milestone_config["number"]}"
        milestone_config["number"]
      elsif milestone_config["name"]
        # Resolved once per run and memoized: resolving per comment caused
        # duplicated milestone fetches (see 3a06c3d).
        @milestone_number ||= begin
          puts "[GitHubIssueCreator] Using milestone name: #{milestone_config["name"]}"
          resolve_milestone_by_name_or_number(milestone_config["name"])
        end
      end
    end

    def resolve_milestone_by_name_or_number(milestone_identifier)
      # If it's a number, return it directly
      return milestone_identifier.to_i if milestone_identifier.to_s.match?(/^\d+$/)

      # Otherwise, search by name
      find_milestone_by_name(milestone_identifier)
    end

    def find_milestone_by_name(name)
      milestones = @github_client.milestones(@repo, state: "all")

      puts "[GitHubIssueCreator] Found #{milestones.size} milestones in repository #{@repo}" if milestones.any?
      milestone = milestones.find { |m| m.title == name }
      milestone&.number
    rescue Octokit::Error
      nil
    end

    def update_yaml_with_github_info(yaml_file, comment_sheet, results, options)
      # Update comments with GitHub information
      results.each do |result|
        next unless result[:issue_number]

        comment = comment_sheet.comments.find { |c| c.id == result[:comment_id] }
        next unless comment

        created_at = comment.github_created_at || result[:issue_created_at] || Time.now.utc.iso8601
        created_at = created_at.iso8601 if created_at.is_a?(Time)

        comment.record_github_issue(issue_number: result[:issue_number], issue_url: result[:issue_url],
                                    status: result[:issue_status] || (result[:status] == :created ? "open" : comment.github_status),
                                    created_at: created_at)
      end

      # Write updated YAML
      output_file = options[:output] || yaml_file
      File.write(output_file, comment_sheet.to_yaml_document)
    end
  end
end
