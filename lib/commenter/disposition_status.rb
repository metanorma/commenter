# frozen_string_literal: true

module Commenter
  # Canonical disposition vocabulary, shared by cell shading (Filler) and
  # ballot statistics (BallotReport). Matches free-text observations and
  # OSD's structured resolution_status values. One home for the question
  # "what counts as an accepted disposition".
  module DispositionStatus
    PATTERNS = [
      [:accept_with_modifications, /awm|accept(ed)?[ ,]*with +(modifications|changes)/].freeze,
      [:rejected, /reject(ed)?|not accepted/].freeze,
      [:accepted, /accept(ed)?/].freeze,
      [:noted, /noted/].freeze,
      [:todo, /todo/].freeze
    ].freeze

    module_function

    # Returns the canonical status symbol for the given text, or nil when
    # nothing matches. Order matters: "accept with modifications" and
    # "not accepted" must be classified before the bare "accept" pattern.
    def match(text)
      value = text.to_s.downcase.strip
      return nil if value.empty?

      PATTERNS.each do |status, pattern|
        return status if value.match?(pattern)
      end

      nil
    end

    def statuses
      PATTERNS.map(&:first)
    end
  end
end
