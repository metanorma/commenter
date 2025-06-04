# frozen_string_literal: true

require "spec_helper"

RSpec.describe Commenter::Comment do
  describe "#initialize" do
    it "creates a comment with all attributes" do
      attributes = {
        id: "US-001",
        body: "US",
        locality: { clause: "5.1", element: "Table 1", line_number: "42" },
        type: "te",
        comments: "Test comment",
        proposed_change: "Test change",
        observations: "Test observations"
      }

      comment = described_class.new(attributes)

      expect(comment.id).to eq("US-001")
      expect(comment.body).to eq("US")
      expect(comment.clause).to eq("5.1")
      expect(comment.element).to eq("Table 1")
      expect(comment.line_number).to eq("42")
      expect(comment.type).to eq("te")
      expect(comment.comments).to eq("Test comment")
      expect(comment.proposed_change).to eq("Test change")
      expect(comment.observations).to eq("Test observations")
    end

    it "handles string keys in attributes" do
      attributes = {
        "id" => "US-001",
        "locality" => { "clause" => "5.1" }
      }

      comment = described_class.new(attributes)

      expect(comment.id).to eq("US-001")
      expect(comment.clause).to eq("5.1")
    end
  end

  describe "#brief_summary" do
    context "with locality information" do
      it "includes clause and element" do
        comment = described_class.new(
          locality: { clause: "5.1", element: "Table 1" },
          comments: "This is a test comment"
        )

        summary = comment.brief_summary

        expect(summary).to include("Clause 5.1")
        expect(summary).to include("Table 1")
        expect(summary).to include("This is a test comment")
      end

      it "includes line number when present" do
        comment = described_class.new(
          locality: { clause: "5.1", line_number: "42" },
          comments: "Test comment"
        )

        summary = comment.brief_summary

        expect(summary).to include("Clause 5.1")
        expect(summary).to include("Line 42")
      end

      it "handles empty locality gracefully" do
        comment = described_class.new(
          locality: { clause: "" },
          comments: "Test comment"
        )

        summary = comment.brief_summary

        expect(summary).to eq("Test comment")
      end
    end

    context "with comment text" do
      it "uses first sentence when short enough" do
        comment = described_class.new(
          locality: { clause: "5.1" },
          comments: "Short comment. This is ignored."
        )

        summary = comment.brief_summary

        expect(summary).to include("Short comment")
        expect(summary).not_to include("This is ignored")
      end

      it "truncates long text" do
        long_text = "This is a very long comment that exceeds the typical length limit and should be truncated appropriately"
        comment = described_class.new(
          locality: { clause: "5.1" },
          comments: long_text
        )

        summary = comment.brief_summary(80)

        expect(summary.length).to be <= 80
        expect(summary).to include("Clause 5.1")
      end

      it "handles empty comments" do
        comment = described_class.new(
          locality: { clause: "5.1" },
          comments: ""
        )

        summary = comment.brief_summary

        expect(summary).to eq("Clause 5.1")
      end

      it "handles nil comments" do
        comment = described_class.new(
          locality: { clause: "5.1" },
          comments: nil
        )

        summary = comment.brief_summary

        expect(summary).to eq("Clause 5.1")
      end
    end

    context "without locality or comments" do
      it "returns default message" do
        comment = described_class.new(
          locality: { clause: "" },
          comments: ""
        )

        summary = comment.brief_summary

        expect(summary).to eq("No description")
      end
    end

    context "respects max_length parameter" do
      it "truncates to specified length" do
        comment = described_class.new(
          locality: { clause: "5.1" },
          comments: "This is a test comment"
        )

        summary = comment.brief_summary(20)

        expect(summary.length).to be <= 20
      end
    end
  end

  describe "#to_h" do
    it "converts comment to hash" do
      comment = described_class.new(
        id: "US-001",
        body: "US",
        locality: { clause: "5.1" },
        type: "te",
        comments: "Test",
        proposed_change: "Change",
        observations: "Obs"
      )

      hash = comment.to_h

      expect(hash[:id]).to eq("US-001")
      expect(hash[:body]).to eq("US")
      expect(hash[:locality][:clause]).to eq("5.1")
      expect(hash[:type]).to eq("te")
      expect(hash[:comments]).to eq("Test")
      expect(hash[:proposed_change]).to eq("Change")
      expect(hash[:observations]).to eq("Obs")
    end
  end

  describe "#to_yaml_h" do
    it "converts to YAML-friendly hash with string keys" do
      comment = described_class.new(
        id: "US-001",
        locality: { clause: "5.1" },
        observations: nil
      )

      yaml_hash = comment.to_yaml_h

      expect(yaml_hash["id"]).to eq("US-001")
      expect(yaml_hash["locality"]["clause"]).to eq("5.1")
      expect(yaml_hash).not_to have_key("observations") # nil observations removed
    end

    it "removes empty observations" do
      comment = described_class.new(observations: "")
      yaml_hash = comment.to_yaml_h

      expect(yaml_hash).not_to have_key("observations")
    end
  end

  describe ".from_hash" do
    it "creates comment from hash" do
      hash = {
        id: "US-001",
        locality: { clause: "5.1" }
      }

      comment = described_class.from_hash(hash)

      expect(comment).to be_a(described_class)
      expect(comment.id).to eq("US-001")
      expect(comment.clause).to eq("5.1")
    end
  end
end
