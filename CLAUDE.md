# kebab.nvim — working notes for Claude

A Neovim-based lightweight IDE layer for LazyVim, aiming at full graphical-IDE
parity for the stacks its author actually uses. Personal project under
**gulay.io**. **Not** related to any of the author's client work.

Read `DESIGN.md` for why each module exists, `CHEATSHEET.md` for the keymaps,
`BACKLOG.md` for what is deliberately unfinished.

## How it is loaded

The repo is **not** copied into `~/.config/nvim`. The live config points at the
clone, so edits here apply on the next Neovim start:

```lua
-- ~/.config/nvim/lua/plugins/kebab.lua   (the only file in the user config)
return { { dir = "~/Projects/kebab.nvim", name = "kebab.nvim", import = "kebab.plugins" } }
```

A local `dir` spec, which is what `setup.sh` writes -- no owner/repo, so lazy
never tries to fetch it and the clone is the source of truth. (It used to use
lazy's `dev` mode with an owner/repo; a plain `dir` is simpler and keeps the
handle out of the published docs.)

`import = "kebab.plugins"` makes lazy load every module under
`lua/kebab/plugins/`. Anything added there is picked up automatically.

Keep `~/.config/nvim` otherwise untouched: `theme.lua`, `all-themes.lua` and
`omarchy-theme-hotreload.lua` there are generated and owned by Omarchy.

## Layout

```
lua/kebab/
├── jdk.lua              JDK discovery (no hardcoded paths)
├── explorer.lua         always-on project tree
├── project.lua          :IdeNewProject / :IdeOpenProject / :IdeInitHere
│                        M.create() is the non-interactive half
├── registry.lua         aggregates lua/kebab/languages/* -- the de-hardcoding
├── languages/           ONE FILE PER LANGUAGE. Add a language here, nowhere else
│   ├── java.lua         maven+gradle, spring, codegen kinds, templates
│   ├── javascript.lua   JS *and* TS, vite templates for both
│   ├── python.lua  dart.lua  go.lua  rust.lua
│   ├── kotlin.lua       no markers: Gradle is java.lua's
│   ├── ruby.lua         Gemfile/.ruby-version, bundle add
│   ├── web.lua          svelte/tailwind (frameworks, not a language)
│   ├── data.lua         json/yaml/toml/docker/sql/md/lua/sh + scratch kinds
│   └── generic.lua      .git marker + the empty scaffold; loaded LAST
├── scaffold.lua         run_steps/write_file for language build functions
├── cli.lua              what `bin/kebab` runs
├── deps.lua             :IdeAddDependency; dispatches via the registry
├── maven.lua            pom reading/editing, pure + heavily tested
├── gradle.lua           build.gradle[.kts] editing, both dialects
├── follow.lua           :IdeFollow -- follow edits made outside the editor
├── ghostbar.lua         the animated Ghost Mode panel follow.lua turns on
├── codegen.lua          :IdeGenerate (jdtls source actions, named)
├── templates.lua        :IdeNewFile (package line from the directory)
├── scratch.lua          :IdeScratch (real files under stdpath("data"))
├── projectfiles.lua     :IdeProjectFile (.gitignore/Dockerfile/CI/editorconfig)
├── runconfig.lua        .kebab/run.json, as an overseer template provider
├── jdbc.lua             JDBC drivers from Maven Central + the JVM runner
├── db.lua               connections, table browsing, SQL consoles
├── dbcomplete.lua       SQL completion from JDBC schema introspection
├── lsp.lua              semantic queries (diagnostics/definition/refs/symbols/hover)
├── agent.lua            their CLI contract: rendering, JSON, exit codes
├── git.lua              the hand-rolled revert, testable without a tree window
├── path.lua             expand a path WITHOUT vim.fn.expand's shell expansion
├── jsonfile.lua         pretty-print JSON for a hand-editable file; jq optional
├── run.lua              marker gating for language tasks (overseer provider)
├── menus/
│   ├── action.lua       introspectable menu actions -- build every entry here
│   ├── editor.lua       right-click: Project/File/Edit/Code/Run/Git/View
│   └── tree.lua         right-click in the tree, incl. git + revert
└── plugins/             every file here is a lazy spec, auto-imported
    ├── extras.lua       the 25 LazyVim extras this layer needs
    ├── mason.lua        LSP/DAP/linter bootstrap list
    ├── java.lua         jdtls + Spring Boot tuning
    ├── flutter.lua      flutter-tools (owns dartls)
    ├── python.lua       basedpyright venv autodetect
    ├── git.lua          diffview
    ├── run.lua          overseer run configurations
    ├── ui.lua           neo-tree behaviour + blink signature help
    ├── menu.lua         right-click wiring
    └── project.lua      project keys, dashboard, which-key

java/KebabJdbc.java      the JDBC bridge; single-file source, compiled on use
autoload/db/adapter/jdbc.vim
                         makes :DB/:DBUI/completion speak JDBC
bin/kebab                the shell command; symlink it onto PATH
tests/
├── run.sh               ./tests/run.sh [spec-name-filter]
├── run.lua              boots one Neovim, runs every spec
├── harness.lua          assertions, vim.ui stubs, scratch repos
└── spec/*_spec.lua      one file per area
```

