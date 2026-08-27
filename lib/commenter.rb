# frozen_string_literal: true

require_relative "commenter/version"
require_relative "commenter/comment"
require_relative "commenter/comment_sheet"
require_relative "commenter/parser"
require_relative "commenter/filler"
require_relative "commenter/github_integration"

# Commenter converts ISO comment sheets (DOCX/XLSX) to structured YAML and
# syncs comments to GitHub issues.
module Commenter
  class Error < StandardError; end

  autoload :CommentType, "commenter/comment_type"
  autoload :GitHubSession, "commenter/github_session"
end
