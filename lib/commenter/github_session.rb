# frozen_string_literal: true

require "octokit"
require "yaml"

module Commenter
  # Shared connection setup for the GitHub integration commands: loads the
  # configuration file, builds the Octokit client, and resolves the target
  # repository. One constructor, one test surface.
  class GitHubSession
    attr_reader :config, :client, :repo

    def initialize(config_path)
      @config = load_config(config_path)
      @client = Octokit::Client.new(access_token: required_token)
      @repo = @config.dig("github", "repository")
      raise "GitHub repository not specified in config" unless @repo
    end

    private

    def load_config(config_path)
      YAML.load_file(config_path)
    rescue Errno::ENOENT
      raise "Configuration file not found: #{config_path}"
    end

    def required_token
      token = @config.dig("github", "token") || ENV["GITHUB_TOKEN"]
      raise "GitHub token not found. Set GITHUB_TOKEN environment variable or specify in config file." unless token

      token
    end
  end
end
