# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
bin/setup                        # install dependencies
bundle exec rake                 # default task: specs + RuboCop (this is what CI runs)
bundle exec rspec                # all specs
bundle exec rspec spec/commenter/comment_spec.rb          # single spec file
bundle exec rspec spec/commenter/comment_spec.rb:42       # single example
bundle exec rubocop              # lint (part of default rake task — must be clean)
bundle exec rubocop -a           # autocorrect
bundle exec exe/commenter        # run the CLI locally
bin/console                      # interactive prompt
```

CI (metanorma/ci `generic-rake.yml`) runs `bundle exec rake` on Ruby 3.2/3.4/4.0 across macOS/Ubuntu/Windows. RuboCop offenses fail CI — run `bundle exec rake`, not just rspec, before pushing. `Gemfile.lock` is gitignored; dependencies resolve fresh in CI.

Specs generate XLSX fixtures at runtime via `spec/support/xlsx_builder.rb` (plain rubyzip, no spreadsheet-writing dependency) plus row data in `spec/support/osd_fixtures.rb` — there are no binary fixture files in the repo. Redline DOCX fixtures are built at runtime via `spec/support/redline_docx_builder.rb` (same approach).

## Release

NEVER bump `lib/commenter/version.rb` by hand and never push tags. Releases go through the GHA workflow, which does the version bump, `v*` tag, and gem push itself:

```sh
gh workflow run release.yml --ref main -f next_version=X.Y.Z
```

The version number is the maintainer's decision — ask, never infer it from semver reasoning. PRs are rebase-merged.

## What this gem does

Converts ISO comment sheets to structured YAML and back, and syncs comments to GitHub issues:

- **Import**: DOCX (ISO 2012-03 balloting template) or XLSX (ISO Online Standards Development exports) → YAML + schema file. Format auto-detected from extension. Redline DOCX with tracked changes is dispatched to `Parser::TrackChangeDocxParser` via `--format redline`.
- **Fill**: YAML → filled DOCX comment sheet (`data/iso_comment_template_2012-03.docx`), optional status-based cell shading.
- **GitHub round-trip**: `github-create` makes issues from YAML via Liquid templates; `github-retrieve` pulls `> **OBSERVATION:**` blockquotes from closed issues back into the YAML's observations field.

Plain text only — formulas/images/complex formatting are unsupported (docx gem limitation).

## Architecture

Core flow: `Parser` → `CommentSheet` (metadata + `Comment` objects) → YAML / DOCX / GitHub issues.

- `Commenter::Comment` / `Commenter::CommentSheet` — data model. `Comment` carries the common fields plus optional OSD-specific fields (`user_name`, `resolution_status`, `motivation`, etc.) and a `github` sub-hash tracking issue state. Comment types: short codes (`ge`/`te`/`ed`) are expanded to full names (`general`/`technical`/`editorial`) when a `Comment` is loaded; YAML output stores the expanded form. The sheet's `version` field (`"2012-03"` vs `"osd"`) selects the output schema.
- `Commenter::Parser` — dispatches by format: `.docx` parsed inline with the `docx` gem; `.xlsx` delegated to `Parser::OsdXlsxParser` (uses `roo`); `redline` delegated to `Parser::TrackChangeDocxParser`.
- `Parser::OsdXlsxParser` — auto-detects two OSD export variants by header row ("resolved" 17-col starting `Comment ID`; "unresolved" 15-col starting `User name`), extracts metadata (date/reference/stage/titles) from header rows 1–2, maps columns by header name into `Comment` attributes, and synthesizes `observations` from `resolution_status` + `motivation`.
- `Parser::TrackChangeDocxParser` — redline DOCX import: streams `word/document.xml` with Nokogiri XML::Reader (redlines can exceed 100 MB), captures `w:ins`/`w:del`/`w:moveFrom`/`w:moveTo` as comment entries (`proposed_change` renders the change itself, e.g. `Insert: "text"`; clause resolved from the nearest preceding heading including sub-clauses; element resolved from Table/Figure/Formula/NOTE references in the same clause; self-closing paragraph-mark markers skipped), plus reviewer `w:comment` threads as `-CNNN` remark entries (remark verbatim in `comments`, instruction reworded in `proposed_change`, empty `observations` for the owner). Stamps `observations` from the `observations`/`accept_all` options.
- `Commenter::Filler` — writes comments into the DOCX template table; maps observation status text (`accept(ed)?`, `noted`, `reject(ed)?`, …) to shading colors.
- GitHub integration (`lib/commenter/github_integration.rb`) — two classes with parallel structure: `GitHubIssueCreator` (`github-create`) and `GitHubIssueRetriever` (`github-retrieve`). Each loads its own config YAML and Octokit client, and rewrites the comments YAML in place after the run. Duplicate detection searches issue titles for a unique ID rendered from a configurable Liquid `unique_id` template (stage-aware by default: `[DIS] GB-001`), so the same comment ID at different ballot stages creates separate issues.
- `Commenter::Cli` (`lib/commenter/cli.rb`) — Thor CLI with subcommands `import`, `fill`, `github-create`, `github-retrieve`.

### Schemas

`schema/iso_comment_2012-03.yaml` and `schema/iso_comment_osd.yaml` are JSON-Schema-style files for IDE validation. `import` copies the matching schema (based on sheet version) into the schema dir and stamps the YAML header with a `yaml-language-server` reference. When the data model changes, update the corresponding schema file.

### Templates

`data/github_issue_title_template.liquid` and `data/github_issue_body_template.liquid` render issue titles/bodies; both are user-overridable via config. See README.adoc for the full variable list.

## Conventions

- Ruby style: double-quoted strings (enforced by RuboCop).
- `data/` files (DOCX template, Liquid templates, sample config) are shipped with the gem and loaded relative to `__dir__` — do not treat them as disposable.
- Testing GitHub integration: use `--dry-run` with `GITHUB_TOKEN=dummy_token` — exercises template rendering without API calls.
- `sig/commenter.rbs` is a minimal stub; RBS coverage is not currently maintained.
