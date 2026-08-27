# frozen_string_literal: true

require "zip"
require "nokogiri"
require_relative "../comment"
require_relative "../comment_sheet"

module Commenter
  class Parser
    # Extracts tracked changes from a redlined Word document into an ISO
    # 2012-03 comment sheet.
    #
    # Captured track changes (w:ins, w:del, w:moveFrom, w:moveTo):
    # - proposed_change renders the change itself, e.g. +Insert: "text"+
    # - locality.clause is resolved from the nearest preceding heading
    # - observations can be stamped via the observations option
    #
    # Self-closing markers (paragraph-mark insertions inside rPr) carry no
    # content and are skipped.
    #
    # word/document.xml is streamed with Nokogiri::XML::Reader because redline
    # documents can exceed 100 MB.
    class TrackChangeDocxParser
      W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

      HEADING_STYLE = /\A(?:Heading[1-6]|h[2-5]annex\d*|ANNEX|BaseHeading)\z/i
      KIND_COMMENT = { "ins" => "insertion", "del" => "deletion", "moveFrom" => "move (from)",
                       "moveTo" => "move (to)" }.freeze
      KIND_LABEL = { "ins" => "Insert", "del" => "Delete", "moveFrom" => "Move from",
                     "moveTo" => "Move to" }.freeze

      DEFAULT_BODY = "CS"
      WHOLE_DOCUMENT = "_whole document"

      attr_reader :skipped_markers

      def parse(path, options = {})
        body = options[:body] || DEFAULT_BODY
        changes = []
        @skipped_markers = 0

        Zip::File.open(path) do |zip|
          entry = zip.glob("word/document.xml").first
          raise Commenter::Error, "word/document.xml not found in #{path}" unless entry

          changes = stream_changes(entry.get_input_stream)
        end

        CommentSheet.new(
          version: "2012-03",
          date: sheet_date(changes),
          document: options[:document],
          stage: options[:stage],
          comments: build_comments(changes, body, options)
        )
      end

      private

      def sheet_date(changes)
        changes.filter_map { |change| change[:date].to_s[/\A\d{4}-\d{2}-\d{2}/] }.max
      end

      def build_comments(changes, body, options)
        changes.each_with_index.map do |change, index|
          kind = change[:kind]
          Comment.new(
            id: format("%<body>s-%03<index>d", body: body, index: index + 1),
            body: body,
            locality: { clause: change[:clause], line_number: nil, element: nil },
            type: options[:type] || "te",
            comments: "Track change (#{KIND_COMMENT.fetch(kind, kind)})",
            proposed_change: "#{KIND_LABEL.fetch(kind, kind)}: \"#{change[:text].strip}\"",
            observations: observations_for(options)
          )
        end
      end

      def observations_for(options)
        return nil if options[:exclude_observations]

        options[:observations]
      end

      def stream_changes(io)
        changes = []
        change_stack = []
        heading = HeadingState.new

        Nokogiri::XML::Reader(io).each do |reader|
          case reader.node_type
          when Nokogiri::XML::Reader::TYPE_ELEMENT
            handle_start(reader, change_stack, heading)
          when Nokogiri::XML::Reader::TYPE_TEXT, Nokogiri::XML::Reader::TYPE_SIGNIFICANT_WHITESPACE
            handle_text(reader, change_stack, heading)
          when Nokogiri::XML::Reader::TYPE_END_ELEMENT
            handle_end(reader, change_stack, heading, changes)
          end
        end

        changes
      end

      def handle_start(reader, change_stack, heading)
        case reader.local_name
        when "p"
          heading.begin_paragraph
        when "pStyle"
          heading.style = reader.attribute("w:val") || reader.attribute("val")
        when "ins", "del", "moveFrom", "moveTo"
          start_change(reader, change_stack, heading)
        end
      end

      def start_change(reader, change_stack, heading)
        if reader.empty_element?
          @skipped_markers += 1
          return
        end

        change_stack.push(
          kind: reader.local_name,
          id: reader.attribute("w:id"),
          author: reader.attribute("w:author"),
          date: reader.attribute("w:date"),
          text: +"",
          clause: heading.clause
        )
      end

      def handle_text(reader, change_stack, heading)
        if (current = change_stack.last)
          current[:text] << reader.value
        else
          heading.append_text(reader.value)
        end
      end

      def handle_end(reader, change_stack, heading, changes)
        case reader.local_name
        when "p"
          heading.commit_paragraph
        when "ins", "del", "moveFrom", "moveTo"
          change = change_stack.pop
          changes << finalize_change(change, heading) if change
        end
      end

      def finalize_change(change, heading)
        # A change inside a heading paragraph belongs to that heading, which
        # is not committed yet at this point.
        change[:clause] = heading.pending_clause || change[:clause]
        change[:clause] = WHOLE_DOCUMENT if change[:clause].to_s.empty?
        change
      end

      # Tracks the current paragraph's style and text to resolve the clause
      # context: the clause number of the most recent heading paragraph.
      class HeadingState
        attr_writer :style
        attr_reader :clause

        def initialize
          @style = nil
          @text = +""
          @clause = ""
        end

        def begin_paragraph
          @style = nil
          @text = +""
        end

        def append_text(value)
          @text << value if heading_paragraph?
        end

        def pending_clause
          return unless heading_paragraph?

          clause = self.class.clause_for(@text)
          clause unless clause.empty?
        end

        def commit_paragraph
          clause = pending_clause
          @clause = clause if clause
        end

        def heading_paragraph?
          @style&.match?(HEADING_STYLE)
        end

        # Extracts the clause identifier from heading text: the leading number
        # ("4.2.1 Thermodynamic ..." -> "4.2.1"), an annex reference, or a
        # well-known unnumbered section. Runs may be concatenated without
        # spaces ("4.2.1Thermodynamic"), so the number is matched with a
        # lookahead.
        def self.clause_for(text)
          s = text.to_s.strip
          return "" if s.empty?

          return Regexp.last_match(1) if s =~ /\A\s*(Annex\s+[A-Z](?:\.\d+)*)\b/i
          return Regexp.last_match(1) if s =~ /\A\s*(Bibliography|Foreword|Introduction)\b/i
          return Regexp.last_match(1) if s =~ /\A\s*((?:\d+\.)*\d+)(?=[A-Z\s])/
          return Regexp.last_match(1) if s =~ /\A\s*((?:\d+\.)*\d+)\b/

          s
        end
      end
    end
  end
end
