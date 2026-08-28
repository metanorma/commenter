# frozen_string_literal: true

require "spec_helper"
require "docx"
require "zip"

RSpec.describe Commenter::Filler do
  let(:template_path) { File.expand_path("../../data/iso_comment_template_2012-03.docx", __dir__) }

  def comment(attrs)
    Commenter::Comment.new({ body: "US", type: "technical", comments: "Text" }.merge(attrs))
  end

  def header_xml(output_path)
    Zip::File.open(output_path) do |zip|
      zip.entries.find { |entry| entry.name == "word/header2.xml" }.get_input_stream.read
    end
  end

  def body_xml(output_path)
    Zip::File.open(output_path) do |zip|
      zip.entries.find { |entry| entry.name == "word/document.xml" }.get_input_stream.read
    end
  end

  it "writes comment rows into the template table" do
    Dir.mktmpdir do |dir|
      output = File.join(dir, "filled.docx")
      described_class.new.fill(template_path, output, [
                                 comment(id: "US-001", locality: { clause: "5.2.1", element: "Table 3", line_number: "45" },
                                         proposed_change: "Fix them", observations: "Accepted")
                               ])

      doc = Docx::Document.open(output)
      row = doc.tables.first.rows.first
      expect(row.cells[0].text).to include("US-001")
      expect(row.cells[1].text).to include("45")
      expect(row.cells[2].text).to include("5.2.1")
      expect(row.cells[3].text).to include("Table 3")
      expect(row.cells[4].text).to include("technical")
      expect(row.cells[5].text).to include("Text")
      expect(row.cells[6].text).to include("Fix them")
      expect(row.cells[7].text).to include("Accepted")
    end
  end

  it "keeps multiple comments in input order and accepts plain hashes" do
    Dir.mktmpdir do |dir|
      output = File.join(dir, "filled.docx")
      described_class.new.fill(template_path, output, [
                                 { "id" => "DE-001", "comments" => "First" },
                                 comment(id: "US-001", comments: "Second")
                               ])

      doc = Docx::Document.open(output)
      expect(doc.tables.first.rows.length).to eq(2)
      expect(doc.tables.first.rows[0].cells[0].text).to include("DE-001")
      expect(doc.tables.first.rows[1].cells[0].text).to include("US-001")
    end
  end

  it "fills the header metadata labels in the page header" do
    Dir.mktmpdir do |dir|
      output = File.join(dir, "filled.docx")
      described_class.new.fill(template_path, output, [comment(id: "US-001")],
                               date: "2026-08-28", document: "ISO 2533:2026", project: "Ballot review")

      header = header_xml(output)
      expect(header).to include("Date: 2026-08-28")
      expect(header).to include("Document: ISO 2533:2026")
      expect(header).to include("Project: Ballot review")
    end
  end

  it "leaves header labels untouched when no metadata is given" do
    Dir.mktmpdir do |dir|
      output = File.join(dir, "filled.docx")
      described_class.new.fill(template_path, output, [comment(id: "US-001")])

      header = header_xml(output)
      expect(header).to include(">Date: <")
      expect(header).to include(">Document:<")
      expect(header).to include(">Project:<")
    end
  end

  it "escapes XML special characters in metadata values" do
    Dir.mktmpdir do |dir|
      output = File.join(dir, "filled.docx")
      described_class.new.fill(template_path, output, [comment(id: "US-001")],
                               document: "A&B <standard>")

      expect(header_xml(output)).to include("Document: A&amp;B &lt;standard&gt;")
    end
  end

  it "shades observation cells according to disposition status" do
    Dir.mktmpdir do |dir|
      output = File.join(dir, "filled.docx")
      described_class.new.fill(template_path, output, [
                                 comment(id: "US-001", observations: "Accepted"),
                                 comment(id: "US-002", observations: "Not accepted")
                               ], shading: true)

      xml = body_xml(output)
      expect(xml).to include('w:fill="92D050"')
      expect(xml).to include('w:fill="FF99CC"')
    end
  end
end
