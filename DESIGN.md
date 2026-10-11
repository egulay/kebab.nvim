# Design notes

Why each module exists and what it had to work around. Written so a future
session can change things without rediscovering the same traps.

## Starting point

The author had a stock Omarchy LazyVim install with exactly **one** extra
enabled (`editor.neo-tree`). No language support, no debugger, no test runner —
so a full graphical IDE was being compared against a syntax-highlighting text
editor. Most
of the perceived gap was unconfigured, not missing.

## `plugins/extras.lua`

The 25 LazyVim extras the layer needs, declared as `{ import = ... }` specs
rather than in the user's `lazyvim.json`.

This matters: `lazyvim.json` is a *user* file. If the extras lived there,
installing this layer would do nothing until the user also hand-edited their
own config. Declaring them here makes the layer self-contained.

`vim.g.lazyvim_check_order = false` is set here too. LazyVim warns that the
import order is wrong because the last extra is imported after a module called
`plugins`, which is true: the user's own `lua/plugins` is module 5 and these
extras arrive at 7+, since this layer imports them itself instead of making the
user list 25 of them. What the check protects still holds — lazy imports a
directory in sorted order, so `extras.lua` is processed before `flutter.lua`,
`java.lua`, `python.lua` and `ui.lua`, and their opts merge on top.
`tests/spec/config_spec.lua` asserts that rather than trusting this paragraph.

Order is deliberate. LazyVim gives `dap.core`, `test.core` and
`lang.typescript` a higher load priority than the rest (`lazyvim/plugins/
xtras.lua`), so they are imported first.

`vim.g.lazyvim_python_lsp` is set here, at module body level, because LazyVim
reads it when the Python extra's spec is evaluated — which happens after this
module is required.

## `registry.lua` + `languages/`

Every fact about a stack used to live in whichever file happened to need it:
the project types in `project.lua`, the Mason packages in
`plugins/mason.lua`, the LazyVim extras in `plugins/extras.lua`, the run
configurations in `plugins/run.lua`, the dependency command in `deps.lua`.
Adding Go meant editing five files and remembering all five.

A language is now one declarative file in `lua/kebab/languages/`, and those five
places ask the registry instead. `tests/spec/registry_spec.lua` asserts the
consumers have not grown their own lists again -- it greps `plugins/mason.lua`
for "jdtls", `deps.lua` for "npm install" and so on, so the de-hardcoding cannot
quietly rot.

The unit of *detection* is the marker, not the language, because one language
can be built several ways and they do not behave alike: a Java project is Maven
or Gradle, and adding a dependency means rewriting `pom.xml` in one case and is
unsupported in the other.

Load order is detection order. The specific stacks come first and `generic`
(which claims `.git`) comes last, so a Rust project is "rust" rather than "dir"
even though it is also a git repository.

Users extend it through `vim.g.kebab_languages` -- a list of language tables, or
a function returning one, merged over the built-ins by `key` so a single field
can be changed without restating the rest -- or `registry.register()` in Lua.
`vim.g.kebab_disabled_languages` drops one. The tests use `register()`, so the
extension point users are told about is the one that is exercised. Functions
survive `vim.g` (Neovim stores them as luarefs), so a scaffold added from a
config file is still callable.

The registry is deliberately dependency-free: `plugins/extras.lua` and
`plugins/mason.lua` are lazy specs evaluated while lazy.nvim is still building
its spec, so it has to be requireable on its own.

## `codegen.lua`

The Generate menu a graphical IDE has. jdtls already implemented all of it as
LSP *source* code actions; what was missing was discoverability, since they were
buried in `<leader>ca` among every quick-fix.

The kinds are dot-separated -- `source.generate.toString` -- and **not** the
camelCase names that appear as field names inside the jdt.ls jars. Guessing from
those produced six entries that silently did nothing, which is precisely the bug
class the menu sweep exists to catch. The list was read back off a live server;
the comment in `languages/java.lua` records how to re-derive it.

Worth knowing for next time: before jdtls finishes importing a Maven project it
offers only `organizeImports` and `overrideMethods`. Checking during that window
looks exactly like "these kinds do not exist".

