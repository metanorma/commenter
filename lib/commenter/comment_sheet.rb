# frozen_string_literal: true

require "lutaml/model"

module Commenter
  # One ballot submission: metadata plus its comments. Serialization is
  # declared with lutaml-model.
  class CommentSheet < Lutaml::Model::Serializable
    attribute :version, :string, default: -> { "2012-03" }
    attribute :date, :string
    attribute :document, :string
    attribute :project, :string
    attribute :stage, :string
    attribute :title_en, :string
    attribute :title_fr, :string
    attribute :comments, Comment, collection: true

    yaml do
      map "version", to: :version
      map "date", to: :date
      map "document", to: :document
      map "project", to: :project
      map "stage", to: :stage
      map "title_en", to: :title_en
      map "title_fr", to: :title_fr
      map "comments", to: :comments
    end

    def add_comment(comment)
      self.comments = (comments || []) + [comment.is_a?(Comment) ? comment : Comment.from_hash(comment)]
    end

    def schema_name
      version == "osd" ? "iso_comment_osd.yaml" : "iso_comment_2012-03.yaml"
    end

    def to_yaml_document(schema_dir = "schema")
      "# yaml-language-server: $schema=#{File.join(schema_dir.to_s, schema_name)}\n\n#{to_yaml}"
    end

    def to_yaml_h
      CommentSheet.to_hash(self)
    end

    def to_h
      CommentSheet.to_hash(self)
    end
  end
end
