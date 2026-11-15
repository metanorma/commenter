# frozen_string_literal: true

module Commenter
  # Resolves (and optionally creates) the GitHub milestone issues are
  # assigned to: a `number` config passes through; a `name` resolves
  # against the repository; `create_if_missing` mints the milestone on
  # first use, honoring `description` and `due_date`.
  class MilestoneResolver
    def initialize(client, repo, config)
      @client = client
      @repo = repo
      @config = config
    end

    def number
      return @config["number"] if @config["number"]
      return nil unless @config["name"]

      @number ||= resolve
      @number ||= create if @config["create_if_missing"]
      @number
    end

    private

    def resolve
      return @config["name"].to_i if @config["name"].to_s.match?(/\A\d+\z/)

      milestones = @client.milestones(@repo, state: "all")
      puts "[GitHubIssueCreator] Found #{milestones.size} milestones in repository #{@repo}" if milestones.any?
      milestones.find { |milestone| milestone.title == @config["name"] }&.number
    rescue Octokit::Error
      nil
    end

    def create
      options = {}
      options[:description] = @config["description"] if @config["description"]
      if (due = @config["due_date"])
        options[:due_on] = due.include?("T") ? due : "#{due}T00:00:00Z"
      end
      milestone = @client.create_milestone(@repo, @config["name"], options)
      puts "[GitHubIssueCreator] Created milestone ##{milestone.number}: #{@config["name"]}"
      milestone.number
    rescue Octokit::Error => e
      puts "[GitHubIssueCreator] Could not create milestone #{@config["name"].inspect}: #{e.message}"
      nil
    end
  end
end
