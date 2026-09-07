# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "yaml"

FakeIssue = Struct.new(:number, :title, :body, :html_url, :state, :created_at, keyword_init: true)
FakeSearchResults = Struct.new(:items, keyword_init: true)
FakeMilestone = Struct.new(:number, :title, keyword_init: true)
MarkerIssue = Struct.new(:number, :html_url, :title, :body, :state, :created_at, keyword_init: true)
MarkerResults = Struct.new(:items, keyword_init: true)
RetrieverIssue = Struct.new(:number, :state, keyword_init: true)
RetrieverComment = Struct.new(:body, keyword_init: true)

# Real stand-in for the Octokit surface github-create uses: a seeded issue
# store plus counters, so duplicate-prevention and retry behavior is
# exercised against an object with the same protocol as Octokit::Client.
class FakeGitHubClient
  attr_accessor :rate_limit_failures, :search_error
  attr_reader :created

  def initialize(existing_issues = [])
    @issues = {}
    existing_issues.each { |issue| @issues[issue.number] = issue }
    @next_number = @issues.keys.max.to_i
    @created = []
    @rate_limit_failures = 0
  end

  def issue(_repo, number)
    @issues.fetch(number) { raise Octokit::NotFound }
  end

  def search_issues(query)
    raise search_error if search_error

    if (marker = query[/in:body "(.+)"\z/, 1])
      FakeSearchResults.new(items: @issues.values.select { |i| i.body.to_s.include?(marker) })
    else
      unique_id = query[/in:title "(.+)"\z/, 1]
      FakeSearchResults.new(items: @issues.values.select { |i| i.title.include?(unique_id) })
    end
  end

  def milestones(_repo, _options = {})
    [FakeMilestone.new(number: 1, title: "Test Milestone")]
  end

  def create_issue(_repo, title, body, _options = {})
    if @rate_limit_failures.positive?
      @rate_limit_failures -= 1
      rate_limited = Octokit::TooManyRequests.new(rate_limited_response)
      raise rate_limited
    end

    @next_number += 1
    issue = FakeIssue.new(number: @next_number, title: title, body: body,
                          html_url: "https://example.test/issues/#{@next_number}",
                          state: "open", created_at: "2026-09-07T00:00:00Z")
    @issues[issue.number] = issue
    @created << issue
    issue
  end

  private

  # Mirrors the response hash Octokit builds from a real 403.
  def rate_limited_response
    {
      status: 403,
      body: "You have exceeded a secondary rate limit and have been " \
            "temporarily blocked from content creation."
    }
  end
