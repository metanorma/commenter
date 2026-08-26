# frozen_string_literal: true

require "spec_helper"
require_relative "../support/osd_fixtures"

RSpec.describe Commenter::Parser::OsdXlsxParser do
  include OsdFixtures

  describe "resolved variant" do
    it "extracts sheet metadata from the header rows" do
      with_resolved_xlsx do |path|
        sheet = described_class.new.parse(path)

        expect(sheet.version).to eq("osd")
        expect(sheet.date).to eq("2026-04-21")
        expect(sheet.document).to eq("ISO/DIS 5843-6(en)")
        expect(sheet.stage).to eq("DIS")
        expect(sheet.project).to eq("ISO/DIS 5843-6")
        expect(sheet.title_en).to eq("Aerodromes and heliports")
        expect(sheet.title_fr).to eq("Aerodromes and heliports (FR)")
      end
    end

    it "maps columns to comment attributes" do
      with_resolved_xlsx do |path|
        comment = described_class.new.parse(path).comments.first

        expect(comment.id).to eq("1")
        expect(comment.body).to eq("John Doe")
        expect(comment.locality).to eq({ clause: "5.2.1", element: "Requirements" })
        expect(comment.comments).to eq("The values in Table 3 are inconsistent.")
        expect(comment.proposed_change).to eq("Correct the values in column 2.")
        expect(comment.comment_type).to eq("Editorial")
        expect(comment.resolution_status).to eq("Accepted")
        expect(comment.resolution_date).to eq("2026-04-10")
        expect(comment.feedbacks).to eq("Feedback from the working group")
        expect(comment.motivation).to eq("Reviewed and approved by the working group.")
        expect(comment.created_date).to eq("2026-04-01")
        expect(comment.stage_code).to eq("40.20")
      end
    end

    it "builds observations from resolution status and motivation" do
      with_resolved_xlsx do |path|
        comments = described_class.new.parse(path).comments

        expect(comments.first.observations).to eq("Accepted. Reviewed and approved by the working group.")
        expect(comments.last.observations).to eq("Rejected")
      end
    end

    it "normalizes numeric comment ids to strings" do
      with_resolved_xlsx do |path|
        comments = described_class.new.parse(path).comments

        expect(comments.map(&:id)).to eq(%w[1 2])
      end
    end

    it "skips empty rows and keeps comments without clause data" do
      with_resolved_xlsx do |path|
        comments = described_class.new.parse(path).comments

        expect(comments.length).to eq(2)
        expect(comments.last.locality).to eq({})
        expect(comments.last.proposed_change).to be_nil
      end
    end

    it "falls back to proposal-on-text when proposed change is blank" do
      rows = resolved_rows
      rows[4][8] = nil # Proposed change
      with_resolved_xlsx(rows) do |path|
        sheet = described_class.new.parse(path)

        expect(sheet.comments.first.proposed_change).to eq("Proposal on the text")
      end
    end

    it "excludes observations when exclude_observations is set" do
      with_resolved_xlsx do |path|
        sheet = described_class.new.parse(path, exclude_observations: true)

        expect(sheet.comments.first.observations).to be_nil
      end
    end

    it "maps columns by real position when the header row has gaps" do
      with_resolved_xlsx(resolved_rows(gap: true)) do |path|
        comment = described_class.new.parse(path).comments.first

        expect(comment.id).to eq("1")
        expect(comment.type).to eq("editorial")
        expect(comment.comments).to eq("The values in Table 3 are inconsistent.")
        expect(comment.resolution_status).to eq("Accepted")
        expect(comment.stage_code).to eq("40.20")
      end
    end
  end
end

RSpec.describe Commenter::Parser::OsdXlsxParser do
  include OsdFixtures

  describe "unresolved variant" do
    it "parses the first sheet by default" do
      with_unresolved_workbook do |path|
        sheet = described_class.new.parse(path)

        expect(sheet.comments.map(&:id)).to eq(%w[7 8])
        expect(sheet.comments.first.body).to eq("John Doe")
        expect(sheet.comments.first.type).to eq("editorial")
        expect(sheet.comments.first.feedbacks).to eq("Reply from secretariat")
        expect(sheet.comments.first.motivation).to eq("Justification text")
        expect(sheet.comments.first.created_date).to eq("2026-04-05")
        expect(sheet.comments.last.observations).to be_nil
      end
    end

    it "uses the unresolved sheet when unresolved_only is set" do
      with_unresolved_workbook do |path|
        sheet = described_class.new.parse(path, unresolved_only: true)

        expect(sheet.comments.map(&:id)).to eq(["9"])
        expect(sheet.comments.first.type).to eq("general")
      end
    end

    it "uses the resolved sheet when resolved_only is set" do
      with_unresolved_workbook do |path|
        sheet = described_class.new.parse(path, resolved_only: true)

        expect(sheet.comments.map(&:id)).to eq(["10"])
        expect(sheet.comments.first.observations).to eq("Partially accepted. Compromise reached.")
      end
    end

    it "parses the sheet given by name" do
      with_unresolved_workbook do |path|
        sheet = described_class.new.parse(path, sheet: "Resolved comments (1)")

        expect(sheet.comments.map(&:id)).to eq(["10"])
      end
    end

    it "raises when the requested sheet does not exist" do
      with_unresolved_workbook do |path|
        expect { described_class.new.parse(path, sheet: "Nope") }
          .to raise_error(/Sheet 'Nope' not found/)
      end
    end
  end
end

RSpec.describe Commenter::Parser::OsdXlsxParser do
  include OsdFixtures

  describe "round-trip stability" do
    it "produces identical YAML when reloaded from its own output" do
      with_resolved_xlsx do |path|
        sheet = described_class.new.parse(path)
        reparsed = Commenter::CommentSheet.from_hash(sheet.to_yaml_h)

        expect(reparsed.to_yaml_h).to eq(sheet.to_yaml_h)
      end
    end

    it "omits nil titles from YAML output" do
      rows = resolved_rows
      rows[1] = ["2026-04-21", "ISO/CD 12345(en)"]
      with_resolved_xlsx(rows) do |path|
        sheet = described_class.new.parse(path)

        expect(sheet.stage).to eq("CD")
        expect(sheet.to_yaml_h).not_to have_key("title_en")
        expect(sheet.to_yaml_h).not_to have_key("title_fr")
      end
    end
  end
end
