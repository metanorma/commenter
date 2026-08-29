# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Commenter::GitHubSync do
  describe ".reconcile_actions" do
    def actions(**overrides)
      described_class.reconcile_actions(
        issue: { title: "Title", body: "Body", state: "open" },
        rendered: { title: "Title", body: "Body" },
        disposition: nil,
        **overrides
      )
    end

    it "reports nothing when the issue is in sync" do
      expect(actions).to eq([])
    end

    it "re-renders differing content under the yaml policy" do
      expect(actions(conflict: "yaml", issue: { title: "Title", body: "Old body", state: "open" })).to eq([:update_content])
    end

    it "keeps differing GitHub content under the github policy" do
      expect(actions(conflict: "github", issue: { title: "Title", body: "Edited on GitHub", state: "open" }))
        .to eq([:keep_github_content])
    end

    it "reports a conflict under the skip policy" do
      expect(actions(conflict: "skip", issue: { title: "Edited on GitHub", body: "Body", state: "open" })).to eq([:conflict])
    end

    it "closes an open issue whose comment has a disposition" do
      expect(actions(disposition: "Accepted.")).to eq([:close])
    end

    it "combines content update and close" do
      expect(actions(issue: { title: "Title", body: "Old", state: "open" }, disposition: "Accepted.")).to eq(%i[update_content close])
    end

    it "does not close a closed issue, an undispositioned comment, or when disabled" do
      expect(actions(disposition: "Accepted.", issue: { title: "Title", body: "Body", state: "closed" })).to eq([])
      expect(actions(disposition: "  ")).to eq([])
      expect(actions(disposition: "Accepted.", close_on_disposition: false)).to eq([])
    end

    it "ignores whitespace when comparing content" do
      expect(actions(issue: { title: "Title", body: "  Body  ", state: "open" })).to eq([])
    end
  end

  describe "#sync dry run" do
    let(:config_file) do
      file = Tempfile.new(["config", ".yaml"])
      file.write({ "github" => { "repository" => "test-org/test-repo", "token" => "test-token" } }.to_yaml)
      file.close
      file
    end

    def yaml_file(comments)
      file = Tempfile.new(["comments", ".yaml"])
      file.write({ "version" => "2012-03", "stage" => "DIS", "comments" => comments }.to_yaml)
      file.close
      file
    end

    after { config_file.unlink }

    it "plans creation for comments without issues and closure for dispositioned open ones" do
      input = yaml_file([
                          { "id" => "US-001", "body" => "US", "comments" => "No issue yet" },
                          { "id" => "US-002", "body" => "US", "comments" => "Resolved", "observations" => "Accepted.",
                            "github" => { "issue_number" => 12, "status" => "open" } }
                        ])

      sync = described_class.new(config_file.path)
      results = sync.sync(input.path, dry_run: true)

      expect(results[0]).to eq(comment_id: "US-001", actions: [:create])
      expect(results[1][:issue_number]).to eq(12)
      expect(results[1][:actions]).to include(:close)

      input.unlink
    end
  end
end