## Rules learned the hard way

**Never open the user's real files in headless Neovim.** A `timeout`-killed
session leaves a swap file in `~/.local/state/nvim/swap/`, and the next time
they open that file they get `E325: ATTENTION / Found a swap file`. This
happened and was reported as "my file is corrupted" — twice, because the first
check only looked at `git diff`, which was clean. Verify against scratch git
repos under the scratchpad directory, or pass `-n` to disable swap entirely.

**Verify behaviour, not loading.** Several bugs shipped because a module
loaded without error and was declared working. "The menu renders" is not "the
menu entries do anything". Always assert on the real effect: file created, LSP
client attached, file contents reverted.

**Specific traps already hit:**

- `require("neo-tree.command")` fails before lazy has loaded the plugin — call
  `require("lazy").load({ plugins = { "neo-tree.nvim" } })` first.
- Two local specs sharing the same `dir` collide; lazy silently drops one. The
  user already has `theme-hotreload` using `dir = stdpath("config")`.
- `lua/config/autocmds.lua` loads on `VeryLazy`, which is *after* the first
  file's `BufReadPost` — too late to catch `nvim some/file.java`.
- neo-tree's `get_state_for_window()` returns nil for any non-tree window, so
  menu actions must refocus the tree window before running a command.
- `gitsigns` resolves its actions through `__index`; `pairs()` shows only
  `setup`/`statuscolumn`, which does not mean the API is missing.
- LazyVim defaults `vim.g.lazyvim_python_lsp` to `pyright`, which *disables*
  basedpyright. `plugins/extras.lua` sets it to `basedpyright`.
- neotest has no Java adapter here; jdtls owns `<leader>tr/tt/tT` in Java
  buffers. Do not wire neotest for Java.
- flutter-tools starts its own `dartls`, so `plugins/flutter.lua` disables the
  lspconfig one. Dart must show exactly **one** client.
- `git checkout HEAD -- <path>` ignores untracked files; revert is implemented
  by hand in `kebab/git.lua` so new files are deleted too, which is what a
  "revert" is expected to do.
- Plugin commands owned by a lazy spec with only `ft` or `event` triggers do
  not exist elsewhere, so a global menu entry pointing at one is dead. This bit
  `AerialToggle` (`event = "LazyFile"`) and all nine Flutter entries
  (`ft = "dart"`). Both now declare `cmd` triggers so lazy stubs them from
  startup.
- `vim.fn.maparg` does not match a special key like `<RightMouse>` when handed
  replaced termcodes. Build the lookup from `nvim_get_keymap` instead, or a
  mapping that is plainly there looks absent.
