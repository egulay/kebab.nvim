-- Rust.
return {
  key = "rust",
  label = "Rust",
  kind = "rust",
  filetypes = { "rust" },

  markers = {
    {
      file = "Cargo.toml",
      kind = "rust",
      deps = {
        prompt = "Crate to add (e.g. serde, or serde@1.0): ",
        -- `cargo add` resolves the latest compatible version and edits
        -- Cargo.toml, so there is nothing to hand-write.
        command = function(package, opts)
          local cmd = { "cargo", "add" }
          if opts and opts.dev then
            table.insert(cmd, "--dev")
          end
          table.insert(cmd, package)
          return cmd
        end,
      },
    },
  },

  extras = { "lazyvim.plugins.extras.lang.rust" },
  tools = { "rust-analyzer", "codelldb", "taplo" },

  tasks = {
    { name = "cargo: run", cmd = { "cargo" }, args = { "run" }, desc = "Run the binary", marker = "Cargo.toml" },
    { name = "cargo: test", cmd = { "cargo" }, args = { "test" }, desc = "Run all tests", marker = "Cargo.toml" },
    { name = "cargo: build", cmd = { "cargo" }, args = { "build" }, desc = "Debug build", marker = "Cargo.toml" },
    { name = "cargo: build --release", cmd = { "cargo" }, args = { "build", "--release" }, desc = "Release build", marker = "Cargo.toml" },
    { name = "cargo: clippy", cmd = { "cargo" }, args = { "clippy", "--all-targets" }, desc = "Lint", marker = "Cargo.toml" },
    { name = "cargo: fmt", cmd = { "cargo" }, args = { "fmt" }, desc = "Format the crate", marker = "Cargo.toml" },
  },

  templates = {
    {
      name = "Rust module",
      extension = "rs",
      prompt = "Module name",
      filetypes = { "rust" },
      render = function(ctx)
        return {
          ("//! %s"):format(ctx.name),
          "",
          "#[cfg(test)]",
          "mod tests {",
          "    #[test]",
          "    fn todo() {",
          "        assert!(true);",
          "    }",
          "}",
          "",
        }
      end,
    },
  },

  scratch = {
    {
      key = "rs",
      name = "Rust",
      extension = "rs",
      filetype = "rust",
      lines = { "fn main() {", '    println!("hello");', "}" },
    },
  },

  project_files = {
    {
      name = ".gitignore (Rust)",
      file = ".gitignore",
      kinds = { "rust" },
      lines = { "/target/", "**/*.rs.bk", "*.pdb", "", "# local config", ".env" },
    },
    {
      name = "Dockerfile (Rust, multi-stage)",
      file = "Dockerfile",
      kinds = { "rust" },
      render = function(ctx)
        return {
          "FROM rust:1-slim AS build",
          "WORKDIR /src",
          "# Build the dependency graph first so it caches across source edits.",
          "COPY Cargo.toml Cargo.lock* ./",
          "RUN mkdir src && echo 'fn main() {}' > src/main.rs && cargo build --release && rm -rf src",
          "COPY src ./src",
          "RUN touch src/main.rs && cargo build --release",
          "",
          "FROM debian:bookworm-slim",
          ('LABEL org.opencontainers.image.title="%s"'):format(ctx.project),
          "RUN useradd --create-home app",
          "USER app",
          ("COPY --from=build /src/target/release/%s /usr/local/bin/app"):format(ctx.project),
          'ENTRYPOINT ["/usr/local/bin/app"]',
        }
      end,
    },
    {
      name = "GitHub Actions (Rust)",
      file = ".github/workflows/test.yml",
      kinds = { "rust" },
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
        "      - uses: dtolnay/rust-toolchain@stable",
        "        with:",
        "          components: clippy, rustfmt",
        "      - run: cargo fmt --check",
        "      - run: cargo clippy --all-targets -- -D warnings",
        "      - run: cargo test",
      },
    },
  },

  project_types = {
    {
      key = "rust",
      label = "Rust (cargo)",
      requires = { "cargo" },
      prompts = {
        {
          name = "kind",
          prompt = "Crate kind",
          kind = "select",
          choices = { "bin", "lib" },
          default = "bin",
        },
      },
      build = function(ctx, done)
        local S = require("kebab.scaffold")
        -- cargo creates the directory itself and initialises git, so it is
        -- given the destination directly.
        S.mkdir(S.parent_of(ctx.dest))
        S.run_steps({
          {
            label = "cargo new",
            cmd = {
              "cargo", "new", ctx.dest,
              "--" .. (ctx.answers.kind or "bin"),
              "--name", S.sanitise(ctx.name, "snake"),
            },
            cwd = S.parent_of(ctx.dest),
          },
        }, S.parent_of(ctx.dest), done)
      end,
    },
  },
}
