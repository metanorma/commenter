# frozen_string_literal: true

require "roo"
require_relative "../comment_sheet"
require_relative "../comment"

module Commenter
  class Parser
    # Parser for ISO Online Standards Development (OSD) XLSX exports.
    #
    # Supports two variants:
    #   - "resolved" XLSX: single "Comments (N)" sheet with resolution data
    #     (columns: Comment ID, User name, Clause nb, ..., Resolution status, Motivation, Resolution Date, Stage code)
    #   - "unresolved" XLSX: multi-sheet format with "Comments (N)", "Unresolved comments (N)",
    #     "Resolved comments (N)" sheets
    #     (columns: User name, Clause nb, ..., Comment type, Comment/Motivation, Comment on text,
    #      Proposal on Text, Proposed change, Replies, Resolution status, Justification, Resolution Date, Date, Comment number)
    #
    # Both formats share the same header structure in rows 0-3:
    #   Row 0: [Date, Reference, nil, "", Title EN, nil, nil, Title FR, ...]
    #   Row 1: ["2026-04-21", "ISO/DIS 5843-6(en)", ...]
    #   Row 2: empty
    #   Row 3: column headers
    #   Row 4+: data
    class OsdXlsxParser
      RESOLVED_HEADERS = [
        "Comment ID", "User name", "Clause nb", "Clause Title", "Type", "Subtype",
        "Comment", "Proposal on Text", "Proposed change", "Feedbacks", "Topic",
        "Tags", "Created Date", "Resolution status", "Motivation", "Resolution Date", "Stage code"
      ].freeze

      UNRESOLVED_HEADERS = [
        "User name", "Clause nb", "Clause Title", "Type", "Comment type",
        "Comment/Motivation", "Comment on text", "Proposal on Text", "Proposed change",
        "Replies", "Resolution status", "Justification", "Resolution Date", "Date", "Comment number"
      ].freeze

      def parse(xlsx_path, options = {})
        xlsx = Roo::Spreadsheet.open(xlsx_path)

        # Select which sheet(s) to use
        sheet_name = select_sheet(xlsx, options)

        # Detect variant from header row
        sheet = xlsx.sheet(sheet_name)
        header_row_num = find_header_row(sheet)
        header_row_data = sheet.row(header_row_num)
        variant = detect_variant(header_row_data)

        # Extract metadata from the header rows
        metadata = extract_metadata(xlsx, sheet_name, header_row_num)

        # Parse comments based on variant
        comments = if variant == :resolved
                     parse_resolved_sheet(sheet, header_row_num, options)
                   else
                     parse_unresolved_sheet(sheet, header_row_num, options)
                   end

        CommentSheet.new(
          version: "osd",
          date: metadata[:date],
          document: metadata[:document],
          project: metadata[:project],
          stage: metadata[:stage],
          title_en: metadata[:title_en],
          title_fr: metadata[:title_fr],
          comments: comments
        )
      end

      private

      def select_sheet(xlsx, options)
        sheets = xlsx.sheets

        if options[:sheet]
          # Explicit sheet name
          raise "Sheet '#{options[:sheet]}' not found. Available: #{sheets.join(', ')}" unless sheets.include?(options[:sheet])
          options[:sheet]
        elsif options[:resolved_only]
          sheets.find { |s| s.start_with?("Resolved") } || sheets.find { |s| s.start_with?("Comments") }
        elsif options[:unresolved_only]
          sheets.find { |s| s.start_with?("Unresolved") } || sheets.find { |s| s.start_with?("Comments") }
        else
          # Default: use first sheet (usually "Comments (N)" which has all comments)
          sheets.first
        end
      end

      def find_header_row(sheet)
        # Headers are always in row 4 (1-indexed in Roo), which is the 4th row (index 3)
        # But we search for it to be safe
        (1..10).each do |row_num|
          row = sheet.row(row_num).compact.map(&:to_s)
          return row_num if row.include?("User name") || row.include?("Comment ID")
        end
        raise "Could not find header row in XLSX sheet"
      end

      def detect_variant(header_row)
        row = header_row.compact.map(&:to_s)
        if row.include?("Comment ID") || row.include?("Subtype")
          :resolved
        elsif row.include?("Comment/Motivation") || row.include?("Comment type")
          :unresolved
        else
          # Try to infer from column count
          row.length >= 15 ? :resolved : :unresolved
        end
      end

      def extract_metadata(xlsx, sheet_name, header_row_num)
        metadata = { date: nil, document: nil, project: nil, stage: nil, title_en: nil, title_fr: nil }

        # Row 1 (1-indexed) contains header labels: [Date, Reference, nil, "", Title EN, nil, nil, Title FR, ...]
        # Row 2 (1-indexed) contains values: [2026-04-21, ISO/DIS 5843-6(en), nil, "", ...]
        # We read raw rows (not compact) to preserve column positions
        row1 = xlsx.sheet(sheet_name).row(1)
        row2 = xlsx.sheet(sheet_name).row(2)

        # Date is in column 0 of row 2 (the value row)
        date_val = row2 && row2[0]
        date_str = date_val.is_a?(Date) ? date_val.strftime("%Y-%m-%d") : date_val.to_s.strip
        metadata[:date] = date_str if date_str && !date_str.empty? && date_str != "Date"

        # Reference is in column 1 of row 2 (e.g. "ISO/DIS 5843-6(en)")
        reference = row2 && row2[1] ? row2[1].to_s.strip : nil
        if reference && !reference.empty? && reference != "Reference"
          metadata[:document] = reference
          metadata[:stage] = extract_stage(reference)
          metadata[:project] = extract_project(reference)
        end

        # Title EN is in column 4 of row 2
        title_en = row2 && row2[4] ? row2[4].to_s.strip : nil
        metadata[:title_en] = title_en if title_en && !title_en.empty? && title_en != "Title EN"

        # Title FR is in column 7 of row 2
        title_fr = row2 && row2[7] ? row2[7].to_s.strip : nil
        metadata[:title_fr] = title_fr if title_fr && !title_fr.empty? && title_fr != "Title FR"

        metadata
      end

      def parse_date(date_str)
        case date_str
        when /^\d{4}-\d{2}-\d{2}$/
          date_str
        when /(\d{4})-(\d{2})-(\d{2})/
          $&
        else
          date_str
        end
      rescue StandardError
        date_str
      end

      def extract_stage(reference)
        case reference
        when /\/WD\b/i then "WD"
        when /\/CD\b/i then "CD"
        when /\/DIS\b/i then "DIS"
        when /\/FDIS\b/i then "FDIS"
        else nil
        end
      end

      def extract_project(reference)
        # Extract ISO number from reference like "ISO/DIS 5843-6(en)"
        match = reference.match(/(ISO[\s\/]*\w*\s*\d+[\-\d]*)/)
        match ? match[1].strip.gsub(/\s+/, " ") : nil
      end

      def parse_resolved_sheet(sheet, header_row_num, options)
        # Build column index map from header
        headers = sheet.row(header_row_num).compact.map { |h| h.to_s.strip }
        col_map = build_resolved_column_map(headers)

        comments = []
        (header_row_num + 1..sheet.last_row).each do |row_num|
          row = sheet.row(row_num)
          next if row.nil? || row.compact.empty?

          comment = build_resolved_comment(row, col_map, options)
          comments << comment if comment
        end

        comments
      end

      def parse_unresolved_sheet(sheet, header_row_num, options)
        # Build column index map from header
        headers = sheet.row(header_row_num).compact.map { |h| h.to_s.strip }
        col_map = build_unresolved_column_map(headers)

        comments = []
        (header_row_num + 1..sheet.last_row).each do |row_num|
          row = sheet.row(row_num)
          next if row.nil? || row.compact.empty?

          comment = build_unresolved_comment(row, col_map, options)
          comments << comment if comment
        end

        comments
      end

      def build_resolved_column_map(headers)
        map = {}
        headers.each_with_index do |h, i|
          case h
          when "Comment ID" then map[:id] = i
          when "User name" then map[:user_name] = i
          when "Clause nb" then map[:clause] = i
          when "Clause Title" then map[:clause_title] = i
          when "Type" then map[:type] = i
          when "Subtype" then map[:subtype] = i
          when "Comment" then map[:comment_text] = i
          when "Proposal on Text" then map[:proposal_on_text] = i
          when "Proposed change" then map[:proposed_change] = i
          when "Feedbacks" then map[:feedbacks] = i
          when "Topic" then map[:topic] = i
          when "Tags" then map[:tags] = i
          when "Created Date" then map[:created_date] = i
          when "Resolution status" then map[:resolution_status] = i
          when "Motivation" then map[:motivation] = i
          when "Resolution Date" then map[:resolution_date] = i
          when "Stage code" then map[:stage_code] = i
          end
        end
        map
      end

      def build_unresolved_column_map(headers)
        map = {}
        headers.each_with_index do |h, i|
          case h
          when "User name" then map[:user_name] = i
          when "Clause nb" then map[:clause] = i
          when "Clause Title" then map[:clause_title] = i
          when "Type" then map[:type] = i
          when "Comment type" then map[:comment_type] = i
          when "Comment/Motivation" then map[:comment_text] = i
          when "Comment on text" then map[:comment_on_text] = i
          when "Proposal on Text" then map[:proposal_on_text] = i
          when "Proposed change" then map[:proposed_change] = i
          when "Replies" then map[:replies] = i
          when "Resolution status" then map[:resolution_status] = i
          when "Justification" then map[:justification] = i
          when "Resolution Date" then map[:resolution_date] = i
          when "Date" then map[:created_date] = i
          when "Comment number" then map[:id] = i
          end
        end
        map
      end

      def build_resolved_comment(row, col_map, options)
        id = cell_value(row, col_map[:id])
        return nil if id.nil?

        # Normalize id to string
        id_str = id.is_a?(Float) ? id.to_i.to_s : id.to_s

        comment_text = cell_value(row, col_map[:comment_text]) || ""
        return nil if comment_text.strip.empty? && id_str.empty?

        clause = cell_value(row, col_map[:clause]) || ""
        clause_title = cell_value(row, col_map[:clause_title]) || ""
        subtype = cell_value(row, col_map[:subtype]) || ""

        # Combine clause number and title for locality
        clause_ref = clause.to_s.strip
        clause_ref = "#{clause_ref} #{clause_title}".strip if clause_title && !clause_title.empty?

        user_name = cell_value(row, col_map[:user_name]) || ""
        body = user_name.to_s.strip

        comment_attrs = {
          id: id_str,
          body: body,
          locality: {
            clause: clause.empty? ? nil : clause.to_s.strip,
            element: clause_title.empty? ? nil : clause_title.to_s.strip
          }.compact,
          type: normalize_comment_type(subtype),
          comments: comment_text.to_s.strip,
          proposed_change: cell_value_str(row, col_map[:proposed_change]) ||
                           cell_value_str(row, col_map[:proposal_on_text]),
          observations: nil
        }

        # OSD-specific fields
        comment_attrs[:user_name] = user_name.to_s.strip
        comment_attrs[:comment_type] = subtype.to_s.strip
        comment_attrs[:resolution_status] = cell_value_str(row, col_map[:resolution_status])
        comment_attrs[:resolution_date] = cell_value_str(row, col_map[:resolution_date])
        comment_attrs[:feedbacks] = cell_value_str(row, col_map[:feedbacks])
        comment_attrs[:motivation] = cell_value_str(row, col_map[:motivation])
        comment_attrs[:created_date] = cell_value_str(row, col_map[:created_date])
        comment_attrs[:stage_code] = cell_value_str(row, col_map[:stage_code])

        # Build observations from resolution data
        unless options[:exclude_observations]
          observations_parts = []
          if comment_attrs[:resolution_status] && !comment_attrs[:resolution_status].empty?
            observations_parts << comment_attrs[:resolution_status]
          end
          if comment_attrs[:motivation] && !comment_attrs[:motivation].empty?
            observations_parts << comment_attrs[:motivation]
          end
          comment_attrs[:observations] = observations_parts.empty? ? nil : observations_parts.join(". ")
        end

        Comment.new(comment_attrs)
      end

      def build_unresolved_comment(row, col_map, options)
        id = cell_value(row, col_map[:id])
        return nil if id.nil?

        # Normalize id to string
        id_str = id.is_a?(Float) ? id.to_i.to_s : id.to_s

        comment_text = cell_value(row, col_map[:comment_text]) || ""
        return nil if comment_text.strip.empty? && id_str.empty?

        clause = cell_value(row, col_map[:clause]) || ""
        clause_title = cell_value(row, col_map[:clause_title]) || ""
        comment_type = cell_value(row, col_map[:comment_type]) || ""

        user_name = cell_value(row, col_map[:user_name]) || ""
        body = user_name.to_s.strip

        comment_attrs = {
          id: id_str,
          body: body,
          locality: {
            clause: clause.empty? ? nil : clause.to_s.strip,
            element: clause_title.empty? ? nil : clause_title.to_s.strip
          }.compact,
          type: normalize_comment_type(comment_type),
          comments: comment_text.to_s.strip,
          proposed_change: cell_value_str(row, col_map[:proposed_change]) ||
                           cell_value_str(row, col_map[:proposal_on_text]),
          observations: nil
        }

        # OSD-specific fields
        comment_attrs[:user_name] = user_name.to_s.strip
        comment_attrs[:comment_type] = comment_type.to_s.strip
        comment_attrs[:resolution_status] = cell_value_str(row, col_map[:resolution_status])
        comment_attrs[:resolution_date] = cell_value_str(row, col_map[:resolution_date])
        comment_attrs[:feedbacks] = cell_value_str(row, col_map[:replies])
        comment_attrs[:motivation] = cell_value_str(row, col_map[:justification])
        comment_attrs[:created_date] = cell_value_str(row, col_map[:created_date])

        # Build observations from resolution data
        unless options[:exclude_observations]
          observations_parts = []
          if comment_attrs[:resolution_status] && !comment_attrs[:resolution_status].empty?
            observations_parts << comment_attrs[:resolution_status]
          end
          if comment_attrs[:motivation] && !comment_attrs[:motivation].empty?
            observations_parts << comment_attrs[:motivation]
          end
          comment_attrs[:observations] = observations_parts.empty? ? nil : observations_parts.join(". ")
        end

        Comment.new(comment_attrs)
      end

      def normalize_comment_type(type_str)
        case type_str.to_s.strip.downcase
        when "editorial" then "ed"
        when "technical" then "te"
        when "general" then "ge"
        when "ed" then "ed"
        when "te" then "te"
        when "ge" then "ge"
        else type_str.to_s.strip
        end
      end

      def cell_value(row, index)
        return nil if index.nil?
        return nil if row.length <= index

        val = row[index]
        return nil if val.is_a?(String) && val.strip.empty?
        val
      end

      def cell_value_str(row, index)
        val = cell_value(row, index)
        return nil if val.nil?
        val.to_s.strip.empty? ? nil : val.to_s.strip
      end
    end
  end
end