## `templates.lua`

New-file templates. The part worth having is the package line: typing
`package com.example.thing.service;` by hand is tedious and is what you get
wrong after moving a file. `package_for()` reads it off the directory layout and
is a pure function, so it is tested against every shape including the one that
merely ends in `src`.

A template may declare `target_dir`, which is how the JUnit template writes into
`src/test/java` while you are in `src/main/java` -- the backlog's "test class for
the file you are on" -- and `default_name`, which turns `Widget` into
`WidgetTest` without doubling the suffix.

## `scratch.lua`

Scratch files as real numbered files under `stdpath("data")`, not `:enew`
buffers. A buffer would be simpler and much less useful: no filetype, no
language server, gone when you quit. Being outside the project also means they
cannot be committed by accident.

The Java scratch renders its class name from the file name, because a public
class has to match its file.

## `projectfiles.lua`

`.gitignore`, Dockerfile, CI workflow, `.editorconfig`. Distinct from
`templates.lua`, which creates a *source* file where you are and asks what to
call it: these have fixed names and belong at the project root. Mixing them
would mean one picker offering "Java class" next to ".editorconfig".

A generator declares `kinds`, so a Go project is not offered a Maven Dockerfile;
one with no `kinds` (an `.editorconfig`) is always offered. An existing file is
never replaced without asking.

## `runconfig.lua`

The language tasks are generic -- "maven: test" is the same in every Maven
project. These are the ones that belong to *this* project, with its arguments
and environment, in `.kebab/run.json` and committed so the team gets them too.

They reach overseer as a template **provider** rather than registered templates,
which is what makes them re-read on every search: editing the file takes effect
without a restart, and switching project picks up the new one. Their priority is
above the generic tasks, so yours come first in `<leader>oo`.

A malformed file is reported, not ignored. Dropping a colleague's configuration
silently because of a typo is worse than saying what is wrong.

## `plugins/rest.lua`

kulala now asks for a paid licence token the moment a `.http` buffer opens: its
LSP backend downloads "kulala-core", and the download prompts with
`vim.fn.inputsecret("Kulala license token: ")`. Headless that blocks forever --
it hung the test suite, which is how it was found -- and interactively it turns
the layer's advertised `.http` support into a paywall.

Sending a request does not need it; that path is curl-based. So the backend is
left off unless a token is actually present, in which case nothing is taken
away.

## `plugins/mason.lua`

The tooling bootstrap. Without it a fresh install has every plugin and no
language servers, and each language silently reports "no LSP attached" —
which looks like the layer is broken.

## `plugins/java.lua` + `jdk.lua`

LazyVim's Java extra wires jdtls, the debug adapter and the test bundles, but
leaves Eclipse defaults in place. The settings added here are the ones that
close the visible gap against a graphical IDE:

- `maven.downloadSources` / `eclipse.downloadSources` — without these,
  go-to-definition into Spring classes lands in decompiled stubs rather than
  real source. This is the single biggest "this isn't a real IDE" tell.
- `updateBuildConfiguration = "automatic"` — picks up `pom.xml` edits without
  a manual reload, like Maven auto-import.
- Code lenses for references/implementations, parameter-name inlay hints.
- `favoriteStaticMembers` for JUnit/AssertJ/Mockito/MockMvc, so static imports
  complete in tests.

`spring-boot.nvim` adds Spring-specific intelligence jdtls alone does not
have: completion in `application.yml`/`.properties` resolved against your own
beans, bean and request-mapping navigation. It needs `vscode-spring-boot-tools`
from Mason, and its jars are **appended** to jdtls' bundles — `opts.jdtls` is
set as a *function* because `vim.tbl_deep_extend` would otherwise replace the
java-debug/java-test bundle list rather than add to it.

`jdk.lua` replaced hardcoded `/usr/lib/jvm/java-{17,21}-openjdk` paths. It
probes the usual directories plus `JAVA_HOME` and `$(which java)`, derives the
major version from the directory name, and marks the newest as default.

## `plugins/flutter.lua`

