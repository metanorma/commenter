# frozen_string_literal: true

require "spec_helper"

RSpec.describe Commenter::BallotDiff do
  def sheet(comments)
    Commenter::CommentSheet.new(comments: comments)
  end

  def comment(id, text: "Text for #{id}", observations: nil)
    Commenter::Comment.new(id: id, body: id.split("-").first, comments: text, observations: observations)
  end

  let(:cd) do
    sheet([
            comment("DE-001"),
            comment("DE-002", text: "Old wording"),
            comment("US-001")
          ])
  end

  let(:dis) do
    sheet([
            comment("DE-001"),
            comment("DE-002", text: "Revised wording"),
            comment("US-001", observations: "Accepted."),
            comment("JP-001")
          ])
  end

  it "classifies new, withdrawn, repeated, and revised comments" do
    result = described_class.diff(cd, dis)

    expect(result[:new]).to eq(["JP-001"])
    expect(result[:withdrawn]).to eq([]) # US-001 present in both
    expect(result[:repeated]).to eq(%w[DE-001 US-001])
    expect(result[:revised]).to eq(["DE-002"])
  end

  it "counts comments with a disposition in the later stage as resolved" do
    result = described_class.diff(cd, dis)

    expect(result[:resolved]).to eq(["US-001"])
  end

  it "reports withdrawn comments" do
    result = described_class.diff(dis, cd)

    expect(result[:withdrawn]).to eq(["JP-001"])
    expect(result[:new]).to eq([])
  end

  it "renders a markdown table" do
    markdown = described_class.to_markdown(cd, dis)

    expect(markdown).to start_with("| Category | Count | Comments |")
    expect(markdown).to include("| New | 1 | JP-001 |")
    expect(markdown).to include("| Revised | 1 | DE-002 |")
    expect(markdown).to include("Resolved (disposition recorded in the later stage): 1")
  end
end
