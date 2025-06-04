# frozen_string_literal: true

require_relative "comment"

module Commenter
  class CommentSheet
    attr_accessor :version, :date, :document, :project, :stage, :comments

    def initialize(attributes = {})
      # Normalize input to symbols
      attrs = symbolize_keys(attributes)

      @version = attrs[:version] || "2012-03"
      @date = attrs[:date]
      @document = attrs[:document]
      @project = attrs[:project]
      @stage = attrs[:stage]
      @comments = (attrs[:comments] || []).map { |c| c.is_a?(Comment) ? c : Comment.from_hash(c) }
    end

    def add_comment(comment)
      @comments << (comment.is_a?(Comment) ? comment : Comment.from_hash(comment))
    end

    def to_h
      {
        version: @version,
        date: @date,
        document: @document,
        project: @project,
        stage: @stage,
        comments: @comments.map(&:to_h)
      }
    end

    def to_yaml_h
      stringify_keys(to_h.merge(comments: @comments.map(&:to_yaml_h)))
    end

    def self.from_hash(hash)
      new(hash)
    end

    private

    def symbolize_keys(hash)
      return hash unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(key, value), result|
        new_key = key.to_sym
        new_value = value.is_a?(Hash) ? symbolize_keys(value) : value
        result[new_key] = new_value
      end
    end

    def stringify_keys(hash)
      return hash unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(key, value), result|
        new_key = key.to_s
        new_value = case value
                    when Hash
                      stringify_keys(value)
                    when Array
                      value.map { |item| item.is_a?(Hash) ? stringify_keys(item) : item }
                    else
                      value
                    end
        result[new_key] = new_value
      end
    end
  end
end
