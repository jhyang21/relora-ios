source "https://rubygems.org"

gem "fastlane", ">= 2.226", "< 3.0"

# No Gemfile.lock is committed: this repo is authored on Windows and the
# lock file fastlane/bundler would generate here targets a non-darwin
# platform set, which breaks `bundle install` on the macOS CI runner
# (missing darwin-specific platform entries). CI runs a plain
# `bundle install` against this Gemfile on every run instead, which is
# slightly slower but always resolves gems for the runner it's on.
