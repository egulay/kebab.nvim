# Backlog

Ordered by how much friction it removes day to day.

## Helpers (all built)

1. ~~**Add dependency**~~ Done: `:IdeAddDependency` / `Space → p → d` / Project
   menu. Maven coordinates are written into `pom.xml` — version omitted when
   the spring-boot parent or `dependencyManagement` already manages it, and
   refused outright when nothing does, rather than writing a pom that will not
   build. A bare name expands to a Spring starter, so `data-jpa` means
   `org.springframework.boot:spring-boot-starter-data-jpa`. Flutter, Node and
   Python delegate to `flutter pub add`, `npm install` and `uv add`. Gradle is
   still unsupported and says so.
2. ~~**Java code generation**~~ Done: `:IdeGenerate` / `Space → c → g` / Code ›
   Generate. Named entries for constructor, getters and setters, `toString`,
   `equals`/`hashCode`, override, delegate methods and organize imports. The
   action kinds are dot-separated (`source.generate.toString`), **not** the
   camelCase names in the jdt.ls jars -- guessing from those gave six dead
   entries, so the list was read back off a live server. See
   `languages/java.lua` for how to re-derive it.
3. ~~**File templates**~~ Done: `:IdeNewFile` / `Space → f → n`. 20 templates
   across Java, Python, Go, Rust, JS/TS and Svelte. The Java ones fill the
   package line in from the directory, and the JUnit template redirects itself
   to `src/test/java` with the same package, named after the file you were on.
4. ~~**Scratch files**~~ Done: `:IdeScratch` / `Space → f → S`, with
   `:IdeScratchList` / `Space → f → s` to reopen one. 13 kinds including `.http`
   and `.sql`. They are real numbered files under `stdpath("data")`, so a
   language server attaches and they survive a restart -- and they can never be
   committed by accident.
5. ~~**Project generators**~~ Done: `:IdeProjectFile` / `Space → p → f`. A
   `.gitignore`, Dockerfile and CI workflow per language, plus `.editorconfig`
   and `README.md` everywhere. Only the ones that suit the project in hand are
   offered, and an existing file is never replaced without asking.
6. ~~**Per-project run configurations**~~ Done: `.kebab/run.json` at the
   project root, with name, cmd, args, env and cwd, committed with the project.
   Exposed to overseer as a template *provider*, so they appear in
   `Space → o → o` above the generic language tasks and are re-read on every
   search -- editing the file needs no restart. `:IdeRunConfigEdit` /
   `Space → o → e` creates it with an example that suits the project;
   `:IdeRunConfig` / `Space → o → r` runs one.

## Ghost programming (built)

`:IdeFollow` / `Space → u → f` / View › Follow External Edits. **On by default**; the keymap turns it off.

When a file changes on disk, the view moves to it and the cursor to the first
changed line, which is briefly highlighted. Watching is via `vim._watch`'s
inotify backend over the project root.

What it refuses to do, which is most of the design:

- **It never reloads over your own edits.** A buffer that is modified *and*
  changed on disk is a conflict; it says so and leaves both alone.
- **It yields to you**: insert mode, a visual selection, the command line, an
  open completion menu or picker, a terminal or prompt buffer, or any unsaved
  buffer. A dropped jump is better than a stolen cursor.
- **It does not open new files** unless asked (`open_new`), because an agent
  writing forty files should not open forty buffers.
- Events are coalesced over 250ms and the latest wins, so a large refactor is
  watchable rather than a slideshow. `follow = "first"` stays put instead.
- Build output is ignored by whole path segment -- `target/`, `node_modules/`,
  `build/`, `.venv/` and the rest -- so a Maven build does not drown the
  signal. A directory called `build-tools` is *not* ignored.

Configure with `vim.g.kebab_follow = { debounce_ms = 250, follow = "latest",
open_new = true }`. `vim.g.kebab_follow_autostart = false` stops it starting
itself, and `vim.g.kebab_follow_roots` names other projects to watch -- a
watcher only ever sees its own tree, so an agent working in a repo you do not
have open needs naming.

