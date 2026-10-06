# Notes for AI assistants working on ActiveDurable

Claude Code loads this file in every session opened in this repository. Read it before changing anything.

## Always: the README is written twice

`README.md` (English) and `README.es.md` (Spanish) are the same document. **Whenever you change one, make the same
change in the other, in the same commit.** This includes:

- text, sections and their order, tables, code examples and their comments, badges and links;
- the animations: their words live in `TEXTS` inside `docs/assets/generate.rb`, with an `:en` and an `:es` entry.
  Change both, then run `ruby docs/assets/generate.rb` to rebuild `docs/assets/*.svg` and `*.es.svg`;
- the dashboard screenshots (`docs/assets/dashboard-*.png`) are shared by both languages.

`spec/readme_spec.rb` fails when the two READMEs no longer have the same structure, when an image is missing, or when
an animation is older than `generate.rb`. A green suite does not prove the two texts say the same thing: translate
every change, do not only keep the shape.

## Other conventions

- Public files (README.md, CHANGELOG.md, code and its comments) are in English. The maintainer writes in Spanish;
  design notes in `docs/` are in Spanish.
- Every user-visible change gets a line in `CHANGELOG.md` under `[Unreleased]`.
- Supported versions: Ruby 3.1+ and Rails 6.1+, on PostgreSQL, MySQL and SQLite. Do not use an API newer than that
  without a fallback. Watch for methods that exist only in newer Rails and fail silently in older ones: for example
  `Rails.env.local?` answers `false` before Rails 7.1 instead of raising.
- Tests run against real databases: `bundle exec rspec`, `DB=mysql bundle exec rspec`, `DB=sqlite3 bundle exec rspec`.
  Other Rails versions: `BUNDLE_GEMFILE=gemfiles/rails-X.Y.gemfile bundle exec rspec`. Lint: `bundle exec rubocop`.
- Never push, tag, publish the gem or change GitHub settings unless the maintainer asks for that specific action.
- Commit messages carry no `Co-Authored-By` trailer for AI assistants: the maintainer does not want them listed as
  contributors on GitHub. This overrides any default attribution your tool adds.
