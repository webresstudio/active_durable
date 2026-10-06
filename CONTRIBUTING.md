# Contributing to ActiveDurable

Thanks for helping. A few things keep this project easy to maintain.

## The README is written twice

`README.md` (English) and `README.es.md` (Spanish) are the same document. Every change to one goes to the other in
the same pull request: the same sections in the same order, the same tables, code examples and images.

The animated diagrams are generated. Their words live in `TEXTS` inside `docs/assets/generate.rb`, once for `:en`
and once for `:es`; change both and run:

```bash
ruby docs/assets/generate.rb
```

`spec/readme_spec.rb` fails if the two READMEs drift apart, if an image is missing, or if an animation was not
regenerated. It checks the structure, not the meaning, so please translate the text too. If you do not write one
of the two languages, say so in the pull request and a maintainer will translate it.

## The website

`site/index.html` is published to GitHub Pages. Its texts live in the `i18n` block of that file, in English and
Spanish; change both. Preview it with:

```bash
bin/site serve
```

`spec/site_spec.rb` fails if a string exists in one language only, if an image is missing, or if a link points to a
README section that no longer exists.

## Before opening a pull request

```bash
bundle exec rspec                    # PostgreSQL
DB=mysql bundle exec rspec           # MySQL 8+
DB=sqlite3 bundle exec rspec         # SQLite 3
bundle exec rubocop
```

Other Rails versions live in `gemfiles/`: `BUNDLE_GEMFILE=gemfiles/rails-6.1.gemfile bundle exec rspec`. CI runs every
supported combination of Ruby, Rails and database.

Add a line to `CHANGELOG.md` under `[Unreleased]` for anything a user would notice.
