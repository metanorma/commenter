# frozen_string_literal: true

require "spec_helper"

RSpec.describe Commenter::SheetValidator do
  def sheet(comments, version: "2012-03", stage: nil)
    Commenter::CommentSheet.new(version: version, stage: stage, comments: comments)
  end

  def comment(id, text: "Text", type: "technical")
    Commenter::Comment.new(id: id, body: id.to_s.split("-").first, comments: text, type: type)
  end

  it "accepts a clean sheet" do
    expect(described_class.call(sheet([comment("DE-001")]))).to eq([])
  end

  it "reports unknown versions and unusual stages" do
    problems = described_class.call(sheet([comment("DE-001")], version: "2018-01", stage: "CUSTOM"))

    expect(problems).to include(severity: :error, message: a_string_including("unknown version"))
    expect(problems).to include(severity: :warning, message: a_string_including("unusual stage"))
  end

  it "reports missing ids, missing text, and duplicate ids as errors" do
    problems = described_class.call(sheet([
                                            comment("", text: "No id"),
                                            comment("DE-001"),
                                            comment("DE-001"),
                                            comment("DE-002", text: "")
                                          ]))

    errors = problems.select { |problem| problem[:severity] == :error }
    expect(errors.map { |problem| problem[:message] }).to include("missing id", "missing comment text",
                                                                  "duplicate comment id DE-001")
  end

  it "warns about unrecognized comment types without failing" do
    problems = described_class.call(sheet([comment("DE-001", type: "ge/te")]))

    expect(problems).to contain_exactly(severity: :warning, comment: "DE-001",
                                        message: a_string_including("unrecognized comment type"))
  end
end