Still missing: the highlight marks the first changed line, not the whole
changed region, and there is no history of what was followed. It also cannot
tell an agent's write from your own save in another editor, a `git checkout` or
a formatter -- which on reflection is the feature rather than a flaw.

## Known weak spots

- ~~**The editor menu is under-tested.**~~ Done. Both menus are swept by
  `tests/run.sh`: every leaf entry is checked against its real target, and the
  entries with an observable effect are run and asserted on. The sweep found
  and fixed three dead entries — a cheatsheet path that never existed, Aerial
  unreachable before a file was opened, and the whole Flutter submenu dead
  outside a Dart buffer — plus the Java test entries running neotest, which has
  no Java adapter. Menu actions are now built through `menus/action.lua`, which
  records what each one targets; an opaque closure fails the sweep by design.
- **`nvzone/menu` is NvChad-oriented.** It works, but it is the least solid
  dependency here. The bundled `menus/neo-tree.lua` it ships is unused because
  it has no git actions and depends on NvChad-only modules.
- ~~**A dedicated database IDE has no real replacement.**~~ Largely done, over
  JDBC with drivers fetched from Maven Central, the way a dedicated database IDE
  does it. See
  `jdbc.lua`, `db.lua`, `dbcomplete.lua` and `autoload/db/adapter/jdbc.vim`.
  Nine databases registered; a database needs no native client installed, only
  a JDK.

  Queries run on a warm process per connection: 180ms for the first, 0.2ms
  thereafter. Replacing the bridge with Rust was measured and rejected -- see
  DESIGN.md; a warm JVM is about 4x faster than a cold Rust binary, because the
  cost was never the language.

  What is still missing against a dedicated database IDE: no editable data grid
  (results are read-only text), no visual query plan, no schema diff or
  migration generation, and no transaction control -- the first and the last
  by decision, not omission. Completion covers tables, `table.column`, aliases
  and types; it does not know about functions, CTEs or subquery scopes.

  ~~SQL Server and Oracle are written and never executed.~~ Done, and then
  the rest of them: `tests/db/servers.sh` covers **eight of the nine
  registered drivers** -- H2, DuckDB and SQLite need no server at all, and
  PostgreSQL, MySQL, MariaDB, SQL Server and Oracle run in containers. 22
  checks each, from the driver jar to the warm process.

  Three bugs that SQLite and PostgreSQL could not show, one per round:
  the tree listing the server's own catalog (589 `sys` tables on SQL Server,
  2049 on Oracle), a structure panel that came back empty for a table name
  typed in the wrong case, and -- found only once MySQL was added -- 100 `sys`
  views returned *unqualified*, because MySQL keeps its internals in a catalog
  rather than a schema and the filter was looking at the wrong field.

  ClickHouse is checked too, and it was the most expensive one: its shaded
  driver jar does not bundle slf4j, so both driver classes failed to
  initialise and the JDBC service loader swallowed it ("No suitable driver for
  this URL. Drivers on the classpath: (none)" -- which reads as a URL
  problem); the shaded jar needs a Maven *classifier*, which coordinates could
  not express; and against a current server the driver's default compression
  fails every query with "Invalid LZ4 magic byte", so the URL template carries
  `compress=0`. Two of its checks are skipped by name with the reason printed:
  no foreign keys, and a data skipping index that JDBC does not report as an
  index.

  All nine registered drivers are checked now. What is still unexercised is
  *versions*: one server version each, the newest at the time.
- ~~**Startup time has never been measured.**~~ Measured: **21.8 ms** median
  with the full layer against **3.4 ms** for bare `nvim -u NONE`, so the layer
  costs about 18 ms despite 80-odd plugins -- lazy loading is doing its job.
  Seven runs each, median of `--- NVIM STARTED ---` from `--startuptime`.
  Caveat: headless, so UI initialisation is not included; a real start is
  higher. Re-measure with:

  ```bash
  nvim -n --headless --startuptime /tmp/st.txt -c qa && grep "NVIM STARTED" /tmp/st.txt
  ```

