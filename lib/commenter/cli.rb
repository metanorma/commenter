# frozen_string_literal: true

require "thor"
require "yaml"
require "fileutils"
require "commenter"

module Commenter
  class Cli < Thor
    desc "import INPUT", "Convert comment sheet (DOCX or XLSX) or redline DOCX to YAML"
    option :output, type: :string, aliases: :o, default: "comments.yaml", desc: "Output YAML file"
    option :exclude_observations, type: :boolean, aliases: :e, desc: "Exclude observations column"
    option :schema_dir, type: :string, default: "schema", desc: "Directory for schema file"
    option :format, type: :string, desc: "Force input format (docx, xlsx or redline)"
    option :sheet, type: :string, desc: "XLSX sheet name to parse (default: first sheet)"
    option :resolved_only, type: :boolean, desc: "XLSX: use resolved comments sheet only"
    option :unresolved_only, type: :boolean, desc: "XLSX: use unresolved comments sheet only"
    option :body, type: :string, desc: "Redline: member body code for comment IDs (default: CS)"
    option :observations, type: :string, desc: "Redline: observations stamped on all track changes"
    option :accept_all, type: :boolean, desc: "Redline: stamp 'Accepted. Tracked change accepted.' on all track changes"
    option :document, type: :string, desc: "Redline: document identifier (e.g. ISO 2533:2026)"
    option :stage, type: :string, desc: "Redline: approval stage (e.g. DIS)"
    def import(input_file)
      # Parse the input file
      comment_sheet = Parser.new.parse(input_file, options)

      schema_target = write_sheet(comment_sheet, options[:output], options[:schema_dir])

      puts "Converted #{input_file} to #{options[:output]}"
      puts "  Version: #{comment_sheet.version}"
      puts "  Comments: #{comment_sheet.comments.length}"
      puts "  Schema: #{schema_target}"
    end

    desc "merge INPUT.yaml...", "Merge multiple comment sheets into one ballot sheet"
    option :output, type: :string, aliases: :o, default: "merged.yaml", desc: "Output YAML file"
    option :schema_dir, type: :string, default: "schema", desc: "Directory for schema file"
    def merge(*input_files)
      raise "At least one input file is required" if input_files.empty?

      sheets = input_files.map { |path| CommentSheet.from_yaml(File.read(path)) }
      comment_sheet = Ballot.new(sheets).merge
      write_sheet(comment_sheet, options[:output], options[:schema_dir])

      puts "Merged #{input_files.length} files (#{comment_sheet.comments.length} comments) to #{options[:output]}"
    end

    desc "stats INPUT.yaml", "Disposition statistics for ballot reports"
    option :output, type: :string, aliases: :o, desc: "Output file (default: stdout)"
    option :format, type: :string, default: "markdown", enum: %w[markdown yaml], desc: "Report format"
    def stats(input_yaml)
      comment_sheet = CommentSheet.from_yaml(File.read(input_yaml))

      report = if options[:format] == "yaml"
                 BallotReport.counts(comment_sheet).to_yaml
               else
                 BallotReport.to_markdown(comment_sheet)
               end

      if options[:output]
        File.write(options[:output], report)
        puts "Wrote statistics to #{options[:output]}"
      else
        puts report
      end
    end

    desc "fill INPUT.yaml", "Fill DOCX template from YAML comments"
    option :output, type: :string, aliases: :o, default: "filled_comments.docx", desc: "Output DOCX file"
    option :template, type: :string, aliases: :t, desc: "Custom template file"
    option :shading, type: :boolean, aliases: :s, desc: "Apply status-based shading"
    def fill(input_yaml)
      output_docx = options[:output]

      comment_sheet = CommentSheet.from_yaml(File.read(input_yaml))
      comments = comment_sheet.comments
      raise "No comments found in YAML file" if comments.empty?

      # Use default template if none specified
      template_path = options[:template] || File.join(__dir__, "../../data/iso_comment_template_2012-03.docx")

      # Fill the template, including the sheet metadata in the page header
      fill_options = options.merge(
        date: comment_sheet.date,
        document: comment_sheet.document,
        project: comment_sheet.project
      ).compact
      Filler.new.fill(template_path, output_docx, comments, fill_options)
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

    desc "github-sync INPUT.yaml", "Synchronize comments with GitHub issues (YAML is the source of truth)"
    option :config, type: :string, aliases: :c, required: true, desc: "GitHub configuration YAML file"
    option :output, type: :string, aliases: :o, desc: "Output YAML file (default: update original)"
    option :stage, type: :string, desc: "Override approval stage (WD/CD/DIS/FDIS/PRF/PUB)"
    option :milestone, type: :string, desc: "Override milestone name or number"
    option :assignee, type: :string, desc: "Override assignee GitHub handle"
    option :title_template, type: :string, desc: "Custom title template"
    option :body_template, type: :string, desc: "Custom body template"
    option :dry_run, type: :boolean, desc: "Preview sync actions without applying them"
    option :conflict, type: :string, default: "yaml", enum: %w[yaml github skip],
                      desc: "Conflict policy: yaml re-renders the issue, " \
                            "github keeps the issue content, skip reports and leaves it"
    option :close_on_disposition, type: :boolean, default: true,
                                  desc: "Close open issues whose comment has a recorded " \
                                        "disposition"
    def github_sync(input_yaml)
      sync = GitHubSync.new(options[:config], options[:title_template], options[:body_template])

      sync_options = {
        stage: options[:stage],
        milestone: options[:milestone],
        assignee: options[:assignee],
        conflict: options[:conflict],
        close_on_disposition: options[:close_on_disposition],
        dry_run: options[:dry_run],
        output: options[:output]
      }.compact
      results = sync.sync(input_yaml, sync_options)

      if options[:dry_run]
        puts "DRY RUN - Planned sync actions:"
        puts "=" * 50
        results.each do |result|
          issue = result[:issue_number] ? "issue ##{result[:issue_number]}" : "no issue yet"
          puts "#{result[:comment_id]} (#{issue}): #{result[:actions].join(", ")}"
        end
        puts "-" * 30
        puts "Based on the issue state last recorded in the YAML; run without --dry-run for a live pass."
      else
        puts "GitHub sync results:"
        puts "=" * 40
        results.each do |result|
          case result[:status]
          when :created then puts "\u2713 #{result[:comment_id]}: Created issue ##{result[:issue_number]} " \
                                   "(#{result[:issue_url]})"
          when :updated then puts "\u21bb #{result[:comment_id]}: Updated issue ##{result[:issue_number]} " \
                                   "(#{result[:actions].join(", ")})"
          when :closed then puts "\u2713 #{result[:comment_id]}: Closed issue ##{result[:issue_number]} (disposition recorded)"
          when :updated_and_closed then puts "\u21bb\u2713 #{result[:comment_id]}: Updated and closed issue ##{result[:issue_number]}"
          when :unchanged then puts "- #{result[:comment_id]}: Issue ##{result[:issue_number]} in sync"
          when :error then puts "\u2717 #{result[:comment_id]}: Error - #{result[:message]}"
          end
        end
        puts "Updated YAML file: #{options[:output] || input_yaml}"
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

    def write_sheet(comment_sheet, output_yaml, schema_dir)
      FileUtils.mkdir_p(schema_dir) unless Dir.exist?(schema_dir)
      File.write(output_yaml, comment_sheet.to_yaml_document(schema_dir))

      schema_name = comment_sheet.schema_name
      schema_source = File.join(__dir__, "../../schema/#{schema_name}")
      schema_target = File.join(schema_dir, schema_name)
      FileUtils.cp(schema_source, schema_target) unless File.expand_path(schema_source) == File.expand_path(schema_target)
      schema_target
    end
  end
end