LazyVim's dart extra is LSP-only: no device picker, no emulator launch, no hot
reload UI. flutter-tools supplies those, but it starts **its own** `dartls`, so
the lspconfig one is disabled here. A Dart buffer must show exactly one client;
two means this regressed.

## `plugins/python.lua`

`basedpyright` is pointed at the project's own `.venv`/`venv`/`.env` in
`before_init`, so imports resolve without running `<leader>cv` first.

Note that LazyVim defaults `lazyvim_python_lsp` to `pyright`, and that setting
actively *disables* basedpyright — the symptom is a Python buffer with only
`ruff` attached and no completion.

## `plugins/run.lua`

overseer provides the task list and runner; the templates here are the actual
run configurations, gated on project markers (`pom.xml`, `pubspec.yaml`, …) so
only relevant ones appear. npm scripts come from overseer's built-in
`package.json` provider. `.vscode/launch.json` is loaded into nvim-dap so debug
configs can live in the repo and travel with it.

## `explorer.lua`

neo-tree ships as a toggle (`<leader>e`); this keeps it open on the left like
a graphical IDE's project pane, with focus staying in the editor.

Registered from the plugin spec's `init`, which lazy runs during setup —
*before* Neovim reads its file arguments. `lua/config/autocmds.lua` was tried
first and is too late: it loads on `VeryLazy`, after the first file's
`BufReadPost`, so `nvim some/file.java` never opened the tree.

A placeholder plugin spec was also tried and silently dropped, because lazy
keys local specs by `dir` and the user's `theme-hotreload` already claims
`stdpath("config")`.

## `project.lua`

Two entry points, because developers expect both:

- `:IdeNewProject` — wizard: type → name → location, with type-specific steps
  (Spring Boot asks group id and dependencies and fetches from start.spring.io;
  Vite asks for a template).
- `:IdeInitHere` — a graphical editor style: you already made and opened the folder, pick
  a type and it fills it in.

`discover()` scans `~/Projects`, `~/src`, `~/code` and
`~/dev` for directories carrying a project marker, and labels each
by kind. New projects default to `~/Projects` — note the capital P, which is
where this user keeps new work.

Scaffolding is split in two. `M.create()` takes every answer up front and
prompts for nothing; `M.new_project()` is the wizard that collects those answers
through `vim.ui` and calls it. Before the split there was only the wizard, so
nothing about project creation could be tested — and project creation is the
thing most expensive to get wrong, since it writes directories.

Each type declares `requires`, the executables it needs on PATH, so a missing
toolchain is reported as "Flutter app needs flutter on PATH" rather than as a
confusing failure half way through.

## `cli.lua` + `bin/kebab`

Opening and creating projects from the shell, so the IDE starts like `code .`
rather than only from inside Neovim. The shell script only parses arguments and
quotes them into one Lua call; the behaviour is in `cli.lua` where the tests can
reach it without spawning a terminal.

`kebab open foo` prefers a real path over a project name, so `kebab open ./foo`
cannot open some unrelated project called `foo`, and offers a picker when a name
is ambiguous instead of guessing.

`kebab new` passes any `--name value` straight through as an answer rather than
listing the options it knows, which is the same de-hardcoding as everywhere
else: a language that adds a prompt becomes settable without touching the
script, and `kebab types --prompts` documents itself from the declarations. The
cost is that a typo would be swallowed, so `project.create` reports an answer
the chosen type does not ask for -- the check belongs in Lua, where the prompts
are known.

### `doctor`

Grouped by **who owns the version**, which is the split the whole layer rests
on:

- **Required** -- the layer does not work without them. These fail the report.
- **Language toolchains** -- the *project* dictates the version, so they are
  detected and reported and never installed silently. Derived from the
  registry, so a language added later reports its own requirements.
- **Optional** -- something degrades. Each says what is lost.

Only a required check can fail it, so `kebab doctor` exits non-zero exactly
when the install is actually broken. A missing Go toolchain is not a broken
install; it is a Go scaffold you cannot run, and the report says so.

Two things it knows that are easy to miss:

