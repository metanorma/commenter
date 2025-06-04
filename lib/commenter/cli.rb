# frozen_string_literal: true

require "thor"
require "yaml"
require "fileutils"
require "commenter/parser"
require "commenter/filler"
require "commenter/github_integration"

module Commenter
  class Cli < Thor
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
      FileUtils.cp(schema_source, schema_target) unless File.expand_path(schema_source) == File.expand_path(schema_target)

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

    desc "github-create INPUT.yaml", "Create GitHub issues from comments"
    option :config, type: :string, aliases: :c, required: true, desc: "GitHub configuration YAML file"
    option :output, type: :string, aliases: :o, desc: "Output YAML file (default: update original)"
    option :stage, type: :string, desc: "Override approval stage (WD/CD/DIS/FDIS/PRF/PUB)"
    option :milestone, type: :string, desc: "Override milestone name or number"
    option :assignee, type: :string, desc: "Override assignee GitHub handle"
    option :title_template, type: :string, desc: "Custom title template file"
    option :body_template, type: :string, desc: "Custom body template file"
    option :dry_run, type: :boolean, desc: "Preview issues without creating them"
    def github_create(input_yaml)
      creator = GitHubIssueCreator.new(
        options[:config],
        options[:title_template],
        options[:body_template]
      )

      github_options = {
        stage: options[:stage],
        milestone: options[:milestone],
        assignee: options[:assignee],
        dry_run: options[:dry_run],
        output: options[:output]
      }.compact

      results = creator.create_issues_from_yaml(input_yaml, github_options)

      if options[:dry_run]
        puts "DRY RUN - Preview of issues to be created:"
        puts "=" * 50
        results.each do |result|
          puts "\nComment ID: #{result[:comment_id]}"
          puts "Title: #{result[:title]}"
          puts "Labels: #{result[:labels].join(", ")}" if result[:labels]&.any?
          puts "Assignees: #{result[:assignees].join(", ")}" if result[:assignees]&.any?
          puts "Milestone: #{result[:milestone]}" if result[:milestone]
          puts "\nBody preview (first 200 chars):"
          puts result[:body][0...200] + (result[:body].length > 200 ? "..." : "")
          puts "-" * 30
        end
      else
        puts "GitHub issue creation results:"
        puts "=" * 40

        created_count = 0
        skipped_count = 0
        error_count = 0

        results.each do |result|
          case result[:status]
          when :created
            created_count += 1
            puts "✓ #{result[:comment_id]}: Created issue ##{result[:issue_number]}"
            puts "  URL: #{result[:issue_url]}"
          when :skipped
            skipped_count += 1
            puts "- #{result[:comment_id]}: Skipped (#{result[:message]})"
            puts "  URL: #{result[:issue_url]}" if result[:issue_url]
          when :error
            error_count += 1
            puts "✗ #{result[:comment_id]}: Error - #{result[:message]}"
          end
        end

        puts "\nSummary:"
        puts "Created: #{created_count}, Skipped: #{skipped_count}, Errors: #{error_count}"
      end
    rescue StandardError => e
      puts "Error: #{e.message}"
      exit 1
    end

    desc "github-retrieve INPUT.yaml", "Retrieve observations from GitHub issues"
    option :config, type: :string, aliases: :c, required: true, desc: "GitHub configuration YAML file"
    option :output, type: :string, aliases: :o, desc: "Output YAML file (default: update original)"
    option :include_open, type: :boolean, desc: "Include observations from open issues"
    option :dry_run, type: :boolean, desc: "Preview observations without updating"
    def github_retrieve(input_yaml)
      retriever = GitHubIssueRetriever.new(options[:config])

      retrieve_options = {
        output: options[:output],
        include_open: options[:include_open],
        dry_run: options[:dry_run]
      }.compact

      results = retriever.retrieve_observations_from_yaml(input_yaml, retrieve_options)

      if options[:dry_run]
        puts "DRY RUN - Preview of observations to be retrieved:"
        puts "=" * 50
        results.each do |result|
          puts "\nComment ID: #{result[:comment_id]}"
          puts "Issue ##{result[:issue_number]}: #{result[:status]}"
          if result[:observation]
            puts "Observation preview (first 200 chars):"
            puts result[:observation][0...200] + (result[:observation].length > 200 ? "..." : "")
          else
            puts "No observation found"
          end
          puts "-" * 30
        end
      else
        puts "GitHub observation retrieval results:"
        puts "=" * 40

        retrieved_count = 0
        skipped_count = 0
        error_count = 0

        results.each do |result|
          case result[:status]
          when :retrieved
            retrieved_count += 1
            puts "✓ #{result[:comment_id]}: Retrieved observation from issue ##{result[:issue_number]}"
          when :skipped
            skipped_count += 1
            puts "- #{result[:comment_id]}: Skipped (#{result[:message]})"
          when :error
            error_count += 1
            puts "✗ #{result[:comment_id]}: Error - #{result[:message]}"
          end
        end

        puts "\nSummary:"
        puts "Retrieved: #{retrieved_count}, Skipped: #{skipped_count}, Errors: #{error_count}"

        output_file = options[:output] || input_yaml
        puts "Updated YAML file: #{output_file}"
      end
    rescue StandardError => e
      puts "Error: #{e.message}"
      exit 1
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
