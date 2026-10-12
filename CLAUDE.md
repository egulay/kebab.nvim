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
├── jdk.lua              JDK discovery (no hardcoded paths; vim.g.kebab_jdk_roots)
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
├── gitwatch.lua         notice commits/pushes made outside the editor
├── codegen.lua          :IdeGenerate (jdtls source actions, named)
├── templates.lua        :IdeNewFile (package line from the directory)
├── scratch.lua          :IdeScratch (real files under stdpath("data"))
├── projectfiles.lua     :IdeProjectFile (.gitignore/Dockerfile/CI/editorconfig)
├── runconfig.lua        .kebab/run.json, as an overseer template provider
├── jdbc.lua             JDBC drivers from Maven Central + the JVM runner
├── db.lua               connections, table browsing, SQL consoles
├── dbide.lua            the three panes: tree | statement / rows
├── dbcomplete.lua       SQL completion from JDBC schema introspection
├── lsp.lua              semantic queries (diagnostics/definition/refs/symbols/hover)
├── agent.lua            their CLI contract: rendering, JSON, exit codes
├── git.lua              the hand-rolled revert, testable without a tree window
├── path.lua             expand a path WITHOUT vim.fn.expand's shell expansion
├── jsonfile.lua         pretty-print JSON for a hand-editable file; jq optional
├── fs.lua               write/read a file that REPORTS instead of raising E482
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
├── spec/*_spec.lua      one file per area
└── pty/run.sh           mouse tests; a real terminal, NOT in run.sh
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
- A template's **package line comes from where the file lands**, not from the
  directory the picker was pointed at: a name carrying a subdirectory
  (`sub/Widget`) goes to `com/foo/sub`, and `package com.foo` does not compile
  there. `ctx.dir` is the landing directory and `ctx.target_dir` the other one;
  `languages/go.lua` reads `ctx.dir` for the same reason. Verified with javac
  and `go build`.
- **`vim.fn.writefile` raises E482, and `mkdir` raises E739** -- neither
  returns a code. Every write goes through `kebab.fs.write_lines`, which
  reports instead, because a build function that throws never calls its `done`
  and a dependency gets reported as added when the file was never written.
  Do not add a `vim.fn.mkdir` beside it; `write_lines` does that part safely.
- **Reverting a rename is restore-the-old plus remove-the-new.** The porcelain
  `-z` record gives the new name first, then the old, and `git checkout HEAD --
  <new>` can never work -- HEAD has never heard of it. Deleting the file is not
  enough either: the new name is a staged addition, so `git rm -f` is what
  clears the index entry too. `plan.renamed` carries the pairs.
- A **JDBC URL can carry inline credentials**, and argv is in the process list,
  so `KebabJdbc` takes `-` as the url argument and reads `KEBAB_DB_URL` from
  the environment. `jdbc.spawn_env` is what every spawn path passes.
- A malformed frame in the serve loop **cannot be answered and recovered from**:
  the payload bytes it declared are still in the stream, so the next read takes
  them as a header. The loop closes the connection instead.
- `vim.schedule` **defers onto the main loop, it does not move work off it**, so
  the "off the main loop" schema fetch still blocks. It is bounded at 15s
  (`vim.g.kebab_db_schema_timeout`) and the failure is cached, so an
  unreachable host costs that once per cooldown rather than 120s per keystroke.
- An LSP `character` offset is in the **server's offset encoding**, not bytes.
  Every server here negotiates utf-16, so `character + 1` was wrong on any line
  with non-ASCII before the symbol -- and it disagreed with `diagnostics`,
  whose columns come from `vim.diagnostic` and are byte-based. `lsp.lua`
  converts with `vim.str_byteindex`, so one tool answers in one coordinate
  system and its own output can be fed back in.
- **`client:request` returns a boolean.** A client whose RPC channel has closed
  is still returned by `get_clients` -- client objects leave `lsp.client._all`
  only after two nested `vim.schedule`s -- and `request` then returns false
  without ever calling the handler. Ignoring it left the pending counter stuck,
  so every query burned its full 20s timeout and blamed the server. Measured
  after the fix: 3ms and "gopls rejected the request".
- `position_params` must be built **per client**: a buffer commonly has two
  clients with different encodings (basedpyright utf-16, ruff utf-8 on every
  Python file here), and `get_clients(...)[1]` is not reliably the lowest id.
- `M.open` loads a buffer, and `kebab serve` is long-lived: a query per file
  meant a buffer and a didOpen'd document per file, for good. `lsp.release`
  unloads what the module itself loaded -- stepping off it first, because
  `:edit` puts it in the current window so a "is it visible?" guard would
  refuse every time. Measured bounded at +2 over 20 queries, was +1 each.
- A **warm process is keyed by URL, but credentials are baked in at spawn**.
  Two saved connections can share a URL and differ only in user -- the URL
  templates carry host, port and database only -- so a "readonly" connection
  reused a daemon started as "admin" and ran as admin, silently, while the
  one-shot path behaved correctly. `request` compares a hash of the current
  credentials against the daemon's and restarts it on a mismatch;
  `jdbc.daemon_pid` exists so a test can tell reuse from restart.
- A **driver jar goes onto a classpath that `java` executes**, so it is checked
  against the `.sha1` Maven Central publishes beside it -- one extra GET.
  `vim.g.kebab_jdbc_require_checksum` makes it strict; by default a missing
  checksum or sha1sum does not block working offline. curl also passes
  `--proto =https --proto-redir =https`, or an https -> http redirect is
  followed in the clear.
- The version string from `maven-metadata.xml` **becomes part of a filesystem
  path**, so `<release>../../../x</release>` was a write-outside-the-cache
  primitive. `jdbc.is_version` gates it.
- `templates.path_for` must **contain** the result: a name like
  `../../../../outside/Pwned` wrote the file outside the project and reported
  success, with an un-normalised path and a nonsense package line. A
  subdirectory is still allowed; an absolute name is refused.
- `vim.system` throws for a **missing `cwd`** as well as a missing executable,
  and from step two onward `run_steps` was inside a `vim.schedule` where the
  throw is swallowed -- so `done` was never called and `kebab new --no-open`
  waited fifteen minutes over a half-built tree. Both are checked, and the
  spawn is wrapped.
- **`vim.wait` pumps `vim.schedule` callbacks**, so a second `jdbc.run` on the
  same URL used to start *inside* the first one's wait. The per-URL process is
  a single slot and whichever request timed out first called `shutdown(url)`,
  killing the JVM mid-statement and failing the other. `request` holds a
  `busy` flag per daemon and hands a concurrent caller back to the one-shot
  path, where nothing is shared.
- A path given to `kebab --server` must be made **absolute by the caller**: the
  warm instance resolves a relative one against its own cwd, so the same query
  answered about a different project's `src/Foo.java`. `bin/kebab`'s
  `absolute_query_arg` does it, keeping any `:line:col` suffix and passing a
  non-existent path through unchanged.
- In bash, `local a=$1 b=$a` does **not** see `a` -- `b` comes out empty. One
  `local` per variable.
- JDT's execution environments are **`JavaSE-1.8` and below for 8 and below**,
  `JavaSE-9` and up after that. `JavaSE-8` is rejected with "Invalid runtime for
  JavaSE-8" and the entry dropped -- so a Java 8 project was analysed against
  whatever JVM jdtls itself runs on. `jdk.ee_name` owns the spelling.
- A macOS bundle JDK is `<x>.jdk/Contents/Home`, so its **basename is "Home"**
  and a version read from the basename found nothing. Walking up the path
  blindly is not the fix either -- it reads a version out of an unrelated
  ancestor directory (a scratch path gave `JavaSE-1.4`). Match the bundle
  component specifically, then fall back to the JDK's own `release` file, which
  every layout has.
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
- **Autostart must refuse while the editor is exiting.** It is scheduled, so in
  a short-lived session -- `nvim -c qa`, or the editor `git commit` opens -- it
  lands at or after `VimLeavePre` and the watcher it starts is never stopped.
  Measured: one orphaned `inotifywait` per invocation, which for `git commit`
  is one per commit. Guarded by a `shutting_down` flag set on
  VimLeavePre/VimLeave/QuitPre *before* the stop, and by `vim.v.exiting`. It
  also skips a `gitcommit`/`gitrebase`/`help`/`man` buffer, which is not a
  session worth following.
- **A held change must not be discarded.** `flush` used to throw its pending
  set away whenever `yielding()` said the user was busy, so an agent's whole
  burst went unseen while you had unsaved changes -- and the next change after
  you went idle looked like the only thing that happened. Measured: 7 files
  written, 0 shown. It holds them now (stale after `hold_ms`, 30s), retries
  every `retry_ms` until you are free, and the **badge reports each file
  immediately** whether or not the view is about to move.
- **Two of neo-tree's nine default git markers are plain Unicode dingbats** --
  `added = "✚"` (U+271A) and `deleted = "✖"` (U+2716) -- and a Nerd Font does
  not carry those. the monospace Nerd Font has every other symbol it uses and
  neither of these, so a file an agent had just *added* rendered as a tofu box.
  `plugins/ui.lua` overrides both with nf-fa glyphs. `menu_tree_spec` asserts
  every configured symbol is ASCII or in a Nerd Font private-use range, and
  asks `fc-list` whether the installed font really has it.
- `utf8.codes` does not exist in LuaJIT. `vim.fn.str2list(s)` gives codepoints.
- **Nothing sees a commit or a push without `gitwatch.lua`.** `follow.lua`
  excludes `.git` from its watch on purpose, and a *push* changes no file at
  all -- only `.git/refs/remotes/...` -- so no working-tree watcher could ever
  notice it. `gitwatch` watches `.git` itself and only re-reads state: gitsigns
  `refresh()`, neo-tree's `GIT_EVENT` **and** a filesystem-source refresh
  (the event alone leaves a partial update), and `redrawstatus!`. It never
  moves the cursor. `:IdeGitRefresh` does it by hand;
  `vim.g.kebab_git_watch = false` turns it off. Measured: one coalesced refresh
  from an external commit, and one from an external push.
- A worktree's or submodule's `.git` is a **file** holding `gitdir: <path>`,
  which may be relative. `gitwatch.git_dir` resolves both.
- **The badge is an activity light, not a status light.** It appears from
  `ghostbar.activity()` -- i.e. because something touched the project -- and
  hides itself after `idle_ms` (5s) of quiet. `follow.start()` must NOT show
  it: a badge that sits there whenever watching is armed says nothing about
  whether an agent is doing anything, which is the only question it answers.
  This was built the wrong way round first and reported as "it says ghost mode
  but none of the agent touches that project".
- **Ghost Mode ships ON**: `kebab_follow_autostart` defaults to on and
  `open_new` to true, because needing a keypress is how the feature ends up
  looking dead. `= false` turns each off. `tests/run.lua` pins autostart off
  for the suite, since a live watcher would move buffers under the specs.
  `open_new = true` does not mean 40 buffers for 40 files: a burst is coalesced
  and only the chosen file of each flush is opened.
- **`vim.g.kebab_follow_autostart` is read in the callback, never at setup
  time.** `follow.setup()` is called from another spec's `init` and lazy does
  not order `init` functions, so deciding early meant the autocmd was simply
  never registered whenever that init ran first -- the feature looked dead.
- Autostart must latch, both ways: once per tree (`BufEnter` fires constantly,
  and one session otherwise accumulated eight watchers on one directory) and
  **a stop the user asked for has to stick**, or the next buffer switch starts
  it again and `<leader>uf` cannot turn it off. `follow.allow_autostart()`
  clears both, and `DirChanged` calls it because a new project is a fresh
  decision.
- A watcher only ever sees **its own tree**, so following the project you have
  open cannot show an agent working elsewhere. `vim.g.kebab_follow_roots` names
  extra trees; do not default it to a large directory, because
  `vim._watch.inotify` places a watch per subdirectory.
- `H.it` stops the follower after **every** test. A test that errors before its
  own `stop()` leaves an inotifywait running whose callbacks move the next
  test's buffers. Note the residue that remains: a *full* suite run still ends
  with a handful of watchers on the test sandbox, which `follow` or `ghostbar`
  alone do not leave -- the stop callbacks run but do not kill under a loaded
  event loop. A real session is clean: start, work, `:qa` leaves none.
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
- Project discovery scans **two levels**, so three guards are load-bearing: a
  directory that is itself a project is recorded and not descended into, the
  `SKIP_DIRS` list (`node_modules`, `target`, `build`, ...) is never walked,
  and `scan_limit` caps the whole scan. Remove any one and opening the picker
  walks a vendored dependency tree. A hidden directory can *be* a project
  (`~/Projects/.dotfiles`) but is never walked through to reach one.
- `project.discover()` returns **`projects, problems`**. Two consequences: a
  bare `if fd then` around a scandir is how the silent skip got shipped -- an
  unreadable root looked like an empty one -- and `H.eq(x, project.discover())`
  now passes the problems table as the *message* argument, so wrap the call in
  parens when only the first value is wanted.
- A missing **default** root is not a problem: the defaults name
  `~/src` and friends, which most machines lack. Only a root the user
  named in `vim.g.kebab_project_roots` or `$KEBAB_PROJECT_ROOTS` is reported
  missing; an unreadable directory is always reported.
- `kebab db` runs `nvim -c DBUI` **from a cold start**, so the dadbod-ui spec
  needs `cmd` triggers -- it had only `keys`, and a command owned by a
  keys-only spec does not exist until the key is pressed. Same trap as
  `AerialToggle` and the Flutter entries, third time. A spec asserts
  `exists(":DBUI") == 2`.
- **Nothing can add to the editor's environment after Neovim has started**, so
  the env file for a connection's `password_env` is sourced by `bin/kebab`
  before it execs the editor (`--env`, or `$KEBAB_DB_ENV`). Doing it in Lua
  would be too late. An unreadable env file is a hard error: starting anyway
  opens the IDE with every connection failing to authenticate, which reads as
  a broken database rather than a typo.
- **A headless Neovim has no screen grid, so it cannot be clicked.**
  `nvim_input_mouse()` is dropped and `feedkeys("<2-LeftMouse>")` does nothing,
  both silently -- so a mouse test written headlessly passes by doing nothing.
  "The double click works" was claimed twice on the strength of a registered
  mapping, and the mapping was there and the click did nothing both times. Use
  `tests/pty/run.sh`: a real editor under a pty (`#nvim_list_uis() == 1`) fed
  the SGR mouse reports a terminal sends. It is not in `./tests/run.sh`
  because each case boots an editor.
- **dadbod-ui has no mouse support at all** -- `<CR>`, `o`, `A`, `H`, `J`, `K`,
  `R`, `S`, `d`, `q`, `r` and nothing else -- and its action on a table
  expands it into a "List" child rather than opening it. `plugins/sql.lua` maps
  `<2-LeftMouse>` to `kebab.dbide.click`, which feeds `<LeftMouse>` first (that
  is what moves the cursor to the clicked line) and then opens a table in the
  three panes, falling through to `<Plug>(DBUI_SelectLine)` for anything else.
- SQL consoles and statement panes are **real files**, so `vim.g.kebab_db_sql_dir`
  exists and `tests/run.lua` pins it: a run left twenty `beta-*.sql` in the
  user's own data directory, and one of them made the editor ask whether to
  save it -- a prompt nothing can answer under `--headless`.
- **dadbod strips a leading `jdbc:` from any url** (`substitute(url, '^jdbc:',
  '', '')` in its own `s:resolve`) and dispatches on what is left, because it
  accepts JDBC-shaped urls for its *native* adapters. So `b:db` and
  `vim.g.dbs` holding `jdbc:postgresql://...` sent `:DB`, `<leader>S`,
  dadbod-completion and the whole explorer tree to **psql** -- this layer's
  runner was never called by any of them. It looked like it worked because
  psql and sqlite3 are installed here. The scheme is `kjdbc:` + the whole JDBC
  url now (`autoload/db/adapter/kjdbc.vim`); `jdbc.dadbod_url` / `plain_url`
  convert. The test that catches it must **resolve then dispatch** -- dispatch
  alone passes on a bare `jdbc:` url, since only the resolver strips it.
- The explorer reported **`Tables (0)` for a database with 48** for two more
  reasons, both worth knowing: `db#connect` proves a connection by running the
  adapter's command with `auth_input` on stdin and treating a non-zero exit as
  failure -- for a client that reads SQL on stdin that probe is a query of one
  newline, which the runner correctly refuses, so `db#adapter#kjdbc#auth_input`
  returns `v:false` (dadbod's own opt-out). And `db_ui#drawer#populate_tables`
  **returns before asking the adapter** when dadbod could not connect, so a
  connection failure and an empty database look identical. `vim_tables` raises
  rather than returning `{}` for that reason.
- **Two entries with the same name in a `uv.spawn` env array: glibc's `getenv`
  returns the first.** The warm process copied `vim.fn.environ()` and then
  appended its own `KEBAB_DB_URL`, and `vim_command` has to leave that name in
  Neovim's environment (dadbod spawns the argv itself) -- so after one `:DB`,
  every warm process connected to *that* database whatever url it was asked
  for. Merge into a table and flatten once.
- **A legacy timezone alias breaks every JDBC connection.** systemd accepts
  `timedatectl set-timezone Turkey`, the JVM reports that name verbatim in the
  PostgreSQL startup packet, and a server whose tzdata lacks the
  backward-compatibility links answers `FATAL: invalid value for parameter
  "TimeZone"`. The message names neither the JVM nor the machine, so it reads
  as a database fault. `vim.g.kebab_jdbc_timezone` passes a canonical name
  (`-Duser.timezone`, which must come before `-cp`), and `jdbc.hint` appends
  the fix to that error. Not defaulted: canonicalising an alias needs the
  alias table, and a wrong guess moves every timestamp the server renders.
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

**A spec must never assert a default it did not pin.** The suite boots the real
user config on purpose, so any `vim.g.kebab_*` the author sets is live during
the run -- and a spec reading the ambient value fails for a setting that is
perfectly legitimate. This bit three specs the moment
`vim.g.kebab_follow = { open_new = true }` went into the live config. Set the
global inside the test (there is a `with_config` helper in `follow_spec`), and
assert the shipped default only with the global explicitly cleared. Check with:

```bash
nvim -n --headless --cmd "set runtimepath+=$PWD" \
  --cmd 'lua vim.g.kebab_db_preview_limit = 5' \
  -c "luafile $PWD/tests/run.lua"
```

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
`nvim <dir>` opens it too, which is a separate code path -- see the `init` trap
above.

**Reproduce it without opening a real project.** Scaffold throwaway ones and
check those instead; this is how the table above was last confirmed:

```bash
kebab new vgo    --type go    --dir <scratch>/vgo   --module example.com/vgo --no-open
kebab new vrust  --type rust  --dir <scratch>/vrust --no-open
kebab new vmaven --type maven --dir <scratch>/vmaven --group com.example --no-open
```

Last full run: `jdtls,spring-boot` on the Maven project, `gopls`, and
`rust-analyzer`, each with `neo-tree@0` and the file at column 33.

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
