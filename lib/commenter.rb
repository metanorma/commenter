# frozen_string_literal: true

require_relative "commenter/version"
require_relative "commenter/comment"
require_relative "commenter/comment_sheet"
require_relative "commenter/parser"
require_relative "commenter/filler"
require_relative "commenter/github_integration"

module Commenter
  class Error < StandardError; end
end
