# frozen_string_literal: true

module Commenter
  class Comment
    attr_accessor :id, :body, :locality, :type, :comments, :proposed_change, :observations

    def initialize(attributes = {})
      # Normalize input to symbols
      attrs = symbolize_keys(attributes)

      @id = attrs[:id]
      @body = attrs[:body]
      @locality = symbolize_keys(attrs[:locality] || {})
      @type = attrs[:type]
      @comments = attrs[:comments]
      @proposed_change = attrs[:proposed_change]
      @observations = attrs[:observations]
    end

    def line_number
      @locality[:line_number]
    end

    def line_number=(value)
      @locality[:line_number] = value
    end

    def clause
      @locality[:clause]
    end

    def clause=(value)
      @locality[:clause] = value
    end

    def element
      @locality[:element]
    end

    def element=(value)
      @locality[:element] = value
    end

    def to_h
      {
        id: @id,
        body: @body,
        locality: @locality,
        type: @type,
        comments: @comments,
        proposed_change: @proposed_change,
        observations: @observations
      }
    end

    def to_yaml_h
      hash = to_h
      # Remove observations if it's nil or empty
      hash.delete(:observations) if hash[:observations].nil? || hash[:observations] == ""
      stringify_keys(hash)
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
        new_value = value.is_a?(Hash) ? stringify_keys(value) : value
        result[new_key] = new_value
      end
    end
  end
end
