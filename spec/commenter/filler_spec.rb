# frozen_string_literal: true

require "spec_helper"
require "nokogiri"
require "zip"

RSpec.describe Commenter::Filler do
  let(:template_path) { File.expand_path("../../data/iso_comment_template_2012-03.docx", __dir__) }

  def comment(attrs)
    Commenter::Comment.new({ body: "US", type: "technical", comments: "Text" }.merge(attrs))
  end

  def header_xml(output_path)
    Zip::File.open(output_path) do |zip|
      zip.entries.find { |entry| entry.name == "word/header2.xml" }.get_input_stream(&:read)
    end
  end

  def body_xml(output_path)
    Zip::File.open(output_path) do |zip|
      zip.entries.find { |entry| entry.name == "word/document.xml" }.get_input_stream(&:read)
    end
  end

  # Rows of the comment table as arrays of cell text. Read via Nokogiri over
  # the extracted XML rather than Docx::Document, whose open zip handle keeps
  # the file locked on Windows and breaks Dir.mktmpdir teardown.
  def body_rows(output_path)
    document = Nokogiri::XML(body_xml(output_path))
    document.xpath("//w:tbl").flat_map { |table| table.xpath("./w:tr") }.map do |row|
      row.xpath("./w:tc").map { |cell| cell.xpath(".//w:t").map(&:text).join }
    end
  end

  it "writes comment rows into the template table" do
    Dir.mktmpdir do |dir|
      output = File.join(dir, "filled.docx")
      described_class.new.fill(template_path, output, [
                                 comment(id: "US-001", locality: { clause: "5.2.1", element: "Table 3", line_number: "45" },
                                         proposed_change: "Fix them", observations: "Accepted")
                               ])

      row = body_rows(output).first
      expect(row[0]).to include("US-001")
      expect(row[1]).to include("45")
      expect(row[2]).to include("5.2.1")
      expect(row[3]).to include("Table 3")
      expect(row[4]).to include("technical")
      expect(row[5]).to include("Text")
      expect(row[6]).to include("Fix them")
      expect(row[7]).to include("Accepted")
    end
  end

  it "keeps multiple comments in input order and accepts plain hashes" do
    Dir.mktmpdir do |dir|
      output = File.join(dir, "filled.docx")
      described_class.new.fill(template_path, output, [
                                 { "id" => "DE-001", "comments" => "First" },
                                 comment(id: "US-001", comments: "Second")
                               ])

      rows = body_rows(output)
      expect(rows.length).to eq(2)
      expect(rows[0][0]).to include("DE-001")
      expect(rows[1][0]).to include("US-001")
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
