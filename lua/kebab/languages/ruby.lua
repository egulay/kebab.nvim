-- Ruby.
local S = require("kebab.scaffold")

return {
  key = "ruby",
  label = "Ruby",
  kind = "ruby",
  filetypes = { "ruby", "eruby", "rake" },

  markers = {
    {
      file = "Gemfile",
      kind = "ruby",
      deps = {
        prompt = "Gem to add: ",
        -- `bundle add` resolves a version and writes both the Gemfile and the
        -- lockfile, so there is nothing to hand-edit.
        command = function(package, opts)
          local cmd = { "bundle", "add" }
          if opts and opts.dev then
            vim.list_extend(cmd, { "--group", "development,test" })
          end
          table.insert(cmd, package)
          return cmd
        end,
      },
    },
    { file = ".ruby-version", kind = "ruby" },
  },

  extras = { "lazyvim.plugins.extras.lang.ruby" },
  tools = { "ruby-lsp", "rubocop" },

  tasks = {
    { name = "ruby: run current file", cmd = { "ruby" }, args = { "%:p" }, desc = "Run the file in the current buffer", filetypes = { "ruby" } },
    { name = "bundle: install", cmd = { "bundle" }, args = { "install" }, desc = "Install gems", marker = "Gemfile" },
    { name = "rspec", cmd = { "bundle" }, args = { "exec", "rspec" }, desc = "Run the specs", marker = "Gemfile" },
    { name = "rake", cmd = { "bundle" }, args = { "exec", "rake" }, desc = "Run the default rake task", marker = "Rakefile" },
    { name = "rubocop", cmd = { "bundle" }, args = { "exec", "rubocop" }, desc = "Lint", marker = "Gemfile" },
  },

  scratch = {
    {
      key = "rb",
      name = "Ruby",
      extension = "rb",
      filetype = "ruby",
      lines = { "# frozen_string_literal: true", "", 'puts "hello"' },
    },
  },

  templates = {
    {
      name = "Ruby class",
      extension = "rb",
      prompt = "Class name (snake_case file, CamelCase class)",
      filetypes = { "ruby" },
      render = function(ctx)
        -- Ruby files are snake_case and classes are CamelCase, so the class
        -- name is derived rather than taken literally.
        local class = ctx.name:gsub("_(%l)", function(c) return c:upper() end):gsub("^%l", string.upper)
        return {
          "# frozen_string_literal: true",
          "",
          ("class %s"):format(class),
          "end",
          "",
        }
      end,
    },
    {
      name = "Ruby module",
      extension = "rb",
      prompt = "Module name",
      filetypes = { "ruby" },
      render = function(ctx)
        local mod = ctx.name:gsub("_(%l)", function(c) return c:upper() end):gsub("^%l", string.upper)
        return {
          "# frozen_string_literal: true",
          "",
          ("module %s"):format(mod),
          "end",
          "",
        }
      end,
    },
    {
      name = "RSpec spec",
      extension = "rb",
      prompt = "Spec name",
      filetypes = { "ruby" },
      default_name = function(current)
        if current == nil or current == "" then
          return nil
        end
        return current:match("_spec$") and current or (current .. "_spec")
      end,
      render = function(ctx)
        local subject = ctx.name:gsub("_spec$", "")
        local class = subject:gsub("_(%l)", function(c) return c:upper() end):gsub("^%l", string.upper)
        return {
          "# frozen_string_literal: true",
          "",
          ('require "spec_helper"'),
          "",
          ("RSpec.describe %s do"):format(class),
          '  it "works" do',
          "    expect(true).to be true",
          "  end",
          "end",
          "",
        }
      end,
    },
  },

  project_files = {
    {
      name = ".gitignore (Ruby)",
      file = ".gitignore",
      kinds = { "ruby" },
      lines = {
        "/.bundle/", "/vendor/bundle", "/pkg/", "/tmp/", "/log/",
        "/coverage/", "*.gem", ".rspec_status",
        "", "# local config", ".env",
      },
    },
    {
      name = "Dockerfile (Ruby)",
      file = "Dockerfile",
      kinds = { "ruby" },
      lines = {
        "FROM ruby:3.3-slim",
        "WORKDIR /app",
        "",
        "RUN apt-get update -qq && apt-get install -y --no-install-recommends build-essential \\",
        "    && rm -rf /var/lib/apt/lists/*",
        "",
        "# Copy the manifests first so bundle install caches across source edits.",
        "COPY Gemfile Gemfile.lock* ./",
        "RUN bundle config set --local without development:test && bundle install",
        "",
        "COPY . .",
        "RUN useradd --create-home app && chown -R app /app",
        "USER app",
        'CMD ["bundle", "exec", "ruby", "lib/main.rb"]',
      },
    },
    {
      name = "GitHub Actions (Ruby)",
      file = ".github/workflows/test.yml",
      kinds = { "ruby" },
      lines = {
        "name: test",
        "",
        "on:",
        "  push:",
        "    branches: [main]",
        "  pull_request:",
        "",
        "jobs:",
        "  test:",
        "    runs-on: ubuntu-latest",
        "    steps:",
        "      - uses: actions/checkout@v4",
        "      - uses: ruby/setup-ruby@v1",
        "        with:",
        '          ruby-version: "3.3"',
        "          bundler-cache: true",
        "      - run: bundle exec rubocop",
        "      - run: bundle exec rspec",
      },
    },
  },

  project_types = {
    {
      key = "ruby",
      label = "Ruby (bundler + rspec)",
      requires = { "git", "ruby" },
      build = function(ctx, done)
        local name = S.sanitise(ctx.name, "snake")
        S.mkdir(ctx.dest)
        S.write_file(ctx.dest .. "/Gemfile", {
          "# frozen_string_literal: true",
          "",
          'source "https://rubygems.org"',
          "",
          "group :development, :test do",
          '  gem "rspec"',
          '  gem "rubocop", require: false',
          "end",
          "",
        })
        S.write_file(ctx.dest .. "/lib/" .. name .. ".rb", {
          "# frozen_string_literal: true",
          "",
          ("module %s"):format(name:gsub("_(%l)", function(c) return c:upper() end):gsub("^%l", string.upper)),
          "  def self.call",
          '    "hello"',
          "  end",
          "end",
          "",
        })
        S.write_file(ctx.dest .. "/spec/spec_helper.rb", {
          "# frozen_string_literal: true",
          "",
          ('require "%s"'):format(name),
          "",
          "RSpec.configure do |config|",
          "  config.disable_monkey_patching!",
          "end",
          "",
        })
        S.write_file(ctx.dest .. "/spec/" .. name .. "_spec.rb", {
          "# frozen_string_literal: true",
          "",
          ('require "spec_helper"'),
          "",
          ("RSpec.describe %s do"):format(name:gsub("_(%l)", function(c) return c:upper() end):gsub("^%l", string.upper)),
          '  it "says hello" do',
          '    expect(described_class.call).to eq("hello")',
          "  end",
          "end",
          "",
        })
        S.write_file(ctx.dest .. "/.rspec", { "--require spec_helper", "--format documentation" })
        S.write_file(ctx.dest .. "/.gitignore", {
          "/.bundle/", "/vendor/bundle", "/pkg/", "/tmp/", "*.gem", ".rspec_status",
        })
        S.run_steps({ { label = "git init", cmd = { "git", "init", "-q" } } }, ctx.dest, done)
      end,
    },
  },
}
