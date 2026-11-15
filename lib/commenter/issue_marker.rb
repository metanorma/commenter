# frozen_string_literal: true

module Commenter
  # Deterministic issue markers for duplicate detection: exact, independent
  # of the user's templates, and stable across runs. The document segment
  # keeps the marker unambiguous when the same comment id exists for several
  # documents in one repository; sheets without a document keep the earlier
  # marker shape.
  module IssueMarker
    PREFIX = "urn:commenter"

    module_function

    def for(comment, comment_sheet, repo)
      segments = [PREFIX, repo.to_s.downcase, comment_sheet.stage.to_s.downcase]
      document = document_segment(comment_sheet)
      segments << document unless document.nil?
      segments << comment.id
      segments.join(":")
    end

    # The marker shape used before markers carried the document. Ambiguous
    # when two documents share a comment id, so callers must verify a hit
    # against the sheet's document (see ExistingIssueFinder).
    def legacy_for(comment, comment_sheet, repo)
      "#{PREFIX}:#{repo.to_s.downcase}:#{comment_sheet.stage.to_s.downcase}:#{comment.id}"
    end

    def document_segment(comment_sheet)
      document = comment_sheet.document.to_s.gsub(/\s+/, "").downcase
      document.empty? ? nil : document
    end
  end
end