end

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

    context "with an injected client, without dry run" do
      before do
        stub_const("Commenter::GitHubIssueCreator::THROTTLE_SECONDS", 0)
        stub_const("Commenter::GitHubIssueCreator::RATE_LIMIT_RETRY_DELAY", 0)
      end

      def write_sheet(comments)
        data = yaml_data
        data["comments"] = comments
        file = Tempfile.new(["comments", ".yaml"])
        file.write(data.to_yaml)
        file.close
        file
      end

      def seeded_issue(number, title)
        FakeIssue.new(number: number, title: title,
                      html_url: "https://example.test/issues/#{number}",
                      state: "open", created_at: "2026-09-06T00:00:00Z")
      end

      it "skips creation when the YAML records a matching issue" do
        client = FakeGitHubClient.new([seeded_issue(7, "[DIS] US-001: already posted")])
        sheet = write_sheet([yaml_data["comments"].first.merge("github" => { "issue_number" => 7 })])
        creator = described_class.new(config_file.path, title_template_file.path,
                                      body_template_file.path, client: client)

        results = creator.create_issues_from_yaml(sheet.path)

        expect(results.first[:status]).to eq(:skipped)
        expect(results.first[:issue_number]).to eq(7)
        expect(results.first[:issue_url]).to eq("https://example.test/issues/7")
        expect(client.created).to be_empty
        expect(Commenter::CommentSheet.from_yaml(File.read(sheet.path)).comments.first.github_issue_number).to eq(7)
        sheet.unlink
      end

      it "falls back to search when the recorded issue no longer exists" do
        client = FakeGitHubClient.new([seeded_issue(5, "[DIS] US-001: posted earlier")])
        sheet = write_sheet([yaml_data["comments"].first.merge("github" => { "issue_number" => 99 })])
        creator = described_class.new(config_file.path, title_template_file.path,
                                      body_template_file.path, client: client)

        results = creator.create_issues_from_yaml(sheet.path)

        expect(results.first[:status]).to eq(:skipped)
        expect(results.first[:issue_number]).to eq(5)
        expect(client.created).to be_empty
        expect(Commenter::CommentSheet.from_yaml(File.read(sheet.path)).comments.first.github_issue_number).to eq(5)
        sheet.unlink
      end

      it "falls back to search when the recorded issue title does not match the stage" do
        client = FakeGitHubClient.new([seeded_issue(7, "[WD] US-001: different stage"),
                                       seeded_issue(5, "[DIS] US-001: posted earlier")])
        sheet = write_sheet([yaml_data["comments"].first.merge("github" => { "issue_number" => 7 })])
        creator = described_class.new(config_file.path, title_template_file.path,
                                      body_template_file.path, client: client)

        results = creator.create_issues_from_yaml(sheet.path)

        expect(results.first[:status]).to eq(:skipped)
        expect(results.first[:issue_number]).to eq(5)
        expect(client.created).to be_empty
        sheet.unlink
      end

      it "records the issue in the YAML when skipping via title search" do
        client = FakeGitHubClient.new([seeded_issue(5, "[DIS] US-001: posted earlier")])
        sheet = write_sheet(yaml_data["comments"])
        creator = described_class.new(config_file.path, title_template_file.path,
                                      body_template_file.path, client: client)

        results = creator.create_issues_from_yaml(sheet.path)

        expect(results.first[:status]).to eq(:skipped)
        expect(Commenter::CommentSheet.from_yaml(File.read(sheet.path)).comments.first.github_issue_number).to eq(5)
        sheet.unlink
      end

      it "creates and records the issue when nothing exists" do
        client = FakeGitHubClient.new
        sheet = write_sheet(yaml_data["comments"])
        creator = described_class.new(config_file.path, title_template_file.path,
                                      body_template_file.path, client: client)

        results = creator.create_issues_from_yaml(sheet.path)

        expect(results.first[:status]).to eq(:created)
        expect(results.first[:issue_number]).to eq(1)
        expect(client.created.length).to eq(1)
        expect(Commenter::CommentSheet.from_yaml(File.read(sheet.path)).comments.first.github_issue_number).to eq(1)
        sheet.unlink
      end

      it "retries creation after a rate limit" do
        client = FakeGitHubClient.new
        client.rate_limit_failures = 1
        sheet = write_sheet(yaml_data["comments"])
        creator = described_class.new(config_file.path, title_template_file.path,
                                      body_template_file.path, client: client)

        results = creator.create_issues_from_yaml(sheet.path)

        expect(results.first[:status]).to eq(:created)
        expect(client.created.length).to eq(1)
        sheet.unlink
      end

      it "reports an error when rate limiting persists" do
        client = FakeGitHubClient.new
        client.rate_limit_failures = 99
        sheet = write_sheet(yaml_data["comments"])
        creator = described_class.new(config_file.path, title_template_file.path,
                                      body_template_file.path, client: client)

        results = creator.create_issues_from_yaml(sheet.path)

        expect(results.first[:status]).to eq(:error)
        expect(client.created).to be_empty
        sheet.unlink
      end

      it "reports an error instead of creating when the title search fails" do
        client = FakeGitHubClient.new
        client.search_error = Octokit::Forbidden.new(
          status: 403,
          body: "You have exceeded a secondary rate limit and have been " \
                "temporarily blocked from content creation."
        )
        sheet = write_sheet(yaml_data["comments"])
        creator = described_class.new(config_file.path, title_template_file.path,
                                      body_template_file.path, client: client)

        results = creator.create_issues_from_yaml(sheet.path)

        expect(results.first[:status]).to eq(:error)
        expect(client.created).to be_empty
        sheet.unlink
      end
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

