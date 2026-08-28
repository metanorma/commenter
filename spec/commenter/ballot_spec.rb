# frozen_string_literal: true

require "spec_helper"

RSpec.describe Commenter::Ballot do
  def sheet(body:, ids:, document: nil, stage: nil)
    Commenter::CommentSheet.new(
      version: "2012-03",
      document: document,
      stage: stage,
      comments: ids.map do |id|
        Commenter::Comment.new(id: id, body: body, comments: "Comment #{id} from #{body}")
      end
    )
  end

  it "combines comments from all sheets in input order" do
    merged = described_class.new([
                                   sheet(body: "DE", ids: %w[DE-001 DE-002]),
                                   sheet(body: "US", ids: %w[US-001])
                                 ]).merge

    expect(merged.comments.map(&:id)).to eq(%w[DE-001 DE-002 US-001])
    expect(merged.comments.map(&:body)).to eq(%w[DE DE US])
  end

  it "takes metadata from the first sheet that provides it" do
    merged = described_class.new([
                                   sheet(body: "DE", ids: %w[DE-001], stage: nil),
                                   sheet(body: "US", ids: %w[US-001], document: "ISO 2533:2026", stage: "DIS")
                                 ]).merge

    expect(merged.version).to eq("2012-03")
    expect(merged.document).to eq("ISO 2533:2026")
    expect(merged.stage).to eq("DIS")
  end

  it "silently deduplicates identical comments sharing an ID" do
    duplicate = Commenter::Comment.new(id: "DE-001", body: "DE", comments: "Same text", proposed_change: "Same change")

    merged = described_class.new([
                                   Commenter::CommentSheet.new(comments: [duplicate]),
                                   Commenter::CommentSheet.new(comments: [
                                                                 Commenter::Comment.new(id: "DE-001", body: "DE", comments: "Same text",
                                                                                        proposed_change: "Same change")
                                                               ])
                                 ]).merge

    expect(merged.comments.map(&:id)).to eq(["DE-001"])
  end

  it "raises when the same ID carries differing content" do
    conflicting = Commenter::Comment.new(id: "DE-001", body: "DE", comments: "Different text entirely")

    expect do
      described_class.new([
                            sheet(body: "DE", ids: %w[DE-001]),
                            Commenter::CommentSheet.new(comments: [conflicting])
                          ]).merge
    end.to raise_error(Commenter::Error, /DE-001/)
  end

  it "returns an empty sheet when no input sheets are given" do
    merged = described_class.new([]).merge

    expect(merged.comments).to eq([])
  end
end
