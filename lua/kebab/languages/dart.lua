-- Dart and Flutter. flutter-tools owns dartls; see plugins/flutter.lua.
local S = require("kebab.scaffold")

return {
  key = "dart",
  label = "Dart / Flutter",
  kind = "flutter",
  filetypes = { "dart" },

  markers = {
    {
      file = "pubspec.yaml",
      kind = "flutter",
      deps = {
        prompt = "Package to add (pub.dev): ",
        command = function(package, opts)
          local cmd = { "flutter", "pub", "add" }
          if opts and opts.dev then
            table.insert(cmd, "--dev")
          end
          table.insert(cmd, package)
          return cmd
        end,
      },
    },
  },

  extras = { "lazyvim.plugins.extras.lang.dart" },
  tools = {},

  tasks = {
    { name = "flutter: run", cmd = { "flutter" }, args = { "run" }, desc = "Run on the selected device", marker = "pubspec.yaml" },
    { name = "flutter: test", cmd = { "flutter" }, args = { "test" }, desc = "Run all tests", marker = "pubspec.yaml" },
    { name = "flutter: pub get", cmd = { "flutter" }, args = { "pub", "get" }, desc = "Fetch dependencies", marker = "pubspec.yaml" },
    { name = "flutter: analyze", cmd = { "flutter" }, args = { "analyze" }, desc = "Static analysis", marker = "pubspec.yaml" },
  },

  project_files = {
    {
      name = ".gitignore (Flutter)",
      file = ".gitignore",
      kinds = { "flutter" },
      lines = {
        ".dart_tool/", ".packages", "build/", ".flutter-plugins", ".flutter-plugins-dependencies",
        "*.iml", ".idea/",
        "", "# local config", ".env",
      },
    },
    {
      name = "GitHub Actions (Flutter)",
      file = ".github/workflows/test.yml",
      kinds = { "flutter" },
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
        "      - uses: subosito/flutter-action@v2",
        "        with:",
        "          channel: stable",
        "      - run: flutter pub get",
        "      - run: flutter analyze",
        "      - run: flutter test",
      },
    },
  },

  project_types = {
    {
      key = "flutter",
      label = "Flutter app",
      requires = { "flutter" },
      build = function(ctx, done)
        local pname = S.sanitise(ctx.name, "snake")
        S.mkdir(S.parent_of(ctx.dest))
        S.run_steps({
          { label = "flutter create", cmd = { "flutter", "create", "--project-name", pname, ctx.dest } },
        }, S.parent_of(ctx.dest), done)
      end,
    },
  },
}
