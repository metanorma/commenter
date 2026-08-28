# frozen_string_literal: true

require "spec_helper"

RSpec.describe Commenter::BallotReport do
  def comment(body:, observations: nil, resolution_status: nil, github: {}, type: "technical")
    Commenter::Comment.new(
      id: "#{body}-1", body: body, type: type,
      comments: "A comment", observations: observations,
      resolution_status: resolution_status, github: github
    )
  end

  let(:sheet) do
    Commenter::CommentSheet.new(comments: [
                                  comment(body: "DE", observations: "Accepted."),
                                  comment(body: "DE", observations: "Accept with modifications"),
                                  comment(body: "US", observations: "Noted"),
                                  comment(body: "US", observations: "Rejected"),
                                  comment(body: "US"),
                                  comment(body: "CS", resolution_status: "Not accepted"),
                                  comment(body: "CS", github: { status: "open" })
                                ])
  end

  describe ".status_for" do
    it "prefers observation text, then resolution status, then GitHub state" do
      comments = sheet.comments
      expect(described_class.status_for(comments[0])).to eq(:accepted)
      expect(described_class.status_for(comments[4])).to eq(:undecided)
      expect(described_class.status_for(comments[5])).to eq(:rejected)
      expect(described_class.status_for(comments[6])).to eq(:open)
    end
  end

  describe ".counts" do
    it "counts per member body, disposition, and type" do
      counts = described_class.counts(sheet)

      expect(counts[:total]).to eq(7)
      expect(counts[:bodies]["DE"][:total]).to eq(2)
      expect(counts[:bodies]["DE"][:accepted]).to eq(1)
      expect(counts[:bodies]["DE"][:accept_with_modifications]).to eq(1)
      expect(counts[:bodies]["US"][:noted]).to eq(1)
      expect(counts[:bodies]["US"][:rejected]).to eq(1)
      expect(counts[:bodies]["US"][:undecided]).to eq(1)
      expect(counts[:bodies]["CS"][:open]).to eq(1)
      expect(counts[:types]["technical"]).to eq(7)
    end
  end

  describe ".to_markdown" do
    it "renders a ballot report table with totals" do
      markdown = described_class.to_markdown(sheet)

      expect(markdown).to start_with("| Body | Total | Accepted | AWM | Noted | Rejected | TODO | Open | Undecided |")
      expect(markdown).to include("| DE | 2 | 1 | 1 | 0 | 0 | 0 | 0 | 0 |")
      expect(markdown).to include("| **Total** | **7** | **1** | **1** | **1** | **2** | **0** | **1** | **1** |")
      expect(markdown).to include("Comment types: technical 7")
    end
  end
end