- `vim.api.nvim_parse_cmd(cmdline, {})` is the authoritative way to ask whether
  an Ex command line is real: it normalises abbreviations (`qa` -> `qall`,
  `%y+` -> `yank`) and errors on anything unknown.
- Trouble refuses to open with an empty list, and filters out unnamed buffers,
  so testing it needs a real file with a real diagnostic.
- A Spring pom has two `<dependencies>` blocks and the one inside
  `<dependencyManagement>` comes first. Anything matching that tag by pattern --
  including an indentation lookup -- gets the wrong one. `maven.lua` scans tags
  and takes the block whose parent is `<project>`.
- jdtls' source action kinds are **dot-separated** (`source.generate.toString`),
  not the camelCase names in the jdt.ls jars. Guessing gave six dead entries.
  Re-derive by asking a live server for `only = { "source" }` with the cursor on
  a class name -- and only *after* the Maven import finishes, because before
  that it offers just organizeImports and overrideMethods.
- `vim.uv.fs_event():start(dir, { recursive = true })` **reports success on
  Linux and then does not recurse.** Use `vim._watch.inotify`.
- Opening a `.http` buffer used to prompt for a paid kulala licence token with
  `inputsecret`, which blocks headless forever. `plugins/rest.lua` leaves
  kulala's LSP backend off unless a token is present. If the suite ever hangs
  with no output, suspect a plugin prompting for input.
- `vim.g` *does* preserve functions in nested tables (luarefs), so a language
  added from a config file can carry a `build` function.
- `<leader>d*` is the **debugger's** entire namespace (da/db/dc/dt/dp/de and a
  dozen more, from the dap.core extra). The database commands are on
  `<leader>D*`. `tests/spec/keymaps_spec.lua` parses LazyVim's core keymaps
  *and* the extras this layer imports and fails on any undeclared override --
  it was added after `<leader>fn` ("New File") was silently displaced.
- vim-dadbod-completion fills its cache from a `FileType sql` autocmd, which
  fires before `b:db` is set. A standalone `.sql` file therefore has no
  completion for the whole session unless something re-runs
  `vim_dadbod_completion#fetch(bufnr)`. `kebab.db.attach` does.
- `mvn dependency:build-classpath` could not resolve its own plugin here even
  with Maven Central reachable. Driver jars are fetched with curl from
  repo1.maven.org instead; do not reintroduce a Maven dependency for it.
- **Do not rewrite the JDBC bridge in Rust.** It was measured: the 180ms per
  query is one-time *per process* (driver class loading, and SQLite extracting
  a native library), not the JVM, which is 18ms. A warm process answers in
  0.2ms -- about 4x faster than even a cold Rust binary at 1.2ms, which would
  still pay its connect each time. A rewrite would also lose H2 (a Java
  database, no Rust driver), need Oracle's native client, and add cargo as a
  build requirement for a feature that already has the JDK. `KebabJdbc serve`
  is the answer; see DESIGN.md.
- The serve protocol is length-prefixed, not sentinel-delimited, because SQL
  contains newlines and any sentinel can appear inside a query. There is a test
  that sends `-- --KEBAB-END--` inside a statement.
- `vim.uv.spawn` **replaces** the environment when `env` is given, so the real
  one has to be rebuilt from `vim.fn.environ()` or the JVM loses PATH and
  JAVA_HOME. And a table holding libuv handles cannot be `vim.deepcopy`d --
  iterate `vim.tbl_keys` instead.
- Specs leak editor state: opening any real file fires the explorer autocmd and
  leaves a neo-tree window, and landing on its buffer makes the next spec's
  `enew!` fail with "Buffer is not 'modifiable'". `tests/run.lua` calls
  `H.reset_editor()` between spec files.
- A Gradle build file's *first* `dependencies { }` is usually `buildscript`'s.
  Match braces, not patterns; `gradle.lua` takes the block at depth 0. And when
  blanking comments before scanning, replace them with spaces -- removing them
  shifts every offset after the first comment.
