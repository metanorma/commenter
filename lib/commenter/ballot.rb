# frozen_string_literal: true

module Commenter
  # Merges member-body comment sheets into a single ballot sheet — the
  # collation step secretariats otherwise do by hand (ISO's own Comment
  # Collation Tool fails on non-conforming files).
  #
  # Policy: sheet metadata is first-non-nil across the given sheets (the
  # output version comes from the first sheet); comments keep their input
  # order. Identical duplicate IDs are deduplicated silently; the same ID
  # with differing content raises.
  class Ballot
    def initialize(sheets)
      @sheets = sheets
    end

    def merge
      CommentSheet.new(
        version: first_sheet&.version,
        date: first_value(:date),
        document: first_value(:document),
        project: first_value(:project),
        stage: first_value(:stage),
        title_en: first_value(:title_en),
        title_fr: first_value(:title_fr),
        comments: deduplicate(@sheets.flat_map(&:comments))
      )
    end

    private

    def first_sheet
      @sheets.first
    end

    def first_value(attribute)
      @sheets.lazy.map { |sheet| sheet.public_send(attribute) }.find { |value| !value.nil? }
    end

    def deduplicate(comments)
      seen = {}
      conflicts = []
      kept = comments.reject do |comment|
        key = comment.id.to_s
        next false if key.empty?

        existing = seen[key]
        if existing.nil?
          seen[key] = comment
          false
        elsif identical?(existing, comment)
          true
        else
          conflicts << key
          false
        end
      end
      return kept if conflicts.empty?

      raise Commenter::Error, "Duplicate comment IDs with differing content: #{conflicts.uniq.sort.join(", ")}"
    end

    def identical?(one, another)
      one.comments == another.comments && one.proposed_change == another.proposed_change
    end
  end
end
