# frozen_string_literal: true

require "spec_helper"
require_relative "../support/redline_docx_builder"

RSpec.describe Commenter::Parser::TrackChangeDocxParser do
  def author = "CHEN Yvonne"

  def change(kind, id, text, date: "2025-12-05T20:10:00Z")
    { change: kind, id: id, author: author, date: date, text: text }
  end

  def with_redline(paragraphs, options = {})
    file = Tempfile.new(%w[redline .docx])
    RedlineDocxBuilder.write(file.path, paragraphs)
    yield described_class.new.parse(file.path, options)
  ensure
    file.close
    file.unlink
  end

  let(:base_paragraphs) do
    [
      { change: :ins, id: "1", author: author, date: "2025-12-05T20:10:00Z", text: "ISO boilerplate" },
      { heading: true, level: 1, text: "4 Basic principles" },
      { change: :del, id: "2", author: author, date: "2025-12-05T20:11:00Z", text: "old text" },
      { heading: true, level: 2, text: "4.2.1Thermodynamic temperature tangent" },
      { marker: true, id: "9", author: author },
      { parts: [{ text: "Body " }, change(:ins, "3", "inserted")] },
      { heading: true, level: 1, text: "Annex A" },
      { change: :moveTo, id: "4", author: author, date: "2025-12-06T10:00:00Z", text: "moved" }
    ]
  end

  it "extracts track changes in document order with rendered proposed_change" do
    with_redline(base_paragraphs) do |sheet|
      comments = sheet.comments

      expect(comments.map(&:proposed_change)).to eq([
                                                      'Insert: "ISO boilerplate"',
                                                      'Delete: "old text"',
                                                      'Insert: "inserted"',
                                                      'Move to: "moved"'
                                                    ])
      expect(comments.map(&:comments)).to eq([
                                               "Track change (insertion)",
                                               "Track change (deletion)",
                                               "Track change (insertion)",
                                               "Track change (move (to))"
                                             ])
    end
  end

  it "assigns the clause of the nearest preceding heading, including sub-clauses" do
    with_redline(base_paragraphs) do |sheet|
      expect(sheet.comments.map(&:clause)).to eq(["_whole document", "4", "4.2.1", "Annex A"])
    end
  end

  it "skips self-closing paragraph-mark markers without corrupting later capture" do
    with_redline(base_paragraphs) do |sheet|
      expect(sheet.comments.length).to eq(4)
    end
  end

  it "captures nested track changes" do
    paragraphs = [
      { change: :ins, id: "1", author: author, date: "2025-12-05T20:10:00Z", text: "",
        nested: [change(:ins, "2", "inner text")] }
    ]

    with_redline(paragraphs) do |sheet|
      # The inner change ends first, so it is emitted before its wrapper.
      expect(sheet.comments.map(&:proposed_change)).to eq(['Insert: "inner text"', 'Insert: ""'])
    end
  end

  it "builds CS-prefixed sequential IDs by default" do
    with_redline(base_paragraphs) do |sheet|
      expect(sheet.comments.map(&:id)).to eq(%w[CS-001 CS-002 CS-003 CS-004])
      expect(sheet.comments.map(&:body).uniq).to eq(["CS"])
    end
  end

  it "uses a custom body code and technical type" do
    with_redline(base_paragraphs, body: "GB", type: "ge") do |sheet|
      expect(sheet.comments.first.id).to eq("GB-001")
      expect(sheet.comments.first.type).to eq("general")
    end
  end

  it "stamps observations on every entry when given" do
    with_redline(base_paragraphs, observations: "Accepted. ISO/CS tracked change accepted.") do |sheet|
      expect(sheet.comments.map(&:observations).uniq)
        .to eq(["Accepted. ISO/CS tracked change accepted."])
    end
  end

  it "leaves observations blank by default and honours exclude_observations" do
    with_redline(base_paragraphs) do |sheet|
      expect(sheet.comments.first.observations).to be_nil
    end

    with_redline(base_paragraphs, observations: "Accepted.", exclude_observations: true) do |sheet|
      expect(sheet.comments.first.observations).to be_nil
    end
  end

  it "builds 2012-03 sheet metadata from the changes and options" do
    with_redline(base_paragraphs, document: "ISO 2533:2026", stage: "DIS") do |sheet|
      expect(sheet.version).to eq("2012-03")
      expect(sheet.schema_name).to eq("iso_comment_2012-03.yaml")
      expect(sheet.document).to eq("ISO 2533:2026")
      expect(sheet.stage).to eq("DIS")
      expect(sheet.date).to eq("2025-12-06")
    end
  end

  it "is reachable through Parser dispatch with format redline" do
    file = Tempfile.new(%w[redline .docx])
    RedlineDocxBuilder.write(file.path, base_paragraphs)

    sheet = Commenter::Parser.new.parse(file.path, format: "redline")
    expect(sheet.comments.length).to eq(4)
  ensure
    file.close
    file.unlink
  end
end
