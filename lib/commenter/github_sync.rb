# frozen_string_literal: true

module Commenter
  # Synchronizes the comment YAML with GitHub issues, treating the YAML as
  # the source of truth: comments without an issue get one, issue content is
  # refreshed from the YAML (per the conflict policy), and issues whose
  # comment has a recorded disposition can be closed.
  class GitHubSync < GitHubIssueCreator
    # Returns the sync actions for one comment by comparing the rendered
    # issue content against the issue's current state. Pure — no network —
    # so the conflict matrix is directly specifiable.
    #
    # conflict policy:
    #   yaml   - re-render title/body over the issue (YAML wins)
    #   github - leave differing issue content untouched (GitHub wins)
    #   skip   - take no action on differing content, report the conflict
    def self.reconcile_actions(issue:, rendered:, disposition:, conflict: "yaml",
                               close_on_disposition: true)
      actions = []
      differing = [rendered[:title].to_s.strip, rendered[:body].to_s.strip] !=
                  [issue[:title].to_s.strip, issue[:body].to_s.strip]

      if differing
        case conflict
        when "yaml" then actions << :update_content
        when "github" then actions << :keep_github_content
        when "skip" then actions << :conflict
        end
      end

      actions << :close if close_on_disposition && issue[:state] == "open" && disposition && !disposition.strip.empty?

      actions
    end

    def sync(yaml_file, options = {})
      comment_sheet = CommentSheet.from_yaml(File.read(yaml_file))
      comment_sheet.stage = options[:stage] if options[:stage]

      results = comment_sheet.comments.map do |comment|
        options[:dry_run] ? plan(comment, options) : reconcile(comment, comment_sheet, options)
      end

      update_yaml_with_github_info(yaml_file, comment_sheet, results, options) unless options[:dry_run]
      results
    end

    private

    # Dry-run preview, offline: comments with a known issue are planned from
    # the last state recorded in the YAML, not from a live fetch.
    def plan(comment, options)
      return { comment_id: comment.id, actions: [:create] } unless comment.has_github_issue?

      actions = [:reconcile]
      if close_on_disposition?(options) && comment.github_status == "open" &&
         comment.observations && !comment.observations.strip.empty?
        actions << :close
      end
      { comment_id: comment.id, issue_number: comment.github_issue_number, actions: actions }
    end

    def reconcile(comment, comment_sheet, options)
      issue = find_existing_issue(comment, comment_sheet)
      return create_issue(comment, comment_sheet, options) unless issue

      title = @title_template.render(template_variables(comment, comment_sheet))
      body = @body_template.render(template_variables(comment, comment_sheet))
      actions = self.class.reconcile_actions(
        issue: { title: issue.title, body: issue.body, state: issue.state },
        rendered: { title: title, body: body },
        disposition: comment.observations,
        conflict: options[:conflict] || "yaml",
        close_on_disposition: close_on_disposition?(options)
      )

      apply(comment, issue, title, body, actions)
    rescue Octokit::Error => e
      { comment_id: comment.id, status: :error, message: e.message }
    end

    def apply(comment, issue, title, body, actions)
      result = { comment_id: comment.id, issue_number: issue.number, status: :unchanged, actions: actions }
      comment.record_github_issue(issue_number: issue.number, issue_url: issue.html_url, status: issue.state)

      if actions.include?(:update_content)
        @github_client.update_issue(@repo, issue.number, title: title, body: body)
        result[:status] = :updated
      end

      if actions.include?(:close)
        @github_client.close_issue(@repo, issue.number)
        comment.github.status = "closed"
        comment.github.updated_at = Time.now.utc.iso8601
        result[:status] = actions.include?(:update_content) ? :updated_and_closed : :closed
      end

      result
    end

    def close_on_disposition?(options)
      options.fetch(:close_on_disposition, true)
    end
  end
end
