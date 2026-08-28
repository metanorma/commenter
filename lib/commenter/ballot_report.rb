# frozen_string_literal: true

module Commenter
  # Disposition statistics over a comment sheet: the counts ballot reports
  # need — comments per member body by disposition, and per comment type.
  module BallotReport
    module_function

    # status bucket for one comment: matched observation text, else matched
    # OSD resolution_status, else open when a GitHub issue is still open,
    # else undecided.
    def status_for(comment)
      DispositionStatus.match(comment.observations) ||
        DispositionStatus.match(comment.resolution_status) ||
        (comment.github&.status == "open" ? :open : nil) ||
        (comment.observations.to_s.strip.empty? && comment.resolution_status.to_s.strip.empty? ? :undecided : nil)
    end

    def counts(comment_sheet)
      bodies = Hash.new { |hash, body| hash[body] = bucket_hash }
      types = Hash.new(0)
      comment_sheet.comments.each do |comment|
        body = comment.body.to_s.strip.empty? ? "(unknown)" : comment.body
        bodies[body][:total] += 1
        status = status_for(comment)
        bodies[body][status] += 1 if status
        types[comment.type.to_s.strip.empty? ? "(untyped)" : comment.type] += 1
      end
      { total: bodies.values.sum { |bucket| bucket[:total] }, bodies: bodies, types: types }
    end

    def to_markdown(comment_sheet)
      data = counts(comment_sheet)
      sorted_bodies = data[:bodies].sort_by { |body, _| body }

      lines = []
      lines << "| Body | Total | Accepted | AWM | Noted | Rejected | TODO | Open | Undecided |"
      lines << "|------|-------|----------|-----|-------|----------|------|------|-----------|"
      sorted_bodies.each do |body, bucket|
        lines << "| #{body} | #{bucket[:total]} | #{bucket[:accepted]} | #{bucket[:accept_with_modifications]} | " \
                 "#{bucket[:noted]} | #{bucket[:rejected]} | #{bucket[:todo]} | #{bucket[:open]} | #{bucket[:undecided]} |"
      end
      totals = data[:bodies].values.reduce(bucket_hash) { |sum, bucket| merge_bucket(sum, bucket) }
      lines << "| **Total** | **#{totals[:total]}** | **#{totals[:accepted]}** | " \
               "**#{totals[:accept_with_modifications]}** | **#{totals[:noted]}** | " \
               "**#{totals[:rejected]}** | **#{totals[:todo]}** | **#{totals[:open]}** | **#{totals[:undecided]}** |"
      lines << ""
      lines << "Comment types: #{data[:types].sort_by { |type, _| type }.map { |type, count| "#{type} #{count}" }.join(" · ")}"
      lines.join("\n")
    end

    def bucket_hash
      { total: 0, accepted: 0, accept_with_modifications: 0, noted: 0, rejected: 0, todo: 0, open: 0, undecided: 0 }
    end

    def merge_bucket(sum, bucket)
      sum.merge(bucket) { |_key, accumulated, addition| accumulated + addition }
    end
  end
end
