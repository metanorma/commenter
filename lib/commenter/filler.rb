# frozen_string_literal: true

require "docx"

module Commenter
  class Filler
    def fill(template_path, output_path, comments, options = {})
      doc = Docx::Document.open(template_path)
      table = doc.tables.first

      raise "No table found in template" unless table
      raise "Template table must have at least one row" if table.row_count < 1

      # Get the template row (first row in the table)
      template_row = table.rows.first

      # Add new rows for each comment by copying the template row
      comments.each_with_index do |comment, index|
        # Convert comment to symbol keys for consistent access
        comment_data = symbolize_keys(comment)

        # Copy the template row and insert it
        begin
          new_row = template_row.copy
          new_row.insert_before(template_row)
          row = new_row
        rescue => e
          puts "Warning: Could not add row for comment #{comment_data[:id]}: #{e.message}"
          next
        end

        # Map comment to table cells using text substitution
        set_cell_text(row.cells[0], comment_data[:id] || "")
        set_cell_text(row.cells[1], comment_data.dig(:locality, :line_number) || "")
        set_cell_text(row.cells[2], comment_data.dig(:locality, :clause) || "")
        set_cell_text(row.cells[3], comment_data.dig(:locality, :element) || "")
        set_cell_text(row.cells[4], comment_data[:type] || "")
        set_cell_text(row.cells[5], comment_data[:comments] || "")
        set_cell_text(row.cells[6], comment_data[:proposed_change] || "")

        # Handle observations with optional shading
        observations = comment_data[:observations]
        if observations && !observations.empty?
          set_cell_text(row.cells[7], observations)
          apply_shading(row.cells[7], observations) if options[:shading]
        end
      end

      # Remove the original template row after all comments are added
      template_row.remove if template_row.respond_to?(:remove)

      doc.save(output_path)
    end

    private

    def set_cell_text(cell, text)
      return if text.nil? || text.empty?

      # Handle both empty cells and cells with existing text
      text_set = false

      cell.paragraphs.each do |paragraph|
        paragraph.each_text_run do |text_run|
          # Get current text and substitute it with new text
          current_text = text_run.text
          if current_text && !current_text.empty?
            text_run.substitute(current_text, text)
            text_set = true
            return # Only substitute in the first text run found
          end
        end
      end

      # If no text runs with content were found, add text to the first paragraph
      unless text_set
        if cell.paragraphs.any?
          paragraph = cell.paragraphs.first
          # Try to add a text run to the paragraph
          if paragraph.respond_to?(:add_text)
            paragraph.add_text(text)
          elsif paragraph.respond_to?(:text=)
            paragraph.text = text
          end
        end
      end
    rescue => e
      puts "Warning: Could not set text '#{text}' in cell: #{e.message}"
    end

    def symbolize_keys(hash)
      return hash unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(key, value), result|
        new_key = key.to_sym
        new_value = value.is_a?(Hash) ? symbolize_keys(value) : value
        result[new_key] = new_value
      end
    end

    def apply_shading(cell, observation)
      # Shading functionality is not fully supported by the docx gem
      # This is a placeholder for future implementation
      puts "Shading requested for: #{observation}" if observation
    end
  end
end