- ~~**Gradle dependencies are not supported.**~~ Done: `kebab/gradle.lua`
  edits `build.gradle.kts` and `build.gradle`, in the right dialect for each,
  omitting the version when the Spring Boot plugin manages it. The block is
  found by brace matching rather than a pattern, so `buildscript { }` and
  `subprojects { }` are not mistaken for the project's own.

- ~~**The LSP and gitsigns shortcuts the menu advertises are not covered.**~~
  Done. `menu_shortcuts_spec` now opens a real tracked file for the
  `Space → g → h → *` keys and a real Go module for `gd`/`gI`/`gr`/`Space → c → a`/
  `Space → c → r`, and asserts each is bound *in that buffer* once gitsigns or the
  language server has attached. The BUFFER_LOCAL list still asserts they are
  not global; this asserts they exist where they are supposed to.

- **`nvzone/menu` is still the weakest dependency.** See above. If it ever goes
  unmaintained, `menus/action.lua` is the seam: every entry is already a
  described action, so a different renderer is a rewrite of the renderer only.

## The code review

A full review of the layer was run and its findings worked through: 138
distinct findings, of which every one at **high** severity and every one upheld
by the verification pass is fixed, down to the medium and low ones and the
false tests among them. The suite went from 887 assertions to 1051.

What it found, in one line each, is in the git log. The categories worth
remembering are kept with the working notes beside this repo, not in it —
they are the traps, not the fixes.

Three things it surfaced that are worth keeping in mind for any new code here:

- **A false test is worse than no test.** Several assertions could not fail:
  one compared kebab's own two constants, one iterated a list that was always
  empty, one filtered the keys it checked so narrowly that every broken one was
  excluded. Each hid a real bug.
- **Verify against the real tool.** A generated `.gitignore`, a package clause,
  a Dockerfile, a pom — all rendered fine and were rejected by git, javac, go,
  docker and Maven respectively. `git check-ignore`, `javac`, `go build` and
  `mvn validate` are cheap.
- **The warm paths have their own bugs.** `kebab serve` and the warm JDBC
  process were where the credential mix-up, the double execution, the buffer
  leak and the relative-path confusion lived, because nothing else runs long
  enough to notice.

## Packaging

- **One command installs it**: `install.sh` clones the layer if it has to,
  clones the LazyVim starter when there is no Neovim config, runs `setup.sh`,
  installs the plugins and prints what is missing. Verified on a container
  with none of this machine on it (`tests/ci/docker.sh`), which is also what
  found the explorer that was never installed and the version floor that was
  wrong.
- **CI exists**: `.github/workflows/ci.yml` runs the clean-machine install and
  the suite on the floor (0.12) and on stable, twice, so an install that is
  not idempotent fails too.
- Still one machine, one terminal, one font for everything the pty suite
  covers: the mouse paths are verified on this terminal only.
- Decide whether this ships as a plain LazyVim plugin (works for anyone) or
  also as an Omarchy integration. An *Omarchy plugin* is a Quickshell/bar
  artifact, which this is not — at most it would be an install script plus
  theme awareness.

  If that is the direction, the pieces that already exist are `setup.sh` (the
  install script), `kebab doctor` (which reports what a machine is missing and
  exits non-zero only on required things, so it suits a post-install check),
  and `bin/kebab` (a real CLI entry point, which is what a desktop launcher or
  a bar action would call). What does not exist is theme awareness: the layer
  reads whatever colorscheme the config sets and has no hook into Omarchy's
  theme switching, and `~/.config/nvim/theme.lua` is Omarchy-owned and
  deliberately untouched — so that is the one piece of new integration work.
