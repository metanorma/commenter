# frozen_string_literal: true

require "spec_helper"
require "commenter/cli"
require_relative "../support/osd_fixtures"
require_relative "../support/xlsx_builder"

RSpec.describe Commenter::Cli do
  include OsdFixtures

  describe "#import" do
    it "writes OSD YAML and copies the OSD schema for XLSX input" do
      Dir.mktmpdir do |dir|
        xlsx = File.join(dir, "comments.xlsx")
        rows = header_block(OsdFixtures::RESOLVED_HEADERS) + [
          [1, "John Doe", "5.2.1", "Requirements", "Comment", "Editorial",
           "The values in Table 3 are inconsistent.", nil, "Correct the values.", nil, nil, nil,
           "2026-04-01", "Accepted", nil, "2026-04-10", "40.20"]
        ]
        XlsxBuilder.write(xlsx, [["Comments (1)", rows]])
        output = File.join(dir, "out", "comments.yaml")
        schema_dir = File.join(dir, "out", "schema")

        described_class.start(["import", xlsx, "--output", output, "--schema-dir", schema_dir])

        data = YAML.safe_load_file(output)
        expect(data["version"]).to eq("osd")
        expect(data["comments"].length).to eq(1)
        expect(data["comments"].first["id"]).to eq("1")
        expect(File.read(output)).to start_with("# yaml-language-server: $schema=")
        expect(File).to exist(File.join(schema_dir, "iso_comment_osd.yaml"))
      end
    end
  end

  describe "#merge" do
    it "writes a combined sheet with schema reference" do
      Dir.mktmpdir do |dir|
        one = File.join(dir, "de.yaml")
        two = File.join(dir, "us.yaml")
        File.write(one, { "version" => "2012-03", "comments" => [
          { "id" => "DE-001", "body" => "DE", "comments" => "First" }
        ] }.to_yaml)
        File.write(two, { "comments" => [
          { "id" => "US-001", "body" => "US", "comments" => "Second" }
        ] }.to_yaml)
        output = File.join(dir, "out", "merged.yaml")
        schema_dir = File.join(dir, "out", "schema")

        described_class.start(["merge", one, two, "--output", output, "--schema-dir", schema_dir])

        data = YAML.safe_load_file(output)
        expect(data["comments"].map { |comment| comment["id"] }).to eq(%w[DE-001 US-001])
        expect(File).to exist(File.join(schema_dir, "iso_comment_2012-03.yaml"))
      end
    end
  end

  describe "#stats" do
    it "prints a markdown disposition report" do
      Dir.mktmpdir do |dir|
        input = File.join(dir, "comments.yaml")
        File.write(input, { "comments" => [
          { "id" => "DE-001", "body" => "DE", "comments" => "A", "observations" => "Accepted." },
          { "id" => "US-001", "body" => "US", "comments" => "B", "observations" => "Noted" }
        ] }.to_yaml)

        expect { described_class.start(["stats", input]) }
          .to output(a_string_including(
                       "| DE | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |",
                       "| US | 1 | 0 | 0 | 1 | 0 | 0 | 0 | 0 |"
                     )).to_stdout
      end
    end
  end
end