- **`vim.system` throws ENOENT for a missing executable** rather than returning
  a non-zero code. Check `vim.fn.executable()` first or the caller aborts with
  a stack trace and its `done` callback never fires. `deps.lua` and
  `scaffold.lua` both guard, and borrow `cli.install_hint()` for the message.
- `vim._watch` shells out to the **`inotifywait` binary**, so `:IdeFollow`
  needs inotify-tools installed. It is not a pure-libuv watcher.
- Mason installs 31 of its 55 packages *through* a toolchain (npm 14, golang 9,
  gem 4, pypi 4), so a missing toolchain costs language servers too. This is
  why nothing is bundled -- and why a bundled JDK would be worse still, since
  `jdk.lua` hands jdtls every JDK it finds so each project compiles against its
  own target.
- **Ruby on this machine needs a writable gem home.** The system Ruby's gem dir
  is `/usr/lib/ruby/gems/3.4.0`, owned by root, so `bundle add` updates the
  Gemfile and lockfile and *then* fails with `Bundler::PermissionError`. Verified
  that the layer's path is correct by rerunning with `GEM_HOME` pointed at a
  writable directory: it succeeded. The project-level fix is
  `bundle config set --local path vendor/bundle` -- which the generated Ruby
  `.gitignore` already excludes.
- `gem install --user-install` puts executables in `Gem.user_dir/bin`, which is
  **not on PATH** by default here. bundler was installed that way and symlinked
  into `~/.local/bin` (where `kebab` also lives). `cli.install_hint` now says so.
- The agent queries are **read-only on purpose** -- no rename, format or code
  actions. A test asserts the command list contains nothing that writes. Adding
  a mutating command is a decision, not a tidy-up.
- A **unix socket path is limited to ~108 bytes** and fails to bind *silently*
  past that. `kebab serve` refuses a path over 100 chars; the default is in
  `$XDG_RUNTIME_DIR`. A socket under the test scratch directory does not work.
- **A warm instance (`kebab serve`) holds the Lua it started with.** After
  editing the layer it answers with the old code, which looks like a protocol
  mismatch. Restart it.
- `go get` must NOT be followed by `go mod tidy`: tidy drops any requirement
  nothing imports yet, deleting the dependency just added.
- **`vim.fn.expand()` runs the shell for anything in backticks.**
  `vim.fn.expand("`touch /tmp/pwn`")` creates the file. Any path from an
  argument, a prompt or a `vim.g.*` override goes through `kebab.path.expand`
  (`vim.fs.normalize`, which still does `~` and `$VAR`) instead. `path_spec`
  asserts the payload is live under the old call and inert under the new one.
- A literal NUL in a Lua pattern **truncates a character class**: `"([^\0]*)%z"`
  raises "malformed pattern (missing ']')". Use `%z` on both sides.
- `git status --porcelain` **quotes any path with a non-ASCII byte** and escapes
  it C-style (`"sub/caf\303\251.txt"`). Stripping the quotes is not decoding
  it. Read status with `-z`, which emits raw bytes NUL-separated with no
  quoting; a rename then spends two fields, **new name first**.
- Pass a clicked path to git as a `:(literal)` pathspec, or `*`, `?` and
  `[...]` in a filename are glob metacharacters -- a SvelteKit `routes/[slug]`
  is a pattern, not a directory name.
- `git status` collapses an untracked directory into **one** `?? dir/` entry, so
  counting plan entries understates a recursive delete (2 reported, 31 real).
- A value interpolated into the Lua chunk `bin/kebab` generates must be
  validated as a number, and a table key emitted in **bracket form** -- `local`
  and `2fa` are not identifiers. A chunk that does not compile never reaches
  `qa!`, so headless Neovim **hangs with no output** instead of erroring. Any
  "kebab just sits there" report should be read as a malformed generated chunk.
- Never fold stderr into stdout on a path that can emit `--json`: one LSP
  warning prefixes the payload and makes it unparseable.
