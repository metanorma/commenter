# frozen_string_literal: true

require "lutaml/model"

module Commenter
  # Location of a comment within the reviewed document.
  class CommentLocality < Lutaml::Model::Serializable
    attribute :line_number, :string
    attribute :clause, :string
    attribute :element, :string

    yaml do
      map "line_number", to: :line_number
      map "clause", to: :clause
      map "element", to: :element
    end
  end
end
