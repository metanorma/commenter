# frozen_string_literal: true

require "spec_helper"

RSpec.describe Commenter::CommentSheet do
  describe "#initialize" do
    it "creates a comment sheet with all attributes" do
      attributes = {
        version: "2012-03",
        date: "2024-06-04",
        document: "ISO 80000-2:2019",
        project: "Mathematics review",
        stage: "DIS",
        comments: [
          {
            id: "US-001",
            body: "US",
            locality: { clause: "5.1" },
            type: "te",
            comments: "Test comment",
            proposed_change: "Test change"
          }
        ]
      }

      sheet = described_class.new(attributes)

      expect(sheet.version).to eq("2012-03")
      expect(sheet.date).to eq("2024-06-04")
      expect(sheet.document).to eq("ISO 80000-2:2019")
      expect(sheet.project).to eq("Mathematics review")
      expect(sheet.stage).to eq("DIS")
      expect(sheet.comments).to be_an(Array)
      expect(sheet.comments.length).to eq(1)
      expect(sheet.comments.first).to be_a(Commenter::Comment)
    end

    it "handles string keys in attributes" do
      attributes = {
        "version" => "2012-03",
        "stage" => "CD",
        "comments" => []
      }

      sheet = described_class.new(attributes)

      expect(sheet.version).to eq("2012-03")
      expect(sheet.stage).to eq("CD")
    end

    it "sets default version when not provided" do
      sheet = described_class.new({})

      expect(sheet.version).to eq("2012-03")
    end

    it "converts comment hashes to Comment objects" do
      attributes = {
        comments: [
          {
            id: "US-001",
            locality: { clause: "5.1" }
          }
        ]
      }

      sheet = described_class.new(attributes)

      expect(sheet.comments.first).to be_a(Commenter::Comment)
      expect(sheet.comments.first.id).to eq("US-001")
    end

    it "preserves existing Comment objects" do
      comment = Commenter::Comment.new(id: "US-001")
      attributes = { comments: [comment] }

      sheet = described_class.new(attributes)

      expect(sheet.comments.first).to be(comment)
    end
  end

  describe "#add_comment" do
    let(:sheet) { described_class.new({}) }

    it "adds a Comment object" do
      comment = Commenter::Comment.new(id: "US-001")
      sheet.add_comment(comment)

      expect(sheet.comments).to include(comment)
    end

    it "converts hash to Comment object" do
      comment_hash = { id: "US-001", locality: { clause: "5.1" } }
      sheet.add_comment(comment_hash)

      expect(sheet.comments.length).to eq(1)
      expect(sheet.comments.first).to be_a(Commenter::Comment)
      expect(sheet.comments.first.id).to eq("US-001")
    end
  end

  describe "#to_h" do
    it "converts comment sheet to hash including stage" do
      sheet = described_class.new(
        version: "2012-03",
        date: "2024-06-04",
        document: "Test Document",
        project: "Test Project",
        stage: "DIS",
        comments: [
          Commenter::Comment.new(id: "US-001", locality: { clause: "5.1" })
        ]
      )

      hash = sheet.to_h

      expect(hash[:version]).to eq("2012-03")
      expect(hash[:date]).to eq("2024-06-04")
      expect(hash[:document]).to eq("Test Document")
      expect(hash[:project]).to eq("Test Project")
      expect(hash[:stage]).to eq("DIS")
      expect(hash[:comments]).to be_an(Array)
      expect(hash[:comments].first).to be_a(Hash)
    end

    it "includes nil stage when not set" do
      sheet = described_class.new({})
      hash = sheet.to_h

      expect(hash).to have_key(:stage)
      expect(hash[:stage]).to be_nil
    end
  end

  describe "#to_yaml_h" do
    it "converts to YAML-friendly hash with string keys" do
      sheet = described_class.new(
        stage: "DIS",
        comments: [
          Commenter::Comment.new(id: "US-001")
        ]
      )

      yaml_hash = sheet.to_yaml_h

      expect(yaml_hash["stage"]).to eq("DIS")
      expect(yaml_hash["comments"]).to be_an(Array)
      expect(yaml_hash["comments"].first).to be_a(Hash)
      expect(yaml_hash["comments"].first["id"]).to eq("US-001")
    end
  end

  describe ".from_hash" do
    it "creates comment sheet from hash" do
      hash = {
        version: "2012-03",
        stage: "CD",
        comments: [
          { id: "US-001", locality: { clause: "5.1" } }
        ]
      }

      sheet = described_class.from_hash(hash)

      expect(sheet).to be_a(described_class)
      expect(sheet.version).to eq("2012-03")
      expect(sheet.stage).to eq("CD")
      expect(sheet.comments.length).to eq(1)
    end
  end

  describe "stage validation" do
    it "accepts valid stage values" do
      valid_stages = %w[WD CD DIS FDIS PRF PUB]

      valid_stages.each do |stage|
        sheet = described_class.new(stage: stage)
        expect(sheet.stage).to eq(stage)
      end
    end

    it "accepts nil stage" do
      sheet = described_class.new(stage: nil)
      expect(sheet.stage).to be_nil
    end

    it "accepts custom stage values" do
      sheet = described_class.new(stage: "CUSTOM")
      expect(sheet.stage).to eq("CUSTOM")
    end
  end
end
