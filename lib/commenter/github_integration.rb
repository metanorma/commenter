# frozen_string_literal: true

require "octokit"
require "liquid"
require "yaml"
require "dotenv/load"

module Commenter
  class GitHubIssueCreator
    def initialize(config_path, title_template_path = nil, body_template_path = nil)
      @config = load_config(config_path)
      @github_client = create_github_client
      @repo = @config.dig("github", "repository")

      raise "GitHub repository not specified in config" unless @repo

      @title_template = load_liquid_template(title_template_path || default_title_template_path)
      @body_template = load_liquid_template(body_template_path || default_body_template_path)
    end

    def create_issues_from_yaml(yaml_file, options = {})
      data = YAML.load_file(yaml_file)
      comment_sheet = CommentSheet.from_hash(data)

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

    def load_config(config_path)
      YAML.load_file(config_path)
    rescue Errno::ENOENT
      raise "Configuration file not found: #{config_path}"
    end

    def create_github_client
      token = @config.dig("github", "token") || ENV["GITHUB_TOKEN"]
      raise "GitHub token not found. Set GITHUB_TOKEN environment variable or specify in config file." unless token

      Octokit::Client.new(access_token: token)
    end

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

    def template_variables(comment, comment_sheet)
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
        "type_full_name" => expand_comment_type(comment.type),
        "comments" => comment.comments || "",
        "proposed_change" => comment.proposed_change || "",
        "observations" => comment.observations || "",
        "brief_summary" => comment.brief_summary,

        # Locality variables
        "clause" => comment.clause || "",
        "element" => comment.element || "",
        "line_number" => comment.line_number || "",

        # Computed variables
        "has_observations" => !comment.observations.nil? && !comment.observations.strip.empty?,
        "has_proposed_change" => !comment.proposed_change.nil? && !comment.proposed_change.strip.empty?,
        "locality_summary" => format_locality(comment)
      }
    end

    def expand_comment_type(type)
      case type&.downcase
      when "ge" then "General"
      when "te" then "Technical"
      when "ed" then "Editorial"
      else type || "Unknown"
      end
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
      # Check if issue already exists
      existing_issue = find_existing_issue(comment)
      if existing_issue
        puts "[GitHubIssueCreator] Issue already exists for comment ID: #{comment.id}, skipping creation."
        return {
          comment_id: comment.id,
          status: :skipped,
          message: "Issue already exists",
          issue_url: existing_issue.html_url
        }
      end

      title = @title_template.render(template_variables(comment, comment_sheet))
      body = @body_template.render(template_variables(comment, comment_sheet))

      issue_options = {
        labels: determine_labels(comment, comment_sheet),
        assignees: determine_assignees(comment, comment_sheet, options),
        milestone: determine_milestone(comment, comment_sheet, options)
      }.compact

      puts "[GitHubIssueCreator] Creating issue with title: #{title}"
      begin
        issue = @github_client.create_issue(@repo, title, body, issue_options)
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

    def find_existing_issue(comment)
      puts "[GitHubIssueCreator] Searching for existing issue for comment ID: #{comment.id}"

      # Search for existing issues with the comment ID in the title
      query = "repo:#{@repo} in:title #{comment.id}"
      results = @github_client.search_issues(query)
      results.items.first
    rescue Octokit::Error
      nil
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

      # Add comment type label
      labels << comment.type if comment.type

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

    def determine_milestone(_comment, comment_sheet, options)
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
        puts "[GitHubIssueCreator] Using milestone name: #{milestone_config["name"]}"
        resolve_milestone_by_name_or_number(milestone_config["name"])
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
        next unless result[:status] == :created

        comment = comment_sheet.comments.find { |c| c.id == result[:comment_id] }
        next unless comment

        # Add GitHub information to the comment
        comment.github[:issue_number] = result[:issue_number]
        comment.github[:issue_url] = result[:issue_url]
        comment.github[:status] = "open"
        comment.github[:created_at] = Time.now.utc.iso8601
      end

      # Write updated YAML
      output_file = options[:output] || yaml_file
      yaml_content = generate_yaml_with_header(comment_sheet.to_yaml_h)
      File.write(output_file, yaml_content)
    end

    def generate_yaml_with_header(data)
      header = "# yaml-language-server: $schema=schema/iso_comment_2012-03.yaml\n\n"
      header + data.to_yaml
    end
  end

  class GitHubIssueRetriever
    def initialize(config_path)
      @config = load_config(config_path)
      @github_client = create_github_client
      @repo = @config.dig("github", "repository")

      raise "GitHub repository not specified in config" unless @repo
    end

    def retrieve_observations_from_yaml(yaml_file, options = {})
      data = YAML.load_file(yaml_file)
      comment_sheet = CommentSheet.from_hash(data)

      results = []
      comment_sheet.comments.each do |comment|
        next unless comment.has_github_issue?

        result = if options[:dry_run]
                   preview_observation_retrieval(comment, options)
                 else
                   retrieve_observation(comment, options)
                 end
        results << result
      end

      # Update YAML with observations (unless dry run)
      update_yaml_with_observations(yaml_file, comment_sheet, options) unless options[:dry_run]

      results
    end

    private

    def load_config(config_path)
      YAML.load_file(config_path)
    rescue Errno::ENOENT
      raise "Configuration file not found: #{config_path}"
    end

    def create_github_client
      token = @config.dig("github", "token") || ENV["GITHUB_TOKEN"]
      raise "GitHub token not found. Set GITHUB_TOKEN environment variable or specify in config file." unless token

      Octokit::Client.new(access_token: token)
    end

    def retrieve_observation(comment, options)
      issue_number = comment.github_issue_number

      begin
        issue = @github_client.issue(@repo, issue_number)

        # Skip open issues unless explicitly included
        if issue.state == "open" && !options[:include_open]
          return {
            comment_id: comment.id,
            issue_number: issue_number,
            status: :skipped,
            message: "Issue is still open"
          }
        end

        # Extract observation from issue comments
        observation = extract_observation_from_issue(issue_number)

        if observation
          # Update comment with observation and current status
          comment.observations = observation
          comment.github[:status] = issue.state
          comment.github[:updated_at] = Time.now.utc.iso8601

          {
            comment_id: comment.id,
            issue_number: issue_number,
            status: :retrieved,
            observation: observation
          }
        else
          {
            comment_id: comment.id,
            issue_number: issue_number,
            status: :skipped,
            message: "No observation found in issue"
          }
        end
      rescue Octokit::Error => e
        {
          comment_id: comment.id,
          issue_number: issue_number,
          status: :error,
          message: e.message
        }
      end
    end

    def preview_observation_retrieval(comment, _options)
      issue_number = comment.github_issue_number

      begin
        issue = @github_client.issue(@repo, issue_number)
        observation = extract_observation_from_issue(issue_number)

        {
          comment_id: comment.id,
          issue_number: issue_number,
          status: issue.state,
          observation: observation
        }
      rescue Octokit::Error => e
        {
          comment_id: comment.id,
          issue_number: issue_number,
          status: :error,
          message: e.message
        }
      end
    end

    def extract_observation_from_issue(issue_number)
      comments = @github_client.issue_comments(@repo, issue_number)

      # Look for magic comments with observation markers
      observation_markers = @config.dig("github", "retrieval", "observation_markers") ||
                            ["**OBSERVATION:**", "**COMMENTER OBSERVATION:**"]

      # Search comments in reverse order (newest first)
      comments.reverse_each do |comment|
        observation = parse_observation_from_comment(comment.body, observation_markers)
        return observation if observation
      end

      # Fallback to last comment if configured and no magic comment found
      return comments.last.body.strip if @config.dig("github", "retrieval", "fallback_to_last_comment") && !comments.empty?

      nil
    rescue Octokit::Error
      nil
    end

    def parse_observation_from_comment(comment_body, markers)
      markers.each do |marker|
        # Look for markdown blockquote with the marker
        pattern = /^>\s*#{Regexp.escape(marker)}\s*\n((?:^>.*\n?)*)/m
        match = comment_body.match(pattern)

        next unless match

        # Extract the blockquote content and clean it up
        observation = match[1]
                      .split("\n")
                      .map { |line| line.sub(/^>\s?/, "") }
                      .join("\n")
                      .strip
        return observation unless observation.empty?
      end

      nil
    end

    def update_yaml_with_observations(yaml_file, comment_sheet, options)
      output_file = options[:output] || yaml_file
      yaml_content = generate_yaml_with_header(comment_sheet.to_yaml_h)
      File.write(output_file, yaml_content)
    end

    def generate_yaml_with_header(data)
      header = "# yaml-language-server: $schema=schema/iso_comment_2012-03.yaml\n\n"
      header + data.to_yaml
    end
  end
end
