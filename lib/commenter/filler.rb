# frozen_string_literal: true

require "docx"
require "zip"

module Commenter
  class Filler
    # Labels of the sheet metadata fields in the template's page header
    # (word/header*.xml). Values supplied to #fill are appended after each
    # label; the docx gem cannot write header parts (see docx PR #73), so
    # this is done by rewriting the entry directly.
    HEADER_METADATA = { date: "Date", document: "Document", project: "Project" }.freeze

    def fill(template_path, output_path, comments, options = {})
      doc = Docx::Document.open(template_path)
      table = doc.tables.first

      raise "No table found in template" unless table
      raise "Template table must have at least one row" if table.row_count < 1

      # The template row (first row in the table) is copied for each comment;
      # all original template rows are removed afterwards via their XML
      # nodes (the shipped 2012-03 template carries extra blank rows beyond
      # the first, and the docx gem's Row exposes no #remove).
      template_rows = table.rows.to_a
      comments.each { |comment| fill_row(template_rows.first, comment, options) }
      template_rows.each { |row| row.node.remove }

      doc.save(output_path)
      write_header_metadata(output_path, options)
      output_path
    end

    private

    def fill_row(template_row, comment, options)
      comment = Comment.from_hash(comment) unless comment.is_a?(Comment)

      new_row = template_row.copy
      new_row.insert_before(template_row)

      set_cell_text(new_row.cells[0], comment.id.to_s)
      set_cell_text(new_row.cells[1], comment.line_number.to_s)
      set_cell_text(new_row.cells[2], comment.clause.to_s)
      set_cell_text(new_row.cells[3], comment.element.to_s)
      set_cell_text(new_row.cells[4], comment.type.to_s)
      set_cell_text(new_row.cells[5], comment.comments.to_s)
      set_cell_text(new_row.cells[6], comment.proposed_change.to_s)

      observations = comment.observations.to_s
      return if observations.empty?

      set_cell_text(new_row.cells[7], observations)
      apply_shading(new_row.cells[7], observations) if options[:shading]
    rescue StandardError => e
      puts "Warning: Could not add row for comment #{comment.id}: #{e.message}"
    end

    def write_header_metadata(output_path, options)
      metadata = HEADER_METADATA.map do |key, label|
        value = options[key].to_s.strip
        value.empty? ? nil : [label, value]
      end.compact
      return if metadata.empty?

      rewrite_headers(output_path, metadata)
    end

    def rewrite_headers(output_path, metadata)
      # In-memory buffer + File.binwrite rather than rewriting the archive
      # in place: rubyzip commits in-place edits with File.rename, which
      # fails with EACCES on Windows.
      buffer = Zip::OutputStream.write_buffer do |out|
        Zip::File.open(output_path) do |zip|
          zip.entries.each do |entry|
            # Block form: the entry stream is closed eagerly, otherwise its
            # handle keeps the file locked on Windows and the binwrite below
            # fails with EACCES.
            content = entry.get_input_stream(&:read)
            out.put_next_entry(entry.name)
            out.write(patch_header(entry.name, content, metadata))
          end
        end
      end
      File.binwrite(output_path, buffer.string)
    end

    def patch_header(entry_name, content, metadata)
      return content unless entry_name.match?(%r{\Aword/header\d*\.xml\z})

      xml = content.dup.force_encoding(Encoding::UTF_8)
      metadata.each do |label, value|
        xml.sub!(%r{(<w:t[^>]*>)\s*#{label}:\s*(</w:t>)}) do
          "#{Regexp.last_match(1)}#{label}: #{escape(value)}#{Regexp.last_match(2)}"
        end
      end
      xml
    end

    def escape(text)
      text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    def set_cell_text(cell, text)
      return if text.nil? || text.empty?

      # Handle both empty cells and cells with existing text
      text_set = false

      cell.paragraphs.each do |paragraph|
        paragraph.each_text_run do |text_run|
          # Get current text and substitute it with new text
          current_text = text_run.text
          next unless current_text && !current_text.empty?

          text_run.substitute(current_text, text)
          text_set = true
          return # Only substitute in the first text run found
        end
      end

      # If no text runs with content were found, add text to the first paragraph
      if !text_set && cell.paragraphs.any?
        paragraph = cell.paragraphs.first
        # Try to add a text run to the paragraph
        if paragraph.respond_to?(:add_text)
          paragraph.add_text(text)
        elsif paragraph.respond_to?(:text=)
          paragraph.text = text
        end
      end
    rescue StandardError => e
      puts "Warning: Could not set text '#{text}' in cell: #{e.message}"
    end

    SHADING_COLORS = {
      accept_with_modifications: "C4D79B", # Olive Green
      accepted: "92D050", # Green
      noted: "8DB4E2", # Blue
      rejected: "FF99CC", # Pink
      todo: "D9D9D9" # Light Gray (for diagonal stripes, we use solid for now)
    }.freeze

    def determine_shading_color(observation)
      SHADING_COLORS[DispositionStatus.match(observation)]
    end

    def apply_shading(cell, observation)
      return unless observation && !observation.empty?

      # Determine shading color based on status patterns
      shading_color = determine_shading_color(observation)
      return unless shading_color

      puts "Applying #{shading_color} cell shading for: #{observation.strip}"

      # Apply shading to the table cell itself
      apply_cell_shading(cell, shading_color)
    rescue StandardError => e
      puts "Warning: Could not apply shading to cell: #{e.message}"
    end

    def apply_cell_shading(cell, color)
      # Access the cell's XML node
      cell_node = cell.node

      # Find or create the table cell properties (tcPr) element
      tcpr_node = cell_node.at_xpath(".//w:tcPr", "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

      unless tcpr_node
        # Create table cell properties if they don't exist
        tcpr_node = cell_node.document.create_element("tcPr")
        cell_node.prepend_child(tcpr_node)
      end

      # Remove existing shading if present
      existing_shd = tcpr_node.at_xpath(".//w:shd", "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
      existing_shd&.remove

      # Create new shading element for the cell
      shd_node = cell_node.document.create_element("shd")
      shd_node["w:val"] = "clear"
      shd_node["w:color"] = "auto"
      shd_node["w:fill"] = color

      # Add namespace declaration
      shd_node.namespace = cell_node.document.root.namespace_definitions.find { |ns| ns.prefix == "w" }

      # Add the shading to table cell properties
      tcpr_node.add_child(shd_node)
    end
  end
end
