# frozen_string_literal: true

require "roo"
require_relative "../comment_sheet"
require_relative "../comment"

module Commenter
  class Parser
    # Parser for ISO Online Standards Development (OSD) XLSX exports.
    #
    # Supports two variants, detected from the header row:
    #   - "resolved": single "Comments (N)" sheet with resolution data
    #     (columns: Comment ID, User name, Clause nb, ..., Resolution status,
    #     Motivation, Resolution Date, Stage code)
    #   - "unresolved": multi-sheet format with "Comments (N)",
    #     "Unresolved comments (N)", "Resolved comments (N)" sheets
    #     (columns: User name, Clause nb, ..., Comment type, Comment/Motivation,
    #     Comment on text, Proposal on Text, Proposed change, Replies,
    #     Resolution status, Justification, Resolution Date, Date, Comment number)
    #
    # Both variants share the same header structure in the first rows:
    #   Row 0: [Date, Reference, nil, "", Title EN, nil, nil, Title FR, ...]
    #   Row 1: ["2026-04-21", "ISO/DIS 5843-6(en)", ...]
    #   Row 2: empty
    #   Row 3: column headers
    #   Row 4+: data
    class OsdXlsxParser
      # Header names are mapped per variant onto common attribute keys so both
      # variants share a single comment builder. Headers are mapped by real
      # column position, tolerating gaps in the header row.
      RESOLVED_COLUMN_KEYS = {
        "Comment ID" => :id,
        "User name" => :user_name,
        "Clause nb" => :clause,
        "Clause Title" => :clause_title,
        "Subtype" => :comment_type,
        "Comment" => :comment_text,
        "Proposal on Text" => :proposal_on_text,
        "Proposed change" => :proposed_change,
        "Feedbacks" => :feedbacks,
        "Created Date" => :created_date,
        "Resolution status" => :resolution_status,
        "Motivation" => :motivation,
        "Resolution Date" => :resolution_date,
        "Stage code" => :stage_code
      }.freeze

      UNRESOLVED_COLUMN_KEYS = {
        "User name" => :user_name,
        "Clause nb" => :clause,
        "Clause Title" => :clause_title,
        "Comment type" => :comment_type,
        "Comment/Motivation" => :comment_text,
        "Proposal on Text" => :proposal_on_text,
        "Proposed change" => :proposed_change,
        "Replies" => :feedbacks,
        "Resolution status" => :resolution_status,
        "Justification" => :motivation,
        "Resolution Date" => :resolution_date,
        "Date" => :created_date,
        "Comment number" => :id
      }.freeze

      def parse(xlsx_path, options = {})
        xlsx = Roo::Spreadsheet.open(xlsx_path)

        sheet_name = select_sheet(xlsx, options)
        sheet = xlsx.sheet(sheet_name)
        header_row_num = find_header_row(sheet)
        variant = detect_variant(sheet.row(header_row_num))

        comments = parse_comments(sheet, header_row_num, variant, options)
        CommentSheet.new(version: "osd", **extract_metadata(xlsx, sheet_name), comments: comments)
      end

      private

      def select_sheet(xlsx, options)
        sheets = xlsx.sheets

        if options[:sheet]
          raise "Sheet '#{options[:sheet]}' not found. Available: #{sheets.join(", ")}" unless sheets.include?(options[:sheet])

          return options[:sheet]
        end

        if options[:resolved_only]
          sheets.find { |s| s.start_with?("Resolved") } || sheets.find { |s| s.start_with?("Comments") }
        elsif options[:unresolved_only]
          sheets.find { |s| s.start_with?("Unresolved") } || sheets.find { |s| s.start_with?("Comments") }
        else
          sheets.first # Default: first sheet (usually "Comments (N)" with all comments)
        end
      end

      def find_header_row(sheet)
        (1..10).each do |row_num|
          headers = sheet.row(row_num).to_a.compact.map(&:to_s)
          return row_num if headers.include?("User name") || headers.include?("Comment ID")
        end

        raise "Could not find header row in XLSX sheet"
      end

      def detect_variant(header_row)
        headers = header_row.to_a.compact.map(&:to_s)
        if headers.include?("Comment ID") || headers.include?("Subtype")
          :resolved
        elsif headers.include?("Comment/Motivation") || headers.include?("Comment type")
          :unresolved
        else
          headers.length >= 15 ? :resolved : :unresolved
        end
      end

      def extract_metadata(xlsx, sheet_name)
        values = xlsx.sheet(sheet_name).row(2)
        metadata = { date: nil, document: nil, project: nil, stage: nil, title_en: nil, title_fr: nil }
        return metadata if values.nil?

        metadata[:date] = header_value(values[0], "Date")

        reference = header_value(values[1], "Reference")
        if reference
          metadata[:document] = reference
          metadata[:stage] = extract_stage(reference)
          metadata[:project] = extract_project(reference)
        end

        metadata[:title_en] = header_value(values[4], "Title EN")
        metadata[:title_fr] = header_value(values[7], "Title FR")
        metadata
      end

      def header_value(raw, label)
        return nil if raw.nil?

        value = raw.is_a?(Date) ? raw.strftime("%Y-%m-%d") : raw.to_s.strip
        value.empty? || value == label ? nil : value
      end

      def extract_stage(reference)
        case reference
        when %r{/WD\b}i then "WD"
        when %r{/CD\b}i then "CD"
        when %r{/DIS\b}i then "DIS"
        when %r{/FDIS\b}i then "FDIS"
        end
      end

      def extract_project(reference)
        # Extract ISO number from reference like "ISO/DIS 5843-6(en)"
        match = reference.match(%r{(ISO[\s/]*\w*\s*\d+[\d-]*)})
        match ? match[1].strip.gsub(/\s+/, " ") : nil
      end

      def parse_comments(sheet, header_row_num, variant, options)
        column_keys = variant == :resolved ? RESOLVED_COLUMN_KEYS : UNRESOLVED_COLUMN_KEYS
        col_map = build_column_map(sheet.row(header_row_num), column_keys)

        comments = []
        (header_row_num + 1..sheet.last_row).each do |row_num|
          row = sheet.row(row_num)
          next if row.nil? || row.to_a.compact.empty?

          comment = build_comment(row, col_map, options)
          comments << comment if comment
        end
        comments
      end

      def build_column_map(header_row, column_keys)
        header_row.to_a.each_with_index.with_object({}) do |(header, index), map|
          key = column_keys[header.to_s.strip]
          map[key] = index if key
        end
      end

      def build_comment(row, col_map, options)
        id = cell_value(row, col_map[:id])
        return nil if id.nil?

        id_str = id.is_a?(Float) ? id.to_i.to_s : id.to_s
        comment_text = cell_value(row, col_map[:comment_text]) || ""
        return nil if comment_text.strip.empty? && id_str.empty?

        attrs = base_attributes(row, col_map, id_str, comment_text)
                .merge(resolution_attributes(row, col_map))
        attrs[:observations] = resolution_observations(row, col_map) unless options[:exclude_observations]
        Comment.new(attrs)
      end

      def base_attributes(row, col_map, id_str, comment_text)
        user_name = cell_value_str(row, col_map[:user_name]).to_s
        clause = cell_value_str(row, col_map[:clause]).to_s
        clause_title = cell_value_str(row, col_map[:clause_title]).to_s
        {
          id: id_str,
          body: user_name,
          locality: {
            clause: clause.empty? ? nil : clause,
            element: clause_title.empty? ? nil : clause_title
          }.compact,
          type: normalize_comment_type(cell_value_str(row, col_map[:comment_type]).to_s),
          comments: comment_text.to_s.strip,
          proposed_change: cell_value_str(row, col_map[:proposed_change]) ||
            cell_value_str(row, col_map[:proposal_on_text])
        }
      end

      def resolution_attributes(row, col_map)
        {
          user_name: cell_value_str(row, col_map[:user_name]).to_s,
          comment_type: cell_value_str(row, col_map[:comment_type]).to_s,
          resolution_status: cell_value_str(row, col_map[:resolution_status]),
          resolution_date: cell_value_str(row, col_map[:resolution_date]),
          feedbacks: cell_value_str(row, col_map[:feedbacks]),
          motivation: cell_value_str(row, col_map[:motivation]),
          created_date: cell_value_str(row, col_map[:created_date]),
          stage_code: cell_value_str(row, col_map[:stage_code])
        }
      end

      def resolution_observations(row, col_map)
        parts = [cell_value_str(row, col_map[:resolution_status]),
                 cell_value_str(row, col_map[:motivation])].compact
        parts.empty? ? nil : parts.join(". ")
      end

      def normalize_comment_type(type_str)
        case type_str.strip.downcase
        when "editorial", "ed" then "ed"
        when "technical", "te" then "te"
        when "general", "ge" then "ge"
        else type_str.strip
        end
      end

      def cell_value(row, index)
        return nil if index.nil? || row.length <= index

        value = row[index]
        value.is_a?(String) && value.strip.empty? ? nil : value
      end

      def cell_value_str(row, index)
        value = cell_value(row, index)
        value.nil? || value.to_s.strip.empty? ? nil : value.to_s.strip
      end
    end
  end
end
