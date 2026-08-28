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
    # - locality.element is resolved from caption/inline references
    #   (Table N, Figure N, Formula (N), NOTE n) within the current clause
    # - observations can be stamped via the observations or accept_all options
    #
    # Reviewer comment threads (word/comments.xml w:comment) are emitted
    # after the track changes with -CNNN ids: the remark verbatim in
    # comments, its instruction reworded as the proposed change, and empty
    # observations for the owner to draft.
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
      ACCEPT_ALL = "Accepted. Tracked change accepted."

      attr_reader :skipped_markers

      def parse(path, options = {})
        body = options[:body] || DEFAULT_BODY
        changes = []
        remarks = {}
        anchors = {}
        @skipped_markers = 0

        Zip::File.open(path) do |zip|
          entry = zip.glob("word/document.xml").first
          raise Commenter::Error, "word/document.xml not found in #{path}" unless entry

          remarks = read_remarks(zip)
          changes = entry.get_input_stream { |stream| stream_changes(stream, anchors) }
        end

        CommentSheet.new(
          version: "2012-03",
          date: sheet_date(changes),
          document: options[:document],
          stage: options[:stage],
          comments: build_change_comments(changes, body, options) +
                    build_remark_comments(remarks, anchors, body, options)
        )
      end

      # Turns a reviewer's remark phrased as a request ("Please remove this
      # NOTE...") into the corresponding proposed change ("Remove this
      # NOTE...").
      def self.reword_remark(text)
        text.to_s.strip.sub(/\APlease\s+/i, "").sub(/\A[a-z]/, &:upcase)
      end

      private

      def read_remarks(zip)
        entry = zip.glob("word/comments.xml").first
        return {} unless entry

        document = entry.get_input_stream { |stream| Nokogiri::XML(stream) }
        document.xpath("//w:comment", "w" => W_NS).each_with_object({}) do |node, remarks|
          remarks[node["w:id"]] = {
            author: node["w:author"],
            date: node["w:date"],
            text: node.xpath(".//w:t", "w" => W_NS).map(&:text).join
          }
        end
      end

      def sheet_date(changes)
        dates = changes.filter_map { |change| change[:date].to_s[/\A\d{4}-\d{2}-\d{2}/] }
        dates.max
      end

      def build_change_comments(changes, body, options)
        changes.each_with_index.map do |change, index|
          kind = change[:kind]
          Comment.new(
            id: format("%<body>s-%03<index>d", body: body, index: index + 1),
            body: body,
            locality: { clause: change[:clause], line_number: nil, element: change[:element] },
            type: options[:type] || "te",
            comments: "Track change (#{KIND_COMMENT.fetch(kind, kind)})",
            proposed_change: "#{KIND_LABEL.fetch(kind, kind)}: \"#{change[:text].strip}\"",
            observations: observations_for(options)
          )
        end
      end

      def build_remark_comments(remarks, anchors, body, options)
        remarks.keys.sort_by(&:to_i).each_with_index.map do |remark_id, index|
          remark = remarks[remark_id]
          anchor = anchors[remark_id] || {}
          clause = anchor[:clause].to_s.empty? ? WHOLE_DOCUMENT : anchor[:clause]
          Comment.new(
            id: format("%<body>s-C%03<index>d", body: body, index: index + 1),
            body: body,
            locality: { clause: clause, line_number: nil, element: anchor[:element] },
            type: options[:remark_type] || "ed",
            comments: remark[:text],
            proposed_change: self.class.reword_remark(remark[:text]),
            observations: nil
          )
        end
      end

      def observations_for(options)
        return nil if options[:exclude_observations]

        options[:observations] || (options[:accept_all] ? ACCEPT_ALL : nil)
      end

      def stream_changes(io, anchors = {})
        changes = []
        change_stack = []
        paragraph = ParagraphState.new

        Nokogiri::XML::Reader(io).each do |reader|
          case reader.node_type
          when Nokogiri::XML::Reader::TYPE_ELEMENT
            handle_start(reader, change_stack, paragraph, anchors)
          when Nokogiri::XML::Reader::TYPE_TEXT, Nokogiri::XML::Reader::TYPE_SIGNIFICANT_WHITESPACE
            handle_text(reader, change_stack, paragraph)
          when Nokogiri::XML::Reader::TYPE_END_ELEMENT
            handle_end(reader, change_stack, paragraph, changes)
          end
        end

        changes
      end

      def handle_start(reader, change_stack, paragraph, anchors = {})
        case reader.local_name
        when "p"
          paragraph.begin_paragraph
        when "pStyle"
          paragraph.style = reader.attribute("w:val") || reader.attribute("val")
        when "ins", "del", "moveFrom", "moveTo"
          start_change(reader, change_stack, paragraph)
        when "commentRangeStart"
          anchor_remark(reader, paragraph, anchors)
        end
      end

      def anchor_remark(reader, paragraph, anchors)
        id = reader.attribute("w:id")
        anchors[id] = {
          clause: paragraph.pending_clause || paragraph.clause,
          element: paragraph.pending_element || paragraph.element
        }
      end

      def start_change(reader, change_stack, paragraph)
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
          clause: paragraph.clause,
          element: paragraph.element
        )
      end

      def handle_text(reader, change_stack, paragraph)
        if (current = change_stack.last)
          current[:text] << reader.value
        else
          paragraph.append_text(reader.value)
        end
      end

      def handle_end(reader, change_stack, paragraph, changes)
        case reader.local_name
        when "p"
          paragraph.commit_paragraph
        when "ins", "del", "moveFrom", "moveTo"
          change = change_stack.pop
          changes << finalize_change(change, paragraph) if change
        end
      end

      def finalize_change(change, paragraph)
        # A change inside a heading or caption paragraph belongs to that
        # paragraph, which is not committed yet at this point.
        change[:clause] = paragraph.pending_clause || change[:clause]
        change[:element] = paragraph.pending_element || change[:element]
        change[:clause] = WHOLE_DOCUMENT if change[:clause].to_s.empty?
        change
      end

      # Tracks the current paragraph's style and text to resolve the locality
      # context of a change:
      #
      # - clause: the clause number of the most recent heading paragraph; an
      #   unnumbered sub-heading inherits its parent heading's clause
      # - element: the nearest Table/Figure/Formula/NOTE reference, scoped to
      #   the current clause (caption paragraphs and inline mentions both
      #   count)
      class ParagraphState
        NUMBERED_CLAUSE = /\A(?:\d+(?:\.\d+)*|Annex\s+[A-Z](?:\.\d+)*|Bibliography|Foreword|Introduction)\z/i
        ELEMENT_START = /\A\s*(NOTE\s+\d+|NOTE(?=\s*[—:-])|Table\s+(?:[A-Z]\.)?\d+(?:\.\d+)*|Figure\s+(?:[A-Z]\.)?\d+(?:\.\d+)*)\b/i
        FORMULA = /\b(Formula\s*\(\d+(?:\.\d+)*\))/
        ELEMENT_ANY = /\b(Table\s+(?:[A-Z]\.)?\d+(?:\.\d+)*|Figure\s+(?:[A-Z]\.)?\d+(?:\.\d+)*|NOTE\s+\d+)\b/i

        attr_writer :style
        attr_reader :clause, :element

        def initialize
          @style = nil
          @text = +""
          @clause = ""
          @element = nil
          @heading_stack = []
        end

        def begin_paragraph
          @style = nil
          @text = +""
        end

        def append_text(value)
          @text << value
        end

        def pending_clause
          return unless heading_paragraph?

          clause = self.class.clause_for(@text)
          clause unless clause.empty?
        end

        def pending_element
          self.class.element_for(@text)
        end

        def commit_paragraph
          if heading_paragraph?
            commit_heading
          else
            @element = self.class.element_for(@text) || @element
          end
        end

        def heading_paragraph?
          @style&.match?(HEADING_STYLE)
        end

        def self.numbered_clause?(clause)
          clause.to_s.match?(NUMBERED_CLAUSE)
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

        # Resolves the element reference of a paragraph: a caption opening the
        # paragraph ("Table 3 — ...", "NOTE 2 ...", "Formula (9):") wins over an
        # inline mention ("the values in Table 5 shall ...").
        def self.element_for(text)
          s = text.to_s
          match = s.match(ELEMENT_START) || s.match(FORMULA) || s.match(ELEMENT_ANY)
          match[1].squeeze(" ").strip if match
        end

        private

        def commit_heading
          level = heading_level
          clause = self.class.clause_for(@text)
          clause = inherited_clause(level) unless self.class.numbered_clause?(clause)
          @heading_stack.pop while @heading_stack.last && @heading_stack.last[0] >= level
          @heading_stack << [level, clause]
          @clause = clause unless clause.empty?
          # Element references belong to the clause they appear in.
          @element = nil
        end

        def inherited_clause(level)
          parent = @heading_stack.reverse.find { |(lvl, _)| lvl < level }
          parent ? parent[1] : ""
        end

        def heading_level
          m = @style.match(/\A(?:Heading|h)(\d+)/i)
          m ? m[1].to_i : 1
        end
      end
    end
  end
end
