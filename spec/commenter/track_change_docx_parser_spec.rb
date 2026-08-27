# frozen_string_literal: true

require "spec_helper"
require_relative "../support/redline_docx_builder"

RSpec.describe Commenter::Parser::TrackChangeDocxParser do
  def author = "CHEN Yvonne"

  def change(kind, id, text, date: "2025-12-05T20:10:00Z")
    { change: kind, id: id, author: author, date: date, text: text }
  end

  def with_redline(paragraphs, comments: [], **options)
    file = Tempfile.new(%w[redline .docx])
    RedlineDocxBuilder.write(file.path, paragraphs, comments: comments)
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

  describe "element locality" do
    def table_paragraphs
      [
        { heading: true, level: 1, text: "4 Basic principles" },
        { text: "Table 3 — Atmospheric properties at altitude" },
        { parts: [{ text: "Body " }, change(:ins, "5", "edited")] },
        { text: "Formula (9):" },
        { change: :del, id: "6", author: author, date: "2025-12-05T20:10:00Z", text: "old formula text" },
        { text: "NOTE 2 — This note provides clarification." },
        { parts: [{ text: "note body " }, change(:ins, "7", "edited")] }
      ]
    end

    it "resolves the element from caption paragraphs and carries it to following changes" do
      with_redline(table_paragraphs) do |sheet|
        expect(sheet.comments.map(&:element)).to eq(["Table 3", "Formula (9)", "NOTE 2"])
      end
    end

    it "resolves inline element mentions" do
      paragraphs = [
        { heading: true, level: 1, text: "5 Data tables" },
        { parts: [{ text: "The values in Table 5 shall be " }, change(:ins, "8", "interpreted thus")] }
      ]

      with_redline(paragraphs) do |sheet|
        expect(sheet.comments.first.element).to eq("Table 5")
      end
    end

    it "resolves annex figure captions" do
      paragraphs = [
        { heading: true, level: 1, text: "Annex A" },
        { text: "Figure A.2 — Temperature profile" },
        { change: :ins, id: "9", author: author, date: "2025-12-05T20:10:00Z", text: "new caption text" }
      ]

      with_redline(paragraphs) do |sheet|
        expect(sheet.comments.first.element).to eq("Figure A.2")
      end
    end

    it "resets the element when the clause changes" do
      paragraphs = table_paragraphs + [
        { heading: true, level: 1, text: "5 Data tables" },
        { parts: [{ text: "Plain body " }, change(:ins, "10", "edited")] }
      ]

      with_redline(paragraphs) do |sheet|
        expect(sheet.comments.last.element).to be_nil
      end
    end
  end

  describe "unnumbered sub-headings" do
    it "inherit the parent heading clause" do
      paragraphs = [
        { heading: true, level: 1, text: "4 Basic principles" },
        { heading: true, level: 2, text: "4.2 Temperature" },
        { heading: true, level: 3, text: "Justification" },
        { parts: [{ text: "Body " }, change(:ins, "11", "edited")] }
      ]

      with_redline(paragraphs) do |sheet|
        expect(sheet.comments.first.clause).to eq("4.2")
      end
    end
  end

  describe "reviewer comment threads" do
    let(:remark_paragraphs) do
      [
        { change: :ins, id: "1", author: author, date: "2025-12-05T20:10:00Z", text: "tracked" },
        { heading: true, level: 1, text: "1 Scope" },
        { anchor: "74", text: "Values in feet." },
        { heading: true, level: 1, text: "2 Normative references" },
        { anchor: "88", text: "Introduction paragraph." }
      ]
    end

    let(:remarks) do
      [
        { id: "74", author: author, date: "2025-12-05T20:10:00Z",
          text: "Please provide values in km. Equivalent values in ft can be provided in brackets." },
        { id: "88", author: author, date: "2025-12-05T20:12:00Z",
          text: "Remove this paragraph from the Introduction." }
      ]
    end

    it "emits remarks after track changes with -CNNN ids and verbatim text" do
      with_redline(remark_paragraphs, comments: remarks) do |sheet|
        expect(sheet.comments.length).to eq(3)

        remark = sheet.comments.last
        expect(sheet.comments[1].id).to eq("CS-C001")
        expect(remark.id).to eq("CS-C002")
        expect(remark.comments).to eq("Remove this paragraph from the Introduction.")
      end
    end

    it "rewords the remark into proposed_change" do
      with_redline(remark_paragraphs, comments: remarks) do |sheet|
        expect(sheet.comments[1].proposed_change)
          .to eq("Provide values in km. Equivalent values in ft can be provided in brackets.")
      end
    end

    it "leaves remark observations empty for the owner to draft" do
      with_redline(remark_paragraphs, comments: remarks) do |sheet|
        expect(sheet.comments[1].observations).to be_nil
      end
    end

    it "anchors remarks to the clause of their commentRangeStart" do
      with_redline(remark_paragraphs, comments: remarks) do |sheet|
        expect(sheet.comments[1].clause).to eq("1")
        expect(sheet.comments.last.clause).to eq("2")
      end
    end

    it "defaults unanchored remarks to _whole document" do
      unanchored = [{ id: "99", author: author, date: "2025-12-05T20:10:00Z", text: "General remark." }]

      with_redline([{ text: "Body" }], comments: unanchored) do |sheet|
        expect(sheet.comments.first.clause).to eq("_whole document")
      end
    end

    it "stamps accept_all on track changes but not on remarks" do
      with_redline(remark_paragraphs, accept_all: true, comments: remarks) do |sheet|
        expect(sheet.comments.first.observations).to eq("Accepted. Tracked change accepted.")
        expect(sheet.comments[1].observations).to be_nil
      end
    end

    it "prefers an explicit observations stamp over accept_all" do
      with_redline(remark_paragraphs, accept_all: true, observations: "Custom.", comments: remarks) do |sheet|
        expect(sheet.comments.first.observations).to eq("Custom.")
      end
    end

    it "handles documents without comments.xml content" do
      with_redline([{ text: "No changes, no remarks." }]) do |sheet|
        expect(sheet.comments).to be_empty
      end
    end
  end
end
