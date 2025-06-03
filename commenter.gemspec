# frozen_string_literal: true

require_relative "lib/commenter/version"

all_files_in_git = Dir.chdir(File.expand_path(__dir__)) do
  `git ls-files -z`.split("\x0")
end

Gem::Specification.new do |spec|
  spec.name = "commenter"
  spec.version = Commenter::VERSION
  spec.authors = ["Ribose"]
  spec.email = ["open.source@ribose.com"]

  spec.summary = "Library to work with ISO comment sheets in DOCX format."
  spec.description = "Convert between ISO comment sheet DOCX and structured YAML with schema validation."
  spec.homepage = "https://github.com/metanorma/commenter"
  spec.license = "BSD-2-Clause"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.6.0")

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"

  # Specify which files should be added to the gem when it is released.
  spec.files = all_files_in_git
               .reject { |f| f.match(%r{\A(?:test|features|bin|\.)/}) }

  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "docx", "~> 0.8"
  spec.add_dependency "thor", "~> 1.0"
end
