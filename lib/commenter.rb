# frozen_string_literal: true

require_relative "commenter/version"

# Commenter converts ISO comment sheets (DOCX/XLSX) to structured YAML and
# syncs comments to GitHub issues.
module Commenter
  class Error < StandardError; end

  autoload :CommentType, "commenter/comment_type"
  autoload :CommentLocality, "commenter/comment_locality"
  autoload :GithubInfo, "commenter/github_info"
  autoload :DispositionStatus, "commenter/disposition_status"
  autoload :Ballot, "commenter/ballot"
  autoload :BallotReport, "commenter/ballot_report"
  autoload :Comment, "commenter/comment"
  autoload :CommentSheet, "commenter/comment_sheet"
  autoload :GitHubSession, "commenter/github_session"
  autoload :Parser, "commenter/parser"
  autoload :Filler, "commenter/filler"
  autoload :GitHubIssueCreator, "commenter/github_integration"
  autoload :GitHubIssueRetriever, "commenter/github_integration"
end