- `string.gsub`'s *replacement* treats `%` as an escape, so substituting a user
  path into a template eats characters. Pass a **function** as the replacement.
- `vim.fn.readdir()` on a file, or on a directory it cannot read, returns an
  **empty list** and only echoes E484 -- so "exists and is not empty" quietly
  answers "empty". Check `fs_stat().type` first and `pcall` the readdir.
- Any async entry point must answer **even when it throws**: `project.create`
  wraps `type_def.build` in `pcall` because `done` is how `kebab new --no-open`
  learns the outcome, and an unhandled error there hung headless Neovim forever.
- `vim.islist()`, not `type(x) == "table"`, is the check for a JSON array: an
  object decodes to a table too, so `{"configurations": {...}}` read back as
  zero entries instead of being reported. `kebab.jsonfile.is_array` does both.
- **`generic` must stay last** in the language list -- its `.git` marker matches
  every repository. A language appended by `vim.g.kebab_languages` or
  `registry.register` landed *after* it, so `kind_of()` answered "dir" for the
  very projects that language owned. Both paths now insert before it.
- A warm-process request that **timed out** must not be retried as a one-shot:
  the server may have executed and committed it. Only "nothing was sent" is
  retryable. `jdbc.request` returns that as a third value.
- **lazy.nvim replaces `init`, it does not chain it.** Declaring `init` on the
  neo-tree fragment silently dropped LazyVim's, whose autocmd is what opens the
  tree for `nvim <dir>` -- so a directory argument gave one plain window and no
  explorer, while `nvim <file>` looked fine. `explorer.setup` owns both
  triggers now. The same hazard applies to any `init`/`config` this layer adds
  to a plugin LazyVim already configures.
- **`VimEnter` has not fired while `-c` commands run**, and under `--headless`
  it may never fire -- so a probe `-c`'d into a session sees `v:vim_did_enter`
  as 0. Hook `BufEnter` (which is what LazyVim does here) or both.
- `vim.o.diff` is **false during the first file's BufReadPost**: diff mode is
  turned on afterwards. A guard read at call time always passed, so `nvim -d a
  b` got a tree alongside the diff. Check it inside the `vim.schedule`.
- A Gradle build file cannot be blanked with a **pattern**: the first `//` on
  `maven { url = uri("https://repo.spring.io/milestone") }` is inside a string,
  and blanking from there erased that line's closing brace -- so the brace
  counter never saw depth 0 and `:IdeAddDependency` refused an ordinary file.
  `gradle.blank(text, { strings = })` scans instead; brace counting blanks
  strings too (`ext.closeBrace = "}"` sent the dependency into
  `subprojects { }`), and `has_dependency` keeps them because the coordinates
  live there.
- **`vim.tbl_deep_extend` replaces a list, it does not merge it.** Setting
  `vim.g.kebab_follow.ignored_dirs` un-ignored node_modules, build and .venv,
  and setting `ignored_suffixes` un-ignored `.swp` -- so the follower chased
  Vim's own swap writes. `follow.config` merges the lists and takes
  `replace_ignores = true` for the opt-out.
- A debounce set keyed by path **loses arrival order**: `follow`'s "latest" and
  "first" were both `table.sort` plus an end, i.e. alphabetical -- effectively
  swapping the two modes. `STATE.pending[path]` holds a sequence number now.
- A watcher event can arrive **after `stop()`**: the stop is an asynchronous
  SIGINT and inotifywait's buffered lines still come through. `on_change` and
  `flush` check `STATE.running`, and `stop()` closes the debounce timer even
  when it thinks it is already stopped -- it used to early-return and leak one
  libuv timer per stop-mid-burst.
