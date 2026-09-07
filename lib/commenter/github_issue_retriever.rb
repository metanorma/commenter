# frozen_string_literal: true

require "octokit"
require "yaml"
require "dotenv/load"

module Commenter
  # Pulls official observations (OBSERVATION: blockquotes) out of the GitHub
  # issues recorded in the comments YAML and writes them back into the file.
  class GitHubIssueRetriever
    def initialize(config_path, client: nil)
      @session = GitHubSession.new(config_path)
      @config = @session.config
      @github_client = client || @session.client
      @repo = @session.repo
    end

    def retrieve_observations_from_yaml(yaml_file, options = {})
      comment_sheet = CommentSheet.from_yaml(File.read(yaml_file))

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

    def retrieve_observation(comment, _options)
      issue_number = comment.github_issue_number

      begin
        issue = @github_client.issue(@repo, issue_number)

        # An observation is filled in whenever it is present, open issue or
        # not (#4); only the "still waiting" case is skipped.
        observation = extract_observation_from_issue(issue_number)

        if observation
          comment.observations = observation
          comment.github.status = issue.state
          comment.github.updated_at = Time.now.utc.iso8601

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
            message: issue.state == "open" ? "Issue is still open (no observation yet)" : "No observation found in issue"
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
      return comments.last.body.strip if @config.dig("github", "retrieval",
                                                     "fallback_to_last_comment") && !comments.empty?

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
      File.write(output_file, comment_sheet.to_yaml_document)
    end
  end
end