RSpec.describe Commenter::GitHubIssueCreator do
  let(:config_file) do
    file = Tempfile.new(["config", ".yaml"])
    file.write({ "github" => { "repository" => "test-org/test-repo", "token" => "t",
                               "default_labels" => ["comment-review"] } }.to_yaml)
    file.close
    file
  end
  let(:client) { Octokit::Client.new(access_token: "dummy") }
  let(:creator) { described_class.new(config_file.path, client: client) }

  def sheet_with(type)
    Commenter::CommentSheet.new(stage: "DIS", comments: [
                                  Commenter::Comment.new(id: "US-001", body: "US", type: type, comments: "Text")
                                ])
  end

  after { config_file.unlink }

  describe "comment type labels (#3)" do
    it "labels recognized types and never mints labels from combined values" do
      recognized = creator.create_issues_from_yaml(write_yaml(sheet_with("technical")), dry_run: true)
      combined = creator.create_issues_from_yaml(write_yaml(sheet_with("ge/te")), dry_run: true)

      expect(recognized.first[:labels]).to include("technical")
      expect(combined.first[:labels]).to eq(["comment-review"])
    end

    def write_yaml(sheet)
      file = Tempfile.new(["comments", ".yaml"])
      file.write(sheet.to_yaml_document)
      file.close
      file
    end
  end

  describe "issue marker (#1)" do
    it "embeds the marker in created issue bodies" do
      empty = MarkerResults.new(items: [])
      allow(client).to receive(:search_issues).and_return(empty)
      created = MarkerIssue.new(number: 9, html_url: "https://github.com/test-org/test-repo/issues/9",
                                title: "T", body: "B", state: "open")
      allow(client).to receive(:create_issue) { |_repo, _title, _body, _opts| created }

      file = write_yaml_with_github(nil)
      creator.create_issues_from_yaml(file)

      expect(client).to have_received(:create_issue)
        .with(anything, anything, %r{urn:commenter:test-org/test-repo:dis:US-001}, anything)
      file.unlink
    end

    it "finds existing issues through the marker before the title search" do
      marker_hit = MarkerIssue.new(number: 9, html_url: "u", title: "t", body: "b", state: "open", created_at: nil)
      allow(client).to receive(:search_issues).with(/in:body/).and_return(MarkerResults.new(items: [marker_hit]))
      allow(client).to receive(:search_issues).with(/in:title/).and_raise("title search must not run")

      file = write_yaml_with_github(nil)
      results = creator.create_issues_from_yaml(file)

      expect(results.first[:status]).to eq(:skipped)
      expect(results.first[:issue_number]).to eq(9)
      file.unlink
    end

    it "verifies recorded issues by marker when the title does not carry the unique id" do
      recorded = MarkerIssue.new(number: 9, html_url: "u", title: "Custom title", created_at: nil,
                                 body: "discussed in `urn:commenter:test-org/test-repo:dis:US-001`", state: "open")
      allow(client).to receive(:issue).with("test-org/test-repo", 9).and_return(recorded)
      allow(client).to receive(:search_issues).and_raise("search must not run")

      file = write_yaml_with_github(9)
      results = creator.create_issues_from_yaml(file)

      expect(results.first[:status]).to eq(:skipped)
      file.unlink
    end

    def write_yaml_with_github(issue_number)
      github = issue_number ? { "issue_number" => issue_number, "status" => "open" } : nil
      file = Tempfile.new(["comments", ".yaml"])
      file.write({ "version" => "2012-03", "stage" => "DIS",
                   "comments" => [{ "id" => "US-001", "body" => "US", "comments" => "Text",
                                    "github" => github }.compact] }.to_yaml)
      file.close
      file
    end
  end
end

RSpec.describe Commenter::GitHubIssueRetriever do
  let(:config_file) do
    file = Tempfile.new(["config", ".yaml"])
    file.write({ "github" => { "repository" => "test-org/test-repo", "token" => "t" } }.to_yaml)
    file.close
    file
  end
  let(:client) { Octokit::Client.new(access_token: "dummy") }
  let(:retriever) { described_class.new(config_file.path, client: client) }

  after { config_file.unlink }

  def retrieve_with(issue_state, comments)
    Dir.mktmpdir do |dir|
      input = File.join(dir, "comments.yaml")
      File.write(input, { "version" => "2012-03",
                          "comments" => [{ "id" => "US-001", "comments" => "Text",
                                           "github" => { "issue_number" => 5, "status" => "open" } }] }.to_yaml)
      allow(client).to receive(:issue).with("test-org/test-repo", 5)
                                      .and_return(RetrieverIssue.new(number: 5, state: issue_state))
      allow(client).to receive(:issue_comments).and_return(comments)

      result = retriever.retrieve_observations_from_yaml(input)[0]
      sheet = Commenter::CommentSheet.from_yaml(File.read(input))
      [result, sheet.comments.first]
    end
  end

  it "fills an observation from an open issue (#4)" do
    result, comment = retrieve_with("open", [RetrieverComment.new(body: "> **OBSERVATION:**\n> Accepted.")])

    expect(result[:status]).to eq(:retrieved)
    expect(comment.observations).to eq("Accepted.")
  end

  it "skips an open issue only when no observation exists yet" do
    result, comment = retrieve_with("open", [RetrieverComment.new(body: "Still discussing")])

    expect(result[:status]).to eq(:skipped)
    expect(result[:message]).to include("still open")
    expect(comment.observations).to be_nil
  end

  it "fills observations from closed issues and records the status" do
    result, comment = retrieve_with("closed", [RetrieverComment.new(body: "> **OBSERVATION:**\n> Noted.")])

    expect(result[:status]).to eq(:retrieved)
    expect(comment.observations).to eq("Noted.")
    expect(comment.github_status).to eq("closed")
  end
end
