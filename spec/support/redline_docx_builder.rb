# frozen_string_literal: true

require "zip"

# Builds minimal redline DOCX files for specs, without binary fixtures. The
# document body is assembled from a paragraph DSL:
#
#   { heading: "1", level: 1, text: "Scope" }
#   { text: "Body text " }
#   { change: :ins, id: "1", author: "CHEN Yvonne", date: "2025-12-05T20:10:00Z",
#     text: "inserted" }
#   { marker: true }  # self-closing paragraph-mark insertion inside rPr
#
# Multiple entries in one paragraph can be given via :parts.
module RedlineDocxBuilder
  W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  private_constant :W_NS

  HEADING_LEVEL_STYLE = { 1 => "Heading1", 2 => "Heading2", 3 => "Heading3" }.freeze
  CHANGE_TAG = { ins: "w:ins", del: "w:del", moveFrom: "w:moveFrom", moveTo: "w:moveTo" }.freeze
  private_constant :HEADING_LEVEL_STYLE, :CHANGE_TAG

  def self.write(path, paragraphs)
    xml = document_xml(paragraphs)
    zip = Zip::File.new(path, create: true)
    zip.get_output_stream("word/document.xml") { |stream| stream.write(xml) }
    zip.close
    path
  end

  def self.document_xml(paragraphs)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <w:document xmlns:w="#{W_NS}"><w:body>#{paragraphs.map { |p| paragraph_xml(p) }.join}</w:body></w:document>
    XML
  end

  def self.paragraph_xml(paragraph)
    if paragraph[:marker]
      return %(<w:p><w:pPr><w:rPr><w:ins w:id="#{paragraph[:id]}" w:author="#{paragraph[:author]}"/></w:rPr></w:pPr></w:p>)
    end

    inner = if paragraph[:parts]
              paragraph[:parts].map { |part| part_xml(part) }.join
            elsif paragraph[:heading]
              %(<w:r><w:t>#{paragraph[:text]}</w:t></w:r>)
            elsif paragraph[:change]
              change_xml(paragraph)
            else
              %(<w:r><w:t>#{paragraph[:text]}</w:t></w:r>)
            end

    ppr = paragraph[:heading] ? %(<w:pPr><w:pStyle w:val="#{HEADING_LEVEL_STYLE.fetch(paragraph[:level], 1)}"/></w:pPr>) : ""
    "<w:p>#{ppr}#{inner}</w:p>"
  end

  def self.part_xml(part)
    part[:change] ? change_xml(part) : %(<w:r><w:t>#{part[:text]}</w:t></w:r>)
  end

  def self.change_xml(change)
    tag = CHANGE_TAG.fetch(change[:change])
    attrs = %(w:id="#{change[:id]}" w:author="#{change[:author]}" w:date="#{change[:date]}")

    return %(<#{tag} #{attrs}>#{change[:nested].map { |child| change_xml(child) }.join}</#{tag}>) if change[:nested]

    text_tag = change[:change] == :del ? "w:delText" : "w:t"
    %(<#{tag} #{attrs}><w:r><#{text_tag}>#{change[:text]}</#{text_tag}></w:r></#{tag}>)
  end
end
