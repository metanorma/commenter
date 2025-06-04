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
      # Check if issue already exists
      existing_issue = find_existing_issue(comment)
      if existing_issue
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

      begin
        issue = @github_client.create_issue(@repo, title, body, issue_options)
        {
          comment_id: comment.id,
          status: :created,
          issue_number: issue.number,
          issue_url: issue.html_url
        }
      rescue Octokit::Error => e
        {
          comment_id: comment.id,
          status: :error,
          message: e.message
        }
      end
    end

    def preview_issue(comment, comment_sheet)
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

    def determine_assignees(comment, comment_sheet, options)
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

    def determine_milestone(comment, comment_sheet, options)
      # Check for override in options
      return resolve_milestone_by_name_or_number(options[:milestone]) if options[:milestone]

      # Check for stage-specific milestone
      if comment_sheet.stage
        stage_milestone = @config.dig("github", "stage_milestones", comment_sheet.stage)
        if stage_milestone
          milestone_number = resolve_milestone_by_name_or_number(stage_milestone)
          return milestone_number if milestone_number
        end
      end

      # Use configured milestone
      milestone_config = @config.dig("github", "milestone")
      return nil unless milestone_config

      if milestone_config["number"]
        milestone_config["number"]
      elsif milestone_config["name"]
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
      milestone = milestones.find { |m| m.title == name }
      milestone&.number
    rescue Octokit::Error
      nil
    end
  end
end