- **Mason installs 31 of its 55 packages through a language toolchain** (npm,
  golang, gem, pypi). A missing toolchain therefore costs language servers as
  well as scaffolds, which is not what anyone expects, so the report says it.
- **`vim._watch` shells out to the `inotifywait` binary.** `:IdeFollow` cannot
  start without inotify-tools, and nothing else would have told you.

Install hints pick the right manager for the kind of tool: a version manager
(mise, asdf) for a language toolchain, the system one (pacman, apt, brew) for
git or jq, and `gem install bundler` for bundler, which is neither.

`deps.lua` and `scaffold.lua` borrow `install_hint()` so the advice lives in one
place. They need it because **`vim.system` throws ENOENT for a missing
executable rather than returning a code** -- which used to abort a dependency
add with a stack trace and never call its completion callback. Both now check
first and report. That bug was found because the doctor pointed out bundler was
missing.

`KEBAB_DRY_RUN=1` prints the Lua a command would run. That is how the tests
check argument quoting — an interactive editor cannot be inspected from a
headless test, and a project name containing a quote must not be able to end the
string and run as code.

## `jdbc.lua` + `java/KebabJdbc.java` + `autoload/db/adapter/jdbc.vim`

The SQL IDE, built the way a dedicated database IDE is rather than the way
vim-dadbod is.

dadbod shells out to the *native* client -- `psql`, `mysql`, `sqlite3` -- so a
database whose client is not installed does not work at all. On this machine
that was most of them: `sqlite3` and `psql` were present, `mysql` was not. JDBC
needs only a driver jar and a JVM, and `DatabaseMetaData` gives real schema
introspection instead of guessing from SQL text.

Three pieces:

- **`java/KebabJdbc.java`** is the bridge. Java's single-file source mode means
  there is no build step and nothing to ship but the file. It is compiled on
  first use anyway and cached: source mode recompiles on every run, measured at
  400-750ms against 200-260ms precompiled, and the variance is worse than the
  mean. Modes: `query`, `tables`, `columns`, `schema`, `ping`, `serve`.

### Why the process is kept warm, and why it is not Rust

Replacing this with a native Rust binary was considered, for speed. The
measurements said not to:

| | |
|---|---|
| one-shot query, as it was | 180 ms |
| **same query on a process already up** | **0.2 ms** |
| trivial Rust binary, cold start | 1.2 ms |
| trivial JVM, cold start | 18 ms |
| first connection-and-query inside a JVM | 140.8 ms |
| second, same process | 0.5 ms |
| twenty queries on one open connection | 1.0 ms total |

The 180ms was never the JVM. It is one-time *per process*: driver class
loading, and for SQLite extracting a bundled native library. So holding the
process open is worth ~600x, and a **warm JVM beats even a cold Rust binary by
about 4x** — a one-shot Rust process would still pay its connect every time.

What a rewrite would additionally have cost: H2 has no Rust driver at all (it
is a Java database), Oracle's crate needs the vendor's native client — losing
the "no native client" property that is the whole point — and `cargo` would
become a build requirement for a feature that today needs only the JDK already
required for Java and the language server.

`serve` therefore keeps one process per connection, holding one open
connection, and answers requests on stdin. The protocol is **length-prefixed**,
not sentinel-delimited:

```
request   <mode>\t<arg>\t<len>\n<payload>
response  <OK|ERR>\t<len>\n<payload>
```

because SQL contains newlines and any sentinel could appear inside a query --
there is a test that sends `-- --KEBAB-END--` as part of a statement.

`M.run()`'s signature did not change, so `db.lua`, `dbcomplete.lua` and the
dadbod adapter were untouched and their existing tests all still pass: that is
the evidence it is a drop-in. It falls back to a one-shot run whenever a
process cannot be started, and `VimLeavePre` closes them -- a child process
holding a database connection must not outlive the editor.
- **`jdbc.lua`** finds and fetches drivers. Nine databases are registered, each
  with its Maven coordinates and a URL template, extensible through
  `vim.g.kebab_jdbc_drivers` in the same shape as the language registry.
