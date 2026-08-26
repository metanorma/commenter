# frozen_string_literal: true

require "tmpdir"
require_relative "xlsx_builder"

# Fixture data and helpers mirroring ISO OSD XLSX exports for specs.
module OsdFixtures
  RESOLVED_HEADERS = [
    "Comment ID", "User name", "Clause nb", "Clause Title", "Type", "Subtype",
    "Comment", "Proposal on Text", "Proposed change", "Feedbacks", "Topic",
    "Tags", "Created Date", "Resolution status", "Motivation", "Resolution Date", "Stage code"
  ].freeze

  UNRESOLVED_HEADERS = [
    "User name", "Clause nb", "Clause Title", "Type", "Comment type",
    "Comment/Motivation", "Comment on text", "Proposal on Text", "Proposed change",
    "Replies", "Resolution status", "Justification", "Resolution Date", "Date", "Comment number"
  ].freeze

  METADATA_ROWS = [
    ["Date", "Reference", nil, nil, "Title EN", nil, nil, "Title FR"],
    ["2026-04-21", "ISO/DIS 5843-6(en)", nil, nil, "Aerodromes and heliports",
     nil, nil, "Aerodromes and heliports (FR)"]
  ].freeze

  RESOLVED_DATA_ROWS = [
    [1, "John Doe", "5.2.1", "Requirements", "Comment", "Editorial",
     "The values in Table 3 are inconsistent.", "Proposal on the text",
     "Correct the values in column 2.", "Feedback from the working group",
     "Topic A", "tag1", "2026-04-01", "Accepted",
     "Reviewed and approved by the working group.", "2026-04-10", "40.20"],
    [],
    [2, "Jane Roe", nil, nil, "Comment", "Technical", "General remark on the introduction.",
     nil, nil, nil, nil, nil, "2026-04-02", "Rejected", nil, nil, "40.20"]
  ].freeze

  def resolved_rows(gap: false)
    headers = RESOLVED_HEADERS.dup
    data_rows = RESOLVED_DATA_ROWS.map(&:dup)
    if gap
      headers.insert(5, nil)
      data_rows = data_rows.map { |row| row.empty? ? row : row.insert(5, nil) }
    end

    METADATA_ROWS + [[]] + [headers] + data_rows
  end

  def unresolved_workbook_sheets
    [
      ["Comments (3)",
       header_block(UNRESOLVED_HEADERS) + [
         ["John Doe", "5.2.1", "Requirements", "Comment", "Editorial",
          "The scope is too narrow.", "On text remark", "Proposal on the text",
          "Widen the scope to include heliports.", "Reply from secretariat",
          nil, "Justification text", nil, "2026-04-05", 7],
         ["Jane Roe", "3.1", "Terms", "Comment", "Technical", "Define the term consistently.",
          nil, nil, "Add a definition.", nil, nil, nil, nil, "2026-04-06", 8]
       ]],
      ["Unresolved comments (1)",
       header_block(UNRESOLVED_HEADERS) + [
         ["Jack Black", "4.2", "Design", "Comment", "General", "Improve the design section.",
          nil, nil, nil, nil, nil, nil, nil, "2026-04-07", 9]
       ]],
      ["Resolved comments (1)",
       header_block(RESOLVED_HEADERS) + [
         [10, "Jill Hill", "6.1", "Testing", "Comment", "Technical", "Add test requirements.",
          nil, nil, nil, nil, nil, "2026-04-08", "Partially accepted",
          "Compromise reached.", "2026-04-12", "40.92"]
       ]]
    ]
  end

  def with_resolved_xlsx(rows = nil)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "comments.xlsx")
      XlsxBuilder.write(path, [["Comments (2)", rows || resolved_rows]])
      yield path
    end
  end

  def with_unresolved_workbook
    Dir.mktmpdir do |dir|
      path = File.join(dir, "workbook.xlsx")
      XlsxBuilder.write(path, unresolved_workbook_sheets)
      yield path
    end
  end

  private

  def header_block(headers)
    METADATA_ROWS + [[]] + [headers]
  end
end
