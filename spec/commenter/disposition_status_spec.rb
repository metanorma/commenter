# frozen_string_literal: true

require "spec_helper"

RSpec.describe Commenter::DispositionStatus do
  describe ".match" do
    it "classifies accepted dispositions" do
      expect(described_class.match("Accepted")).to eq(:accepted)
      expect(described_class.match("accepted.")).to eq(:accepted)
      expect(described_class.match("Partially accepted")).to eq(:accepted)
    end

    it "classifies accept-with-modifications before the bare accept pattern" do
      expect(described_class.match("Accept with modifications")).to eq(:accept_with_modifications)
      expect(described_class.match("Accepted with modifications")).to eq(:accept_with_modifications)
      expect(described_class.match("Accepted, with changes")).to eq(:accept_with_modifications)
      expect(described_class.match("AWM")).to eq(:accept_with_modifications)
    end

    it "classifies rejection including the 'not accepted' phrasing" do
      expect(described_class.match("Rejected")).to eq(:rejected)
      expect(described_class.match("Not accepted")).to eq(:rejected)
    end

    it "classifies noted, todo, and non-matching text" do
      expect(described_class.match("Noted")).to eq(:noted)
      expect(described_class.match("TODO: review")).to eq(:todo)
      expect(described_class.match("Deferred to next revision")).to be_nil
      expect(described_class.match("")).to be_nil
      expect(described_class.match(nil)).to be_nil
    end
  end

  describe ".statuses" do
    it "lists the canonical statuses" do
      expect(described_class.statuses)
        .to eq(%i[accept_with_modifications rejected accepted noted todo])
    end
  end
end