- **`autoload/db/adapter/jdbc.vim`** is a dadbod adapter. That is the whole
  trick: being an adapter rather than something standalone means `:DB`, `:DBUI`
  and `vim-dadbod-completion` all keep working, over JDBC, unchanged.

**Drivers are fetched over plain HTTPS, not with Maven.** `mvn
dependency:build-classpath` could not resolve its own plugin on this machine
even with Maven Central reachable (`PluginResolutionException`), and requiring
`mvn` at all would exclude anyone with a JDK but no Maven. A jar is a GET from
`repo1.maven.org`, and the version comes from the artifact's own
`maven-metadata.xml`. The few transitive dependencies that matter are named in
the registry -- `mysql-connector-j` needs `protobuf-java` at runtime.

An already-downloaded jar also answers the version question, so a cached driver
keeps working with no network.

## `db.lua`

The part a person uses: saved connections, a table browser, query consoles.

Connections live in `stdpath("data")`, mode 0600, never in the project. **A
password is never stored** -- a connection names an *environment variable* to
read it from. Committing a password by accident is a worse problem than typing
`export` once. Credentials reach the JVM through its environment rather than
argv, so they do not appear in the process list.

## `dbcomplete.lua`

Measured against `vim-dadbod-completion` on a live database: it completes a
table-name prefix, and a column through an alias. It does *not* offer the bare
table list, and does not turn `customers.` into that table's columns -- the two
things you reach for most. Its cache is also filled from a `FileType sql`
autocmd, which fires *before* `b:db` exists, so in a standalone `.sql` file --
exactly what a scratch file is -- completion stays empty for the whole session.
`db.lua` re-runs the fetch on attach to fix that.

Since `KebabJdbc schema` already returns every table, column and type in one
round trip, this source answers from that instead, with the type shown beside
each column. It runs alongside dadbod's rather than replacing it.

Alias resolution is worth noting: Lua patterns have no optional groups, so
`from customers c` and `from customers as c` are matched separately, and a
keyword list stops `from customers where ...` from registering an alias called
"where".

## `deps.lua`

BACKLOG.md called adding a dependency "the biggest remaining daily gap against
a graphical IDE". Where a package manager can do the work -- `flutter pub add`,
`npm install`, `uv add` -- it is handed over. Maven has no such command, so the
pom is edited here, which is what a graphical IDE does too.

That editing is pure string functions, tested exhaustively, because a bad
insertion corrupts a build file -- not a failure mode worth finding by hand.
The tests check the result with a real XML parser rather than a substring match.

Three things it has to get right:

- **The right `<dependencies>`.** A plain search finds the one inside
  `<dependencyManagement>` first on every Spring pom, and adding there declares
  a managed version without depending on anything. `find_dependencies_block`
  scans tags and takes the block whose parent is `<project>`.
- **Whether a version is needed.** Under `spring-boot-starter-parent` a starter
  must *not* carry one, or it overrides the curated set. Anything else without a
  version only resolves if `dependencyManagement` covers it, so that case is
  refused with a reason instead of writing an unbuildable pom.
- **Indentation.** Taken from the block the scanner found. Deriving it by
  matching `<dependencies>` picks up dependencyManagement's copy, which is one
  level deeper, and the new entry landed at 16 spaces in a 12-space file.

A bare name expands to a Spring Boot starter, because `data-jpa` is what you
actually want to type on a Spring project.

## `gradle.lua`

The Gradle half of adding a dependency, and the same reasoning as `maven.lua`:
Gradle has no command for it either, so the build file is rewritten by pure
string functions.

Two things it has to get right that Maven does not:

- **Two dialects.** `implementation("a:b:1")` in a `.kts` file,
  `implementation 'a:b:1'` in a `.gradle` one, chosen from the file name.
- **The right `dependencies { }`.** Found by brace matching rather than a
  pattern, because a build file nests freely: `buildscript { dependencies { } }`
  comes *first* in most files, and adding there declares a plugin classpath
  entry rather than a dependency. Only the block at brace depth 0 is the
  project's own.

Line comments are blanked to spaces rather than removed, because every position
the module returns indexes the original text -- shortening the string shifted
every offset after the first comment, which is the bug this replaced.

