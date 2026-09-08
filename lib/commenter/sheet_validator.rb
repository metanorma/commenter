# frozen_string_literal: true

module Commenter
  # Structural validation of a comment sheet — the checks the CLI schemas
  # express, living next to the model so the vocabulary stays in one place.
  # Returns a list of problems; entries are hashes with :severity (:error or
  # :warning), :comment (id when the problem belongs to one comment), and
  # :message. An empty list means the sheet is valid.
  module SheetValidator
    VERSIONS = %w[2012-03 osd].freeze
    STAGES = %w[WD CD DIS FDIS PRF PUB].freeze

    module_function

    def call(sheet)
      problems = []
      unless VERSIONS.include?(sheet.version)
        problems << { severity: :error,
                      message: "unknown version #{sheet.version.inspect} (expected #{VERSIONS.join(" or ")})" }
      end
      if sheet.stage && !STAGES.include?(sheet.stage)
        problems << { severity: :warning,
                      message: "unusual stage #{sheet.stage.inspect} (expected one of #{STAGES.join(", ")})" }
      end

      sheet.comments.each_with_index do |comment, index|
        problems.concat(comment_problems(comment, index))
      end

      duplicates = sheet.comments.group_by { |comment| comment.id.to_s }
                                 .reject { |id, _| id.empty? }
                                 .select { |_, comments| comments.length > 1 }
                                 .keys
      duplicates.sort.each do |id|
        problems << { severity: :error, comment: id, message: "duplicate comment id #{id}" }
      end

      problems
    end

    def comment_problems(comment, index)
      problems = []
      label = comment.id.to_s.empty? ? "comment ##{index + 1}" : comment.id

      problems << { severity: :error, comment: label, message: "missing id" } if comment.id.to_s.strip.empty?
      problems << { severity: :error, comment: label, message: "missing comment text" } if comment.comments.to_s.strip.empty?
      unless comment.type.to_s.strip.empty? || CommentType.known?(comment.type)
        problems << { severity: :warning, comment: label,
                      message: "unrecognized comment type #{comment.type.inspect} (no label will be minted for it)" }
      end

      problems
    end
  end
end
