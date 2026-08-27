# frozen_string_literal: true

require "docx"
require "pathname"
require_relative "comment_sheet"
require_relative "comment"
require_relative "parser/osd_xlsx_parser"
require_relative "parser/track_change_docx_parser"

module Commenter
  class Parser
    def parse(input_path, options = {})
      format = detect_format(input_path, options)

      case format
      when :docx
        parse_docx(input_path, options)
      when :xlsx
        parse_xlsx(input_path, options)
      when :redline
        parse_redline(input_path, options)
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

    def parse_redline(docx_path, options)
      TrackChangeDocxParser.new.parse(docx_path, options)
    end

    def parse_docx(docx_path, options)
      doc = Docx::Document.open(docx_path)

      # Extract metadata from the first table
      metadata = extract_metadata(doc)

      # The comments are in the second table (or first table if there's only one)
      comments_table = doc.tables.length > 1 ? doc.tables[1] : doc.tables.first
      raise "No comments table found in document" unless comments_table
      raise "Comments table appears to be empty" if comments_table.row_count < 2

      # Process all rows - don't skip any rows, respect all content
      comments = (0..comments_table.row_count - 1).map do |row_index|
        cells = comments_table.rows[row_index].cells.map { |cell| cell.text.strip }
        next if cells.all?(&:empty?)

        osd_docx_row?(cells) ? build_osd_docx_comment(cells, options) : build_classic_docx_comment(cells, options)
      end.compact

      # Create comment sheet
      CommentSheet.new(
        version: "2012-03",
        date: metadata[:date],
        document: metadata[:document],
        project: metadata[:project],
        comments: comments
      )
    end

    # The DOCX from ISO OSD has 9 columns:
    # 0: User name, 1: (empty/line), 2: Clause nb, 3: Clause Title,
    # 4: Type, 5: Comment, 6: (empty/proposal), 7: Observations, 8: Comment number
    # Detected by checking if last column looks like a numeric ID.
    def osd_docx_row?(cells)
      cells.length >= 9 && cells[8].to_s.match?(/^\d+$/)
    end

    def build_osd_docx_comment(cells, options)
      attrs = {
        id: cells[8],
        body: cells[0].to_s.strip,
        locality: {
          clause: presence(cells[2]),
          element: presence(cells[3])
        },
        type: CommentType.code(cells[4]),
        comments: cells[5] || "",
        proposed_change: presence(cells[6]),
        user_name: cells[0].to_s.strip
      }
      attrs[:observations] = presence(cells[7]) unless options[:exclude_observations]
      Comment.new(attrs)
    end

    # Classic ISO comment template format (8 columns):
    # 0: ID, 1: line_number, 2: clause, 3: element, 4: type, 5: comments,
    # 6: proposed_change, 7: observations
    def build_classic_docx_comment(cells, options)
      id = cells[0] || ""
      attrs = {
        id: id,
        body: id.include?("-") ? id.split("-").first : id,
        locality: {
          line_number: presence(cells[1]),
          clause: presence(cells[2]),
          element: presence(cells[3])
        },
        type: cells[4] || "",
        comments: cells[5] || "",
        proposed_change: cells[6] || ""
      }
      attrs[:observations] = presence(cells[7]) unless options[:exclude_observations]
      Comment.new(attrs)
    end

    def presence(value)
      value && !value.empty? ? value : nil
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