## `follow.lua`

Ghost programming: follow an agent's edits as they happen.

There is no agent registration and nothing to configure per agent. The signal
is "the file changed on disk while the buffer had no unsaved changes of its
own", which is what any external editor looks like -- so a save from another
Neovim, a `git checkout` and a formatter all count. On reflection that is the
feature rather than a flaw.

Watching is `vim._watch`'s inotify backend. Note what *not* to use:
`vim.uv.new_fs_event():start(dir, { recursive = true }, cb)` **returns success
on Linux and then does not recurse**, so it silently watches only the top
directory.

Most of the design is in what it refuses to do:

- It never reloads over your own edits. A buffer that is modified *and* changed
  on disk is a conflict; discarding either side silently is the one thing this
  must not do.
- It yields in insert mode, visual mode, the command line, with a completion
  menu or picker open, in a terminal or prompt buffer, and whenever the current
  buffer is modified. A dropped jump beats a stolen cursor -- and dropped
  rather than queued, because by the time you leave insert mode the jump is
  about something you have stopped caring about.
- It does not open files that are not already in a buffer unless asked.
- Events are coalesced over 250ms, latest wins, so a forty-file refactor is
  watchable instead of a slideshow.
- Ignores match whole path segments, so `target/` and `node_modules/` are
  skipped while a project called `build-tools` is not.

`first_change()` is why the cursor lands on the edit rather than the top of the
file, and it is a pure function, so it is tested directly.

## `menus/` and `plugins/menu.lua`

Terminal Neovim has no menu bar, so these are right-click popups via
`nvzone/menu`. Every entry carries `rtxt` with its keybinding, which makes the
menu double as a way to learn the shortcuts.

Menus are passed as **tables**, not strings: the plugin only resolves strings
against its own bundled `menus.*` modules.

`menus/tree.lua` resolves the neo-tree window lazily and refocuses it before
running a command. This is essential, not cosmetic — by the time a menu entry
fires, focus is on the menu, and neo-tree's `get_state_for_window()` returns
nil for any non-tree window. The first version asserted on that nil, so
"New File" threw and "Revert" silently did nothing.

Revert is implemented by hand rather than calling neo-tree's `git_revert_file`,
because that runs `git checkout HEAD -- <path>`, which **ignores untracked
files**. Reverting a newly added file did nothing and said nothing. The
replacement inspects `git status` for the selected node, partitions tracked
from untracked, asks once with a message stating exactly what will happen, then
restores tracked files and deletes untracked ones, which is what a "revert"
is expected to do. It always reports, including "nothing to revert".

## `menus/action.lua`

Menu entries used to be bare closures:

```lua
cmd = function() pcall(function() Snacks.picker.projects() end) end
```

Nothing outside such a closure can tell what it targets, and the `pcall` turns
a renamed upstream function into silence. That is how `menus/editor.lua` came
to have ~90 entries verified only to *render*, three of which did nothing at
all.

Every action is now built here — `A.ex`, `A.mod`, `A.g`, `A.pick`, `A.lsp`,
`A.custom`, `A.tag` — and each builder registers a descriptor beside the
closure it returns. The menu still gets a plain function; the sweep in
`tests/spec/menu_editor_spec.lua` reads the descriptor and checks the target
resolves. An entry that is just a closure fails the sweep, which is the point:
the hole cannot be reopened quietly.

`A.custom` demands a `check()` alongside the function, so even bespoke logic
has to say how it can be verified.

## `git.lua`

The revert `menus/tree.lua` performs, split out so it can be tested against a
real repository instead of only through a selected node in a tree window.

`git checkout HEAD -- <path>` ignores untracked files, so reverting a newly
added file looked like it did nothing — and the first investigation missed it
because `git diff` was clean. `revert_plan()` splits porcelain status into
tracked and untracked, `apply_revert()` restores the former and deletes the
latter, and `describe_plan()` is what the confirmation prompt says out loud so
a deletion is never a surprise.

## `plugins/ui.lua`

