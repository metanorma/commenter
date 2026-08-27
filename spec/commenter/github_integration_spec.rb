# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "yaml"

RSpec.describe Commenter::GitHubIssueCreator do
  let(:config_data) do
    {
      "github" => {
        "repository" => "test-org/test-repo",
        "token" => "test-token",
        "default_labels" => ["comment-review"],
        "stage_labels" => {
          "DIS" => ["draft-international-standard"]
        },
        "default_assignee" => "test-assignee",
        "milestone" => {
          "name" => "Test Milestone"
        }
      }
    }
  end

  let(:config_file) do
    file = Tempfile.new(["config", ".yaml"])
    file.write(config_data.to_yaml)
    file.close
    file
  end

  let(:title_template_file) do
    file = Tempfile.new(["title", ".liquid"])
    file.write("{{ comment_id }}: {{ brief_summary }}")
    file.close
    file
  end

  let(:body_template_file) do
    file = Tempfile.new(["body", ".liquid"])
    file.write("Comment: {{ comments }}\nType: {{ type_full_name }}")
    file.close
    file
  end

  let(:yaml_data) do
    {
      "version" => "2012-03",
      "stage" => "DIS",
      "document" => "Test Document",
      "project" => "Test Project",
      "comments" => [
        {
          "id" => "US-001",
          "body" => "US",
          "locality" => {
            "clause" => "5.1",
            "element" => "Table 1"
          },
          "type" => "te",
          "comments" => "Test comment text",
          "proposed_change" => "Test proposed change"
        }
      ]
    }
  end

  let(:yaml_file) do
    file = Tempfile.new(["comments", ".yaml"])
    file.write(yaml_data.to_yaml)
    file.close
    file
  end

  after do
    config_file.unlink
    title_template_file.unlink
    body_template_file.unlink
    yaml_file.unlink
  end

  describe "#initialize" do
    it "loads configuration and creates GitHub client" do
      expect { described_class.new(config_file.path, title_template_file.path, body_template_file.path) }
        .not_to raise_error
    end

    it "raises error when config file not found" do
      expect { described_class.new("nonexistent.yaml") }
        .to raise_error("Configuration file not found: nonexistent.yaml")
    end

    it "raises error when repository not specified" do
      config_without_repo = config_data.dup
      config_without_repo["github"].delete("repository")

      file = Tempfile.new(["config", ".yaml"])
      file.write(config_without_repo.to_yaml)
      file.close

      expect { described_class.new(file.path) }
        .to raise_error("GitHub repository not specified in config")

      file.unlink
    end
  end

  describe "#create_issues_from_yaml" do
    let(:creator) { described_class.new(config_file.path, title_template_file.path, body_template_file.path) }

    context "with dry_run option" do
      it "returns preview data without creating issues" do
        results = creator.create_issues_from_yaml(yaml_file.path, dry_run: true)

        expect(results).to be_an(Array)
        expect(results.length).to eq(1)

        result = results.first
        expect(result[:comment_id]).to eq("US-001")
        expect(result[:title]).to eq("US-001: Clause 5.1, Table 1: Test comment text")
        expect(result[:body]).to include("Comment: Test comment text")
        expect(result[:body]).to include("Type: Technical")
        expect(result[:labels]).to include("comment-review", "draft-international-standard", "technical")
        expect(result[:assignees]).to eq(["test-assignee"])
      end
    end

    it "processes stage override" do
      results = creator.create_issues_from_yaml(yaml_file.path, dry_run: true, stage: "CD")

      result = results.first
      expect(result[:labels]).not_to include("draft-international-standard")
    end
  end

  describe "template variable generation" do
    let(:creator) { described_class.new(config_file.path, title_template_file.path, body_template_file.path) }
    let(:title_template_file) do
      file = Tempfile.new(["title", ".liquid"])
      file.write("{{ stage }}|{{ document }}|{{ project }}|{{ version }}|{{ comment_id }}|{{ type }}|" \
                 "{{ type_full_name }}|{{ clause }}|{{ element }}|{{ line_number }}|" \
                 "{{ has_observations }}|{{ has_proposed_change }}|{{ locality_summary }}|{{ unique_id }}")
      file.close
      file
    end

    it "exposes sheet, comment, and computed variables to templates" do
      result = creator.create_issues_from_yaml(yaml_file.path, dry_run: true).first
      variables = result[:title].split("|")

      expect(variables).to eq(
        [
          "DIS", "Test Document", "Test Project", "2012-03", "US-001", "technical",
          "Technical", "5.1", "Table 1", "", "false", "true", "Clause 5.1, Table 1", "[DIS] US-001"
        ]
      )
    end
  end

  describe "label determination" do
    let(:creator) { described_class.new(config_file.path, title_template_file.path, body_template_file.path) }

    it "combines default, stage-specific, and comment type labels without duplicates" do
      result = creator.create_issues_from_yaml(yaml_file.path, dry_run: true).first
      labels = result[:labels]

      expect(labels).to include("comment-review", "draft-international-standard", "technical")
      expect(labels.uniq).to eq(labels)
    end
  end
end

RSpec.describe Commenter::GitHubIssueRetriever do
  let(:config_file) do
    file = Tempfile.new(["config", ".yaml"])
    file.write({ "github" => { "repository" => "test-org/test-repo", "token" => "test-token" } }.to_yaml)
    file.close
    file
  end

  let(:osd_yaml_file) do
    file = Tempfile.new(["comments", ".yaml"])
    file.write({
      "version" => "osd",
      "document" => "ISO/DIS 5843-6(en)",
      "stage" => "DIS",
      "comments" => [
        {
          "id" => "1",
          "body" => "John Doe",
          "locality" => { "clause" => "5.2.1" },
          "type" => "editorial",
          "comments" => "The values in Table 3 are inconsistent."
        }
      ]
    }.to_yaml)
    file.close
    file
  end

  after do
    config_file.unlink
    osd_yaml_file.unlink
  end

  describe "#retrieve_observations_from_yaml" do
    it "rewrites the YAML with the schema header matching its version" do
      retriever = described_class.new(config_file.path)

      retriever.retrieve_observations_from_yaml(osd_yaml_file.path)

      expect(osd_yaml_file.open.read.lines.first)
        .to eq("# yaml-language-server: $schema=schema/iso_comment_osd.yaml\n")
    end
  end
end