- **overseer's `condition` understands `filetype`, `dir` and `tags` only.**
  `condition = { callback = fn }` is accepted and then silently ignored, so all
  32 marker-gated language tasks were offered in every project. Marker gating
  goes through a **provider** (`kebab.run.marker_provider`), which is also the
  only way to test the directory being searched rather than Neovim's cwd.
  overseer has **no `priority`** either -- a template carrying one is cargo
  cult, and the test that asserted kebab's own two constants against each other
  could not fail. `register_template` is what validates a definition; the
  validator itself is a local.
- **A driver may compile only the first statement** of a multi-statement
  payload -- SQLite's does -- so `Statement.execute(script)` silently ran one
  insert of two and still reported success. `KebabJdbc.splitStatements` splits
  on unquoted, uncommented semicolons (handling `''`/`""`/backticks, `--`,
  `/* */` and Postgres `$tag$`) and runs each. A fragment of only comments is
  not a statement -- handing one to SQLite raises "the prepared statement has
  been finalized".
- **Which statement failed goes in the exception message, not on stdout**:
  serve mode buffers stdout and discards it when a request fails, so a note
  printed there is lost. The message says "statement 2 of 2 failed (1
  applied)", because the caller has to know how far a script got.
- `System.exit()` inside a printer **kills the warm JVM mid-protocol**: no reply
  frame, the shared connection never closed, every queued request failing. A
  bad argument throws `UsageException`, which `main` maps to exit 2 and `serve`
  turns into one failed request.
- `DatabaseMetaData.getColumns/getTables` take **LIKE patterns**, so `_` in an
  identifier matches any character: `user_data` also returned `userXdata`'s
  columns. Escape with `md.getSearchStringEscape()`.
- `String.length()` is UTF-16 units, not display columns, so a CJK cell skewed
  the result grid. `KebabJdbc.displayWidth` is what `pad` uses.
- **`vim.diagnostic.get()` must be read once, not twice.** Reading it in a
  `vim.wait` predicate and again to build the result is a race: a server
  republishing clears the set and sets it again, and the second read can land
  in the gap -- reporting a file with a compile error as clean *and* settled.
- **The first publish is not the last.** gopls announces what it has early and
  refines it, so stopping at "non-empty" can return a set that does not yet
  hold the compile error. `lsp.stable_diagnostics` waits for the set to stop
  changing for `quiet` ms (500 default) inside the settle budget. Together with
  the double-read above, this was a one-in-three suite flake, and the same bug
  made `--exit-code` a gate that passes whenever the server is cold.
- `--exit-code` has **three** outcomes: 0 clean (and the server said so), 1 an
  error, 2 inconclusive. A gate that cannot tell "clean" from "nothing
  published yet" silently approves everything.
- **Nothing may observe `vim.notify` before `H.install_notify_baseline()`** --
  not even a wrapper that chains through to LazyVim's stand-in. Chaining hits
  the same replay-feeds-itself loop as capture/restore: measured 18s with the
  baseline, still running after 120s with a chained wrapper.
- `handle:kill()` then `handle:close()` in the same tick drops the pid from
  libuv's queue before SIGCHLD, so the child is **never waitpid'd** and stays
  `<defunct>`. Close the handle in the exit callback, which is also the only
  place that can close the pipes of a process that exited on its own.

## House style

**No brand names.** The docs say "a full graphical IDE" and "a dedicated
database IDE", never a vendor's product name. This was asked for explicitly
after a session added several; `~/src` and `~/code` stay
only because they are real paths on this machine.

**No real project names.** This repo is public, so nothing in it names any of
the author's own or client projects -- not in the README, not in CLAUDE.md, not
in a test fixture. Docs describe a project by its *type* ("a Spring Boot
project"); fixtures use obviously synthetic names (`alpha-api`, `alpha-cli`,
`sample-app`, `com.example.*`). This was asked for twice: real names had leaked
into the README, this file and four specs, and renaming them to a shared prefix
still left the original shape visible.

## Tests

