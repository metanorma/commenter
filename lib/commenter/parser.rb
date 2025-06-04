# frozen_string_literal: true

require "docx"
require_relative "comment_sheet"
require_relative "comment"

module Commenter
  class Parser
    def parse(docx_path, options = {})
      doc = Docx::Document.open(docx_path)

      # Extract metadata from the first table
      metadata = extract_metadata(doc)

      # The comments are in the second table (or first table if there's only one)
      comments_table = doc.tables.length > 1 ? doc.tables[1] : doc.tables.first
      raise "No comments table found in document" unless comments_table
      raise "Comments table appears to be empty" if comments_table.row_count < 2

      comments = []

      # Process all rows - don't skip any rows, respect all content
      (0..comments_table.row_count - 1).each do |i|
        row = comments_table.rows[i]
        cells = row.cells.map { |c| c.text.strip }

        # Skip only completely empty rows
        next if cells.all?(&:empty?)

        # Extract body from ID (e.g., "DE-001" -> "DE")
        id = cells[0] || ""
        body = id.include?("-") ? id.split("-").first : id

        # Create comment with symbol keys, respecting all input data
        comment_attrs = {
          id: id,
          body: body,
          locality: {
            line_number: cells[1] && cells[1].empty? ? nil : cells[1],
            clause: cells[2] && cells[2].empty? ? nil : cells[2],
            element: cells[3] && cells[3].empty? ? nil : cells[3]
          },
          type: cells[4] || "",
          comments: cells[5] || "",
          proposed_change: cells[6] || ""
        }

        # Handle observations column
        unless options[:exclude_observations]
          comment_attrs[:observations] = cells[7] && cells[7].empty? ? nil : cells[7]
        end

        comments << Comment.new(comment_attrs)
      end

      # Create comment sheet
      CommentSheet.new(
        version: "2012-03",
        date: metadata[:date],
        document: metadata[:document],
        project: metadata[:project],
        comments: comments
      )
    end

    private

    def extract_metadata(doc)
      metadata = { date: nil, document: nil, project: nil }

      # Try to extract metadata from document properties first
      begin
        if doc.respond_to?(:created) && doc.created
          metadata[:date] = begin
            doc.created.strftime("%Y-%m-%d")
          rescue StandardError
            nil
          end
        end
      rescue StandardError
        # Ignore errors accessing document properties
      end

      # Search for metadata in the document text
      all_text = doc.to_s

      # Look for date patterns
      date_match = all_text.match(/Date:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})/)
      metadata[:date] = date_match[1] if date_match

      # Look for document patterns
      doc_match = all_text.match(/Document:\s*(ISO\s+[0-9\-:]+)/)
      metadata[:document] = doc_match[1] if doc_match

      # Look for project patterns
      project_match = all_text.match(/Project:\s*([^\n\r]+)/)
      metadata[:project] = project_match[1]&.strip if project_match

      # If no metadata found, try to extract from filename or other sources
      # This is a fallback - in practice, users might need to provide metadata manually

      metadata
    end
  end
end
