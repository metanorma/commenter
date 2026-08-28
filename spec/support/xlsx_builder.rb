# frozen_string_literal: true

require "zip"

# Builds minimal single-workbook XLSX files for specs, without needing a
# spreadsheet-writing dependency. Strings are stored via sharedStrings; numbers
# are written as plain numeric cells. Empty/nil cells are omitted (sparse
# rows), matching how real exports represent empty cells.
module XlsxBuilder
  SHEET_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
  RELS_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
  OFFICE_REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  private_constant :SHEET_NS, :RELS_NS, :OFFICE_REL_NS

  # sheets: array of [name, rows] pairs, where rows is an array of arrays.
  # Cell values: String or Numeric. nil and "" cells are skipped.
  def self.write(path, sheets)
    shared = []
    worksheets = sheets.map { |name, rows| [name, worksheet_xml(rows, shared)] }

    # In-memory buffer + File.binwrite rather than Zip::File#create + close:
    # rubyzip commits the latter with File.rename, which fails with EACCES on
    # Windows when the caller still holds an open handle on the destination.
    buffer = Zip::OutputStream.write_buffer do |out|
      write_entry(out, "[Content_Types].xml", content_types_xml(worksheets.size))
      write_entry(out, "_rels/.rels", root_rels_xml)
      write_entry(out, "xl/workbook.xml", workbook_xml(worksheets.map(&:first)))
      write_entry(out, "xl/_rels/workbook.xml.rels", workbook_rels_xml(worksheets.size))
      write_entry(out, "xl/sharedStrings.xml", shared_strings_xml(shared))
      write_entry(out, "xl/styles.xml", styles_xml)
      worksheets.each_with_index do |(_name, xml), index|
        write_entry(out, "xl/worksheets/sheet#{index + 1}.xml", xml)
      end
    end
    File.binwrite(path, buffer.string)
    path
  end

  def self.write_entry(out, name, content)
    out.put_next_entry(name)
    out.write(content)
  end

  def self.worksheet_xml(rows, shared)
    row_elements = rows.each_with_index.map do |values, row_number|
      cells = values.each_with_index.map do |value, column_index|
        cell_xml(value, row_number + 1, column_index, shared)
      end
      "<row r=\"#{row_number + 1}\">#{cells.compact.join}</row>"
    end

    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <worksheet xmlns="#{SHEET_NS}"><sheetData>#{row_elements.join}</sheetData></worksheet>
    XML
  end

  def self.cell_xml(value, row_number, column_index, shared)
    return if value.nil? || (value.is_a?(String) && value.empty?)

    ref = "#{column_name(column_index)}#{row_number}"
    return "<c r=\"#{ref}\"><v>#{value}</v></c>" if value.is_a?(Numeric)

    text = value.to_s
    index = shared.index(text)
    if index.nil?
      shared << text
      index = shared.length - 1
    end
    "<c r=\"#{ref}\" t=\"s\"><v>#{index}</v></c>"
  end

  def self.column_name(index)
    name = +""
    remainder = index
    loop do
      name.prepend((remainder % 26 + 65).chr)
      remainder = remainder / 26 - 1
      break if remainder.negative?
    end
    name
  end

  def self.shared_strings_xml(shared)
    entries = shared.map { |text| "<si><t>#{escape(text)}</t></si>" }
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <sst xmlns="#{SHEET_NS}" count="#{shared.length}" uniqueCount="#{shared.length}">#{entries.join}</sst>
    XML
  end

  def self.content_types_xml(sheet_count)
    overrides = [
      "<Override PartName=\"/xl/workbook.xml\" " \
        "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>",
      "<Override PartName=\"/xl/sharedStrings.xml\" " \
        "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>",
      "<Override PartName=\"/xl/styles.xml\" " \
        "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
    ]
    (1..sheet_count).each do |index|
      overrides << "<Override PartName=\"/xl/worksheets/sheet#{index}.xml\" " \
        "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
    end
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>#{overrides.join}</Types>
    XML
  end

  def self.root_rels_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="#{RELS_NS}"><Relationship Id="rId1" Type="#{OFFICE_REL_NS}/officeDocument" Target="xl/workbook.xml"/></Relationships>
    XML
  end

  def self.workbook_xml(sheet_names)
    sheets = sheet_names.each_with_index.map do |name, index|
      "<sheet name=\"#{escape(name)}\" sheetId=\"#{index + 1}\" r:id=\"rId#{index + 1}\"/>"
    end
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <workbook xmlns="#{SHEET_NS}" xmlns:r="#{OFFICE_REL_NS}"><sheets>#{sheets.join}</sheets></workbook>
    XML
  end

  def self.workbook_rels_xml(sheet_count)
    relationships = (1..sheet_count).map do |index|
      "<Relationship Id=\"rId#{index}\" Type=\"#{OFFICE_REL_NS}/worksheet\" Target=\"worksheets/sheet#{index}.xml\"/>"
    end
    relationships << "<Relationship Id=\"rId#{sheet_count + 1}\" Type=\"#{OFFICE_REL_NS}/sharedStrings\" " \
      "Target=\"sharedStrings.xml\"/>"
    relationships << "<Relationship Id=\"rId#{sheet_count + 2}\" Type=\"#{OFFICE_REL_NS}/styles\" " \
      "Target=\"styles.xml\"/>"
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="#{RELS_NS}">#{relationships.join}</Relationships>
    XML
  end

  def self.styles_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <styleSheet xmlns="#{SHEET_NS}"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>
    XML
  end

  def self.escape(text)
    text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
  end
end
