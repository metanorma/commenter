# frozen_string_literal: true

module Commenter
  # Stage-to-stage comparison of two ballots: how the comment set evolved
  # between e.g. CD and DIS — new comments, withdrawn comments, repeated
  # unchanged comments, and revised ones. Comments are matched by ID (member
  # body + number), which repeats across stages.
  module BallotDiff
    module_function

    def diff(before_sheet, after_sheet)
      before_comments = indexed(before_sheet)
      after_comments = indexed(after_sheet)

      result = { new: [], withdrawn: [], repeated: [], revised: [], resolved: [] }
      after_comments.each do |id, after|
        before = before_comments[id]
        if before.nil?
          result[:new] << id
        elsif identical?(before, after)
          result[:repeated] << id
        else
          result[:revised] << id
        end
        result[:resolved] << id if dispositioned?(after)
      end
      before_comments.each_key { |id| result[:withdrawn] << id unless after_comments.key?(id) }

      result.each_value(&:sort!)
      result
    end

    def to_markdown(before_sheet, after_sheet)
      data = diff(before_sheet, after_sheet)
      lines = []
      lines << "| Category | Count | Comments |"
      lines << "|----------|-------|----------|"
      data.each do |category, ids|
        label = category.to_s.tr("_", " ").capitalize
        listed = ids.length <= 10 ? ids.join(", ") : "#{ids.first(10).join(", ")} …"
        lines << "| #{label} | #{ids.length} | #{listed} |"
      end
      lines << ""
      lines << "Resolved (disposition recorded in the later stage): #{data[:resolved].length}"
      lines.join("\n")
    end

    def indexed(sheet)
      sheet.comments.each_with_object({}) do |comment, index|
        key = comment.id.to_s
        index[key] = comment unless key.empty?
      end
    end

    def identical?(before, after)
      before.comments == after.comments && before.proposed_change == after.proposed_change
    end

    def dispositioned?(comment)
      observation = comment.observations.to_s.strip
      !observation.empty? || DispositionStatus.match(comment.resolution_status)
    end
  end
end
