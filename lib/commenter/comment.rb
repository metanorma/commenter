# frozen_string_literal: true

module Commenter
  class Comment
    attr_accessor :id, :body, :locality, :type, :comments, :proposed_change, :observations, :github

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
      @github = symbolize_keys(attrs[:github] || {})
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

    def brief_summary(max_length = 80)
      parts = []

      # Add locality information first
      parts << "Clause #{clause}" if clause && !clause.strip.empty?
      parts << element if element && !element.strip.empty?
      parts << "Line #{line_number}" if line_number && !line_number.strip.empty?

      locality_text = parts.join(", ")

      # Add description from comment text
      if @comments && !@comments.strip.empty?
        # Extract first sentence or truncate
        clean_text = @comments.strip.gsub(/\s+/, " ")
        first_sentence = clean_text.split(/[.!?]/).first&.strip
        description = if first_sentence && first_sentence.length < max_length
                        first_sentence
                      else
                        clean_text[0...50]
                      end

        if locality_text.empty?
          description
        else
          # Combine locality + description, respecting max_length
          combined = "#{locality_text}: #{description}"
          combined.length <= max_length ? combined : "#{locality_text}: #{description[0...(max_length - locality_text.length - 2)]}"
        end
      else
        locality_text.empty? ? "No description" : locality_text
      end
    end

    def github_issue_number
      @github[:issue_number]
    end

    def github_issue_url
      @github[:issue_url]
    end

    def github_status
      @github[:status]
    end

    def github_created_at
      @github[:created_at]
    end

    def github_updated_at
      @github[:updated_at]
    end

    def has_github_issue?
      !@github[:issue_number].nil?
    end

    def to_h
      {
        id: @id,
        body: @body,
        locality: @locality,
        type: @type,
        comments: @comments,
        proposed_change: @proposed_change,
        observations: @observations,
        github: @github.empty? ? nil : @github
      }.compact
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
