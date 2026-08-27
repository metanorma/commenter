# frozen_string_literal: true

module Commenter
  # Single home for the comment type vocabulary: short codes (ge/te/ed) and
  # their expanded names (general/technical/editorial). Unrecognized values
  # pass through unchanged; display_name capitalizes recognized types.
  module CommentType
    FULL_NAMES = {
      "ge" => "general",
      "te" => "technical",
      "ed" => "editorial"
    }.freeze

    CODES = FULL_NAMES.invert.freeze

    DISPLAY_NAMES = FULL_NAMES.each_with_object({}) do |(code, full), display|
      display[code] = full.capitalize
      display[full] = full.capitalize
    end.freeze

    module_function

    def code(type)
      CODES.fetch(type.to_s.strip.downcase) { type&.to_s&.strip }
    end

    def full_name(type)
      FULL_NAMES.fetch(type.to_s.strip.downcase) { type&.to_s&.strip }
    end

    def display_name(type)
      DISPLAY_NAMES.fetch(type.to_s.strip.downcase) { type || "Unknown" }
    end
  end
end