`./tests/run.sh` runs everything (`./tests/run.sh project` filters by spec
name). 336 assertions, under 5 seconds. It boots **one** headless Neovim from
the real user config and runs every spec in process, because the bugs this
layer has are integration bugs -- a command belonging to an unloaded plugin, a
global not set yet -- and plenary's busted runner would hide them behind its
minimal init.

Add a spec as `tests/spec/<name>_spec.lua`; it is called with the harness as
its only argument. `H.with_ui({...})` scripts `vim.ui.select`/`input` so the
wizards can run headless, `H.git_repo()` builds a scratch repo with a HEAD
commit, and `H.capture_notify()` collects notifications -- most of this layer
reports failure by notifying rather than erroring, so asserting on the
notification is how you tell "it worked" from "it quietly gave up".

**Both menus are swept.** Every leaf entry is checked against its real target.
This only works because actions are built through `menus/action.lua`, which
records what each one points at -- a bare `cmd = function() ... end` fails the
sweep on purpose. Use `A.custom(label, fn, check)` when the logic really is
bespoke; the `check` is mandatory.

**Traps the harness had to work around.** Both are load-bearing; do not undo
them:

- `VeryLazy` fires off `UIEnter`, which never happens under `--headless`, so
  most of LazyVim's own keymaps are never set. `tests/run.lua` fires it by
  hand; without that, "is this shortcut mapped?" answers no for keys that
  plainly work.
- `LazyVim.lazy_notify()` installs a queueing stand-in as `vim.notify` and
  swaps the original back only when something *else* replaces it. So capturing
  `vim.notify` and restoring it reinstalls the stand-in, and LazyVim's
  `replay()` feeds the queue through itself, re-queueing every message until
  Lua raises `table overflow` and the run dies with SIGTERM. The harness pins
  `vim.notify` to its own baseline before any spec runs. This was the whole
  difference between a 1m46s suite and a 1.8s one.

## Verification recipes

```bash
# clean start (no swap file created)
nvim -n --headless -c "qa"

# which LSP clients attach to a file
cd <project> && nvim -n --headless <file> \
  -c 'lua vim.wait(90000, function() return #vim.lsp.get_clients({bufnr=0})>0 end, 500)' \
  -c 'lua vim.wait(20000, function() return false end, 500)' \
  -c 'lua local n={} for _,c in ipairs(vim.lsp.get_clients({bufnr=0})) do n[#n+1]=c.name end print(table.concat(n,","))' \
  -c "qa"
```

Expected, as of the last full run:

| Project | File | Clients |
|---|---|---|
| a Spring Boot project | its `*Application.java` | `jdtls,spring-boot` |
| a Flutter project | `lib/main.dart` | `dartls` (exactly one) |
| a Python project | `conf/setup.py` | `basedpyright,ruff` |
| a SvelteKit project | `+layout.svelte` | `svelte,tailwindcss` |
| a scratch `go` project | `main.go` | `gopls` |
| a scratch `rust` project | `src/main.rs` | `rust-analyzer` |

The tree auto-opens in all of them: `neo-tree` at column 0, the file at 33.

Go and Rust are installed through mise (`go@1.27.2`, `rust@1.99.0`, both in
`~/.config/mise/config.toml`), reached via `~/.local/share/mise/shims`. Scaffold
a throwaway project with `kebab new x --type go --dir <scratch>/x --no-open`
rather than opening one of the author's own.

Adding a dependency is verified end to end for every ecosystem: `go get` writes
the `require` line, `cargo add` writes the `[dependencies]` entry, and the Maven
path rewrites `pom.xml`. **`go get` must not be followed by `go mod tidy`** --
tidy removes any requirement nothing imports yet, so it deletes the dependency
just added. That was shipped and caught only by running it for real; the unit
test had encoded the wrong assumption.

## The author

Comes from a full graphical IDE background and is still learning modal
editing — explain Neovim idioms plainly rather than assuming them, but do not
lecture. Wants work finished and verified, not handed back with caveats. Stacks
are Spring Boot (Java 21, Maven), Flutter, Python/PySpark, SvelteKit.
