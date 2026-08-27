# frozen_string_literal: true

require "spec_helper"

RSpec.describe Commenter::CommentType do
  describe ".code" do
    it "maps full names and codes to codes" do
      expect(described_class.code("Editorial")).to eq("ed")
      expect(described_class.code("general")).to eq("ge")
      expect(described_class.code("te")).to eq("te")
    end

    it "passes unrecognized values through" do
      expect(described_class.code("custom")).to eq("custom")
      expect(described_class.code("")).to eq("")
      expect(described_class.code(nil)).to be_nil
    end
  end

  describe ".full_name" do
    it "expands codes to full names" do
      expect(described_class.full_name("ge")).to eq("general")
      expect(described_class.full_name("TE")).to eq("technical")
      expect(described_class.full_name("editorial")).to eq("editorial")
    end

    it "passes unrecognized values through" do
      expect(described_class.full_name("Custom")).to eq("Custom")
      expect(described_class.full_name(nil)).to be_nil
    end
  end

  describe ".display_name" do
    it "capitalizes recognized types for display" do
      expect(described_class.display_name("ge")).to eq("General")
      expect(described_class.display_name("technical")).to eq("Technical")
      expect(described_class.display_name("ed")).to eq("Editorial")
    end

    it "defaults unknown or missing types" do
      expect(described_class.display_name("unknown")).to eq("unknown")
      expect(described_class.display_name(nil)).to eq("Unknown")
    end
  end
end