neo-tree behaviour (single-click folder expand, follow current file, dotfiles
visible, gitignored hidden) plus `signature = { enabled = true }` for blink,
which LazyVim ships commented out. Parameter hints matter on Spring and Mockito
signatures.

## `lsp.lua` + `agent.lua`

Semantic queries for a caller that is not a person.

The reasoning for building this at all: an agent in a repository already has
file I/O, grep and a shell, so a CLI that only wrapped those would add nothing.
What it cannot get is what the language server knows -- where a symbol is
defined, who calls it, whether the last edit introduced an error. This layer
already boots a full LSP environment, so it is the one thing it can offer that
nothing else can.

**Read-only, deliberately.** No rename, no format, no code actions. An agent
driving these unattended cannot damage a repository, and a test asserts the
command list contains nothing that writes.

Design decisions worth keeping:

- **Severities and symbol kinds are names, not numbers.** `"error"`, not `1`;
  `"Function"`, not `12`. Whatever reads the JSON should not need the protocol
  spec.
- **Positions are 1-based** in and out, because that is what a command line and
  an editor both use. LSP counts from zero; the conversion is in one place.
- **"No language server attached" is an error, not an empty result.** An agent
  must be able to tell "no errors" from "could not check". For the same reason
  diagnostics carry a `settled` flag: a clean file and a server that has not
  published yet are otherwise indistinguishable.
- **The exit code reports whether the query worked**, not what it found.
  Finding errors is a successful query. `--exit-code` opts into failing on an
  error, which is the shape a pre-commit hook wants.

### Why the warm instance is Neovim's own, not ours

A one-shot query costs ~250ms for gopls and up to 150s for jdtls importing a
Maven project -- the same per-process problem the JDBC bridge had. Here Neovim
already solves it: `nvim --listen` plus `--remote-expr` gave a ~4ms round trip
on the first try, with the language server still attached. So `kebab serve` is
`nvim --headless --listen`, and `--server` is a `--remote-expr` call. Nothing to
build and nothing to maintain.

Measured: **~15ms** a query warm against ~250ms cold.

Arguments travel as JSON because a query has to survive shell -> VimScript ->
Lua quoting, and JSON is the only encoding all three agree on. The reply is
**not** JSON: the exit code goes on the first line and the output follows, which
means one round trip and no parser on the caller's side -- and the output may
itself be JSON, which nesting would only have to be unwrapped again. The first
version made three RPC calls to read back a number and a string, which was
silly.

Two traps found by using it:

- A unix socket path is limited to about 108 bytes. A socket under the test
  scratch directory failed to bind *silently*; `serve` now refuses a path
  longer than 100 characters, and the default lives in `$XDG_RUNTIME_DIR`.
- **A warm instance holds the Lua it started with.** After editing the layer it
  answers with the old code, which looks like a protocol mismatch rather than a
  stale process. It cost a confusing few minutes; restart it.

## `tests/`

One headless Neovim loaded from the real user config, running every spec in
process. plenary's busted runner spawns children with a minimal init, which
would hide exactly the bugs this layer has: integration bugs, where a command
belongs to a plugin that has not loaded or a global is not set yet.

Two rules the suite follows, both from CLAUDE.md. It never opens a file the user
owns, and it runs with `-n` so a killed session cannot leave an `E325` swap file
behind. And it asserts on effects — a file created, a window opened, a file
reverted — not on modules loading.

Two things it had to work around:

- `VeryLazy` is fired off `UIEnter`, which never happens under `--headless`, so
  most of LazyVim's own keymaps were never set and "is this shortcut real?"
  answered no for keys that plainly work. `tests/run.lua` fires it by hand.
- `LazyVim.lazy_notify()` installs a queueing stand-in as `vim.notify` and swaps
  the original back only when something *else* replaces it. Capturing
  `vim.notify` and restoring it therefore reinstalls the stand-in, and LazyVim's
  `replay()` then feeds the queue through itself, re-queueing every message
  until Lua raises `table overflow` and the run dies. The harness pins
  `vim.notify` to a baseline of its own before any spec runs. Finding this took
  the suite from 1m46s to under 2s.
