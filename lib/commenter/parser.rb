# frozen_string_literal: true

require "docx"
require "pathname"
require_relative "comment_sheet"
require_relative "comment"
require_relative "parser/osd_xlsx_parser"

module Commenter
  class Parser
    def parse(input_path, options = {})
      format = detect_format(input_path, options)

      case format
      when :docx
        parse_docx(input_path, options)
      when :xlsx
        parse_xlsx(input_path, options)
      else
        raise "Unsupported file format: #{input_path}. Supported formats: .docx, .xlsx"
      end
    end

    private

    def detect_format(path, options = {})
      return options[:format].to_sym if options[:format]

      ext = File.extname(path).downcase
      case ext
      when ".docx" then :docx
      when ".xlsx", ".xls" then :xlsx
      else :unknown
      end
    end

    def parse_xlsx(xlsx_path, options)
      OsdXlsxParser.new.parse(xlsx_path, options)
    end

    def parse_docx(docx_path, options)
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

        # The DOCX from ISO OSD has 9 columns:
        # 0: User name, 1: (empty/line), 2: Clause nb, 3: Clause Title,
        # 4: Type, 5: Comment, 6: (empty/proposal), 7: Observations, 8: Comment number
        # Detect format by checking if last column looks like a numeric ID
        if cells.length >= 9 && cells[8] && cells[8].match?(/^\d+$/)
          # ISO OSD DOCX format (9 columns)
          id = cells[8]
          body = cells[0].to_s.strip
          comment_attrs = {
            id: id,
            body: body,
            locality: {
              clause: cells[2] && cells[2].empty? ? nil : cells[2],
              element: cells[3] && cells[3].empty? ? nil : cells[3]
            },
            type: normalize_type(cells[4]),
            comments: cells[5] || "",
            proposed_change: cells[6] && cells[6].empty? ? nil : cells[6],
            user_name: body
          }

          unless options[:exclude_observations]
            comment_attrs[:observations] = cells[7] && cells[7].empty? ? nil : cells[7]
          end

          comments << Comment.new(comment_attrs)
        else
          # Classic ISO comment template format (8 columns)
          # 0: ID, 1: line_number, 2: clause, 3: element, 4: type, 5: comments, 6: proposed_change, 7: observations
          id = cells[0] || ""
          body = id.include?("-") ? id.split("-").first : id

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

          unless options[:exclude_observations]
            comment_attrs[:observations] = cells[7] && cells[7].empty? ? nil : cells[7]
          end

          comments << Comment.new(comment_attrs)
        end
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

    def normalize_type(type_str)
      case type_str.to_s.strip.downcase
      when "editorial" then "ed"
      when "technical" then "te"
      when "general" then "ge"
      else type_str.to_s.strip
      end
    end

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

      metadata
    end
  end
end
