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
        expect(result[:labels]).to include("comment-review", "draft-international-standard", "te")
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
    let(:comment_sheet) { Commenter::CommentSheet.from_hash(yaml_data) }
    let(:comment) { comment_sheet.comments.first }

    it "generates correct template variables" do
      variables = creator.send(:template_variables, comment, comment_sheet)

      expect(variables["stage"]).to eq("DIS")
      expect(variables["document"]).to eq("Test Document")
      expect(variables["comment_id"]).to eq("US-001")
      expect(variables["type"]).to eq("te")
      expect(variables["type_full_name"]).to eq("Technical")
      expect(variables["clause"]).to eq("5.1")
      expect(variables["element"]).to eq("Table 1")
      expect(variables["comments"]).to eq("Test comment text")
      expect(variables["brief_summary"]).to include("Clause 5.1")
      expect(variables["has_proposed_change"]).to be true
    end
  end

  describe "label determination" do
    let(:creator) { described_class.new(config_file.path, title_template_file.path, body_template_file.path) }
    let(:comment_sheet) { Commenter::CommentSheet.from_hash(yaml_data) }
    let(:comment) { comment_sheet.comments.first }

    it "combines default, stage-specific, and comment type labels" do
      labels = creator.send(:determine_labels, comment, comment_sheet)

      expect(labels).to include("comment-review") # default
      expect(labels).to include("draft-international-standard") # stage-specific
      expect(labels).to include("te") # comment type
      expect(labels.uniq).to eq(labels) # no duplicates
    end
  end

  describe "comment type expansion" do
    let(:creator) { described_class.new(config_file.path, title_template_file.path, body_template_file.path) }

    it "expands comment type codes correctly" do
      expect(creator.send(:expand_comment_type, "ge")).to eq("General")
      expect(creator.send(:expand_comment_type, "te")).to eq("Technical")
      expect(creator.send(:expand_comment_type, "ed")).to eq("Editorial")
      expect(creator.send(:expand_comment_type, "unknown")).to eq("unknown")
      expect(creator.send(:expand_comment_type, nil)).to eq("Unknown")
    end
  end
end
