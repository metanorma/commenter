# frozen_string_literal: true

require "lutaml/model"

module Commenter
  # A single comment on a reviewed document. (De)serialization is declared
  # with lutaml-model; the only custom mapping logic is the type expansion
  # (short codes to full names) and empty-observation omission, both at the
  # YAML boundary.
  class Comment < Lutaml::Model::Serializable
    attribute :id, :string
    attribute :body, :string
    attribute :locality, CommentLocality
    attribute :type, :string
    attribute :comments, :string
    attribute :proposed_change, :string
    attribute :observations, :string

    # OSD-specific fields
    attribute :user_name, :string
    attribute :comment_type, :string
    attribute :resolution_status, :string
    attribute :resolution_date, :string
    attribute :feedbacks, :string
    attribute :motivation, :string
    attribute :created_date, :string
    attribute :stage_code, :string

    attribute :github, GithubInfo

    yaml do
      map "id", to: :id
      map "body", to: :body
      map "locality", to: :locality
      map "type", with: { to: :type_to_yaml, from: :type_from_yaml }
      map "comments", to: :comments
      map "proposed_change", to: :proposed_change
      map "observations", with: { to: :observations_to_yaml, from: :observations_from_yaml }
      map "user_name", to: :user_name
      map "comment_type", to: :comment_type
      map "resolution_status", to: :resolution_status
      map "resolution_date", to: :resolution_date
      map "feedbacks", to: :feedbacks
      map "motivation", to: :motivation
      map "created_date", to: :created_date
      map "stage_code", to: :stage_code
      map "github", to: :github
    end

    def type_from_yaml(model, value)
      model.type = CommentType.full_name(value)
    end

    def type_to_yaml(model, doc)
      doc["type"] = model.type if model.type && !model.type.empty?
    end

    def observations_from_yaml(model, value)
      model.observations = value.to_s.empty? ? nil : value
    end

    def observations_to_yaml(model, doc)
      doc["observations"] = model.observations if model.observations && !model.observations.empty?
    end

    def expand_comment_type(type)
      CommentType.full_name(type)
    end

    def to_h
      Comment.to_hash(self)
    end

    alias to_yaml_h to_h

    def line_number
      locality&.line_number
    end

    def line_number=(value)
      self.locality = CommentLocality.new if locality.nil?
      locality.line_number = value
    end

    def clause
      locality&.clause
    end

    def clause=(value)
      self.locality = CommentLocality.new if locality.nil?
      locality.clause = value
    end

    def element
      locality&.element
    end

    def element=(value)
      self.locality = CommentLocality.new if locality.nil?
      locality.element = value
    end

    def brief_summary(max_length = 60)
      description = comments.to_s.split(/[.!?\n]/).map(&:strip).reject(&:empty?).first.to_s
      locality_text = format_locality

      if description.empty?
        locality_text.empty? ? "No description" : locality_text
      elsif locality_text.empty?
        combined = description
        combined.length <= max_length ? combined : "#{combined[0...(max_length - 3)]}..."
      else
        combined = "#{locality_text}: #{description}"
        combined.length <= max_length ? combined : "#{locality_text}: #{description[0...(max_length - locality_text.length - 2)]}"
      end
    end

    def github_issue_number
      github&.issue_number
    end

    def github_issue_url
      github&.issue_url
    end

    def github_status
      github&.status
    end

    def github_created_at
      github&.created_at
    end

    def github_updated_at
      github&.updated_at
    end

    def has_github_issue?
      !github&.issue_number.nil?
    end

    def record_github_issue(issue_number:, issue_url:, status:, created_at: nil)
      self.github = GithubInfo.new(issue_number: issue_number, issue_url: issue_url,
                                   status: status, created_at: created_at)
    end

    private

    def format_locality
      parts = []
      parts << "Clause #{clause}" if clause && !clause.strip.empty?
      parts << element if element && !element.strip.empty?
      parts << "Line #{line_number}" if line_number && !line_number.strip.empty?
      parts.join(", ")
    end
  end
end
