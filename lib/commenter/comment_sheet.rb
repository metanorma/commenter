# frozen_string_literal: true

require_relative "comment"

module Commenter
  class CommentSheet
    attr_accessor :version, :date, :document, :project, :stage, :comments, :title_en, :title_fr

    def initialize(attributes = {})
      # Normalize input to symbols
      attrs = symbolize_keys(attributes)

      @version = attrs[:version] || "2012-03"
      @date = attrs[:date]
      @document = attrs[:document]
      @project = attrs[:project]
      @stage = attrs[:stage]
      @title_en = attrs[:title_en]
      @title_fr = attrs[:title_fr]
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
        title_en: @title_en,
        title_fr: @title_fr,
        comments: @comments.map(&:to_h)
      }
    end

    def to_yaml_h
      hash = to_h.merge(comments: @comments.map(&:to_yaml_h))
      # Remove nil-valued keys for cleaner YAML output
      hash.delete(:title_en) if hash[:title_en].nil?
      hash.delete(:title_fr) if hash[:title_fr].nil?
      stringify_keys(hash)
    end

    def schema_name
      version == "osd" ? "iso_comment_osd.yaml" : "iso_comment_2012-03.yaml"
    end

    def to_yaml_document(schema_dir = "schema")
      "# yaml-language-server: $schema=#{File.join(schema_dir.to_s, schema_name)}\n\n#{to_yaml_h.to_yaml}"
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
