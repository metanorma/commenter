# frozen_string_literal: true

require "thor"
require "yaml"
require "fileutils"
require "commenter/parser"
require "commenter/filler"

module Commenter
  class CLI < Thor
    desc "import INPUT.docx", "Convert DOCX comment sheet to YAML"
    option :output, type: :string, aliases: :o, default: "comments.yaml", desc: "Output YAML file"
    option :exclude_observations, type: :boolean, aliases: :e, desc: "Exclude observations column"
    option :schema_dir, type: :string, default: "schema", desc: "Directory for schema file"
    def import(input_docx)
      output_yaml = options[:output]
      schema_dir = options[:schema_dir]

      # Ensure schema directory exists
      FileUtils.mkdir_p(schema_dir) unless Dir.exist?(schema_dir)

      # Parse the DOCX file
      parser = Parser.new
      comment_sheet = parser.parse(input_docx, options)

      # Write the YAML data file with schema reference
      yaml_content = generate_yaml_with_header(comment_sheet.to_yaml_h, schema_dir)
      File.write(output_yaml, yaml_content)

      # Copy schema file to output directory
      schema_source = File.join(__dir__, "../../schema/iso_comment_2012-03.yaml")
      schema_target = File.join(schema_dir, "iso_comment_2012-03.yaml")

      # Only copy if source and target are different
      unless File.expand_path(schema_source) == File.expand_path(schema_target)
        FileUtils.cp(schema_source, schema_target)
      end

      puts "Converted #{input_docx} to #{output_yaml}"
      puts "Schema file created at #{schema_target}"
    end

    desc "fill INPUT.yaml", "Fill DOCX template from YAML comments"
    option :output, type: :string, aliases: :o, default: "filled_comments.docx", desc: "Output DOCX file"
    option :template, type: :string, aliases: :t, desc: "Custom template file"
    option :shading, type: :boolean, aliases: :s, desc: "Apply status-based shading"
    def fill(input_yaml)
      output_docx = options[:output]

      # Load YAML data
      data = YAML.load_file(input_yaml)

      # Extract comments from the structure
      comments = if data.is_a?(Hash)
                   data["comments"] || data[:comments] || []
                 else
                   data || []
                 end

      raise "No comments found in YAML file" if comments.empty?

      # Use default template if none specified
      template_path = options[:template] || File.join(__dir__, "../../data/iso_comment_template_2012-03.docx")

      # Fill the template
      Filler.new.fill(template_path, output_docx, comments, options)
      puts "Filled template to #{output_docx}"
    end

    def self.exit_on_failure?
      true
    end

    private

    def generate_yaml_with_header(data, schema_dir)
      schema_path = File.join(schema_dir, "iso_comment_2012-03.yaml")
      header = "# yaml-language-server: $schema=#{schema_path}\n\n"
      header + data.to_yaml
    end
  end
end
