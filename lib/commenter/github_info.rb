# frozen_string_literal: true

require "lutaml/model"

module Commenter
  # GitHub issue tracking state attached to a comment by github-create /
  # github-retrieve.
  class GithubInfo < Lutaml::Model::Serializable
    attribute :issue_number, :integer
    attribute :issue_url, :string
    attribute :status, :string
    attribute :created_at, :string
    attribute :updated_at, :string

    yaml do
      map "issue_number", to: :issue_number
      map "issue_url", to: :issue_url
      map "status", to: :status
      map "created_at", to: :created_at
      map "updated_at", to: :updated_at
    end
  end
end
