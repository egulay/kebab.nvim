# kebab.nvim

A lightweight IDE layer for [LazyVim](https://lazyvim.github.io), built so a
full graphical IDE is no longer needed for day-to-day work — without giving up
the terminal.

It is a plugin spec collection, not a Neovim distribution: LazyVim stays in
charge, this adds the IDE on top.

## What it gives you

- **Languages**: Java/Spring Boot, Kotlin, Python, Ruby, JavaScript *and*
  TypeScript, Svelte/Tailwind, Dart/Flutter, Go, Rust, SQL, Docker,
  YAML/JSON/TOML, Markdown — language servers, debuggers, test runners and formatters installed
  automatically through Mason.
- **One file per language.** Everything the layer knows about a stack — its
  project markers, scaffolds, Mason packages, LazyVim extras, run
  configurations, dependency command, file templates — is declared in one
  `lua/kebab/languages/*.lua`. Adding a language is adding a file, and a user
  can add or override one from their own config without touching the repo.
- **Spring Boot**: `application.yml` completion against your own beans, bean and
  request-mapping navigation, library sources on go-to-definition.
- **Flutter**: device picker, emulator launch, hot reload/restart, dev log.
- **Run configurations**: Maven, Flutter, Python and npm tasks, plus any
  `.vscode/launch.json` the project ships.
- **Add a dependency** without leaving the editor: a Maven coordinate goes into
  `pom.xml` (omitting the version when Spring Boot's parent already manages it),
  Gradle's `dependencies { }` block is edited the same way, in Kotlin or Groovy
  dialect; the rest hand off to `flutter pub add`, `npm install`, `uv add`,
  `cargo add`, `go get` or `bundle add`.
- **Generate code** the way a graphical IDE does: constructor, getters and
  setters, `toString`, `equals`/`hashCode`, override methods, delegates.
- **File templates** that fill in the Java package from the directory, and put a
  JUnit test under `src/test/java` with the same package.
- **Scratch files** — `.http`, `.sql` and one per language — kept outside the
  project as real files, so a language server attaches and they survive a
  restart.
- **Project file generators**: a `.gitignore`, Dockerfile and CI workflow for
  the language in hand, plus `.editorconfig`.
- **Per-project run configurations** in `.kebab/run.json`, with args and env,
  committed so your team gets them too.
- **Follow external edits** (`<leader>uf`): when something outside the editor
  changes a file — an AI agent working in the project, say — the view moves to
  the line that changed. On by default, yields to your own typing, and never
  reloads over unsaved changes.
- **Projects**: create from a wizard or scaffold into the folder you are already
  in; open any project found under your usual roots — from inside the editor or
  from the shell with the `kebab` command.
- **An always-on project tree** on the left, open by default rather than toggled.
- **Right-click menus** — Project / File / Edit / Code / Run / Git / View — each
  entry showing its keybinding, so the menu teaches the shortcut. Mouse and
  keyboard are both first-class: every entry has a shortcut, and the Edit menu
  carries a command palette for finding things by name.
- **SQL, over JDBC**: saved connections, a table browser, query consoles and
  completion that knows your tables, columns and their types. Drivers are
  downloaded from Maven Central on first use, so a database needs no `psql` or
  `mysql` binary installed — only a JDK. Nine databases out of the box.
- **Git**: lazygit, inline hunks, side-by-side diff and 3-way merge, and a
  Revert that discards tracked changes *and* deletes untracked files, rather
  than silently ignoring the untracked ones the way `git checkout` does.

## Requirements

Run **`kebab doctor`** — it groups everything by who owns the version, says
what each missing tool costs you, and prints the command to install it using
whatever package manager this machine has. It exits non-zero only when
something genuinely **required** is absent, so it is safe in a script.

| | |
|---|---|
| **Required** | Neovim 0.12+ with a LazyVim config, `git`, `curl` |
| **Per language** | a JDK, Maven/Gradle, Node, Python, Go, Rust, Ruby, Flutter — only the ones you use |
| **Optional** | `javac` (the SQL editor), `unzip` (the Spring scaffold), `jq` (readable config files), `inotify-tools` (`:IdeFollow`), `lazygit` |

Nothing is bundled, on purpose. Two reasons:

- **31 of the 55 Mason packages install *through* a toolchain** — 14 via npm, 9
  via go, 4 via gem, 4 via pip. Bundling those away would mean shipping a Node,
  a Go, a Ruby and a Python, which is a distribution, not a plugin.
- **A bundled JDK would break Java.** `jdk.lua` discovers every JDK on the
  machine and hands them all to `jdtls`, so each project compiles against its
  own target. Pinning one version would silently index older projects wrongly.

What *is* automatic: the 55 Mason packages, the plugins, and JDBC drivers from
Maven Central. Those are editor infrastructure — no project cares which version
they are.

## Install

One command, from nothing:

```bash
git clone <this repo> ~/Projects/kebab.nvim && ~/Projects/kebab.nvim/install.sh
```

That ends with an editor you can use. `install.sh` writes the lazy.nvim spec,
puts the `kebab` command on your PATH, installs the plugins, and prints what is
still missing — and if there is no Neovim config at all it clones the
[LazyVim](https://lazyvim.github.io) starter first, so a bare machine needs
nothing else. It asks nothing by default; `--ask` makes it confirm each step,
`--dry-run` prints what it would do and changes nothing.

Already have the clone, or want it somewhere else:

```bash
./install.sh                    # from inside the clone
KEBAB_REPO=<this repo> curl -fsSL <raw install.sh> | bash
./install.sh --dir ~/src/kebab.nvim
```

`setup.sh` is the half that writes the config, and can still be run on its own
(`./setup.sh`, `--yes` to skip the questions, `--dry-run` to see them). Nothing
is overwritten without asking, and running either twice changes nothing.

Requires Neovim 0.12 or newer and `git` — two of the plugins this layer
declares (aerial, refactoring) refuse to initialise below it, and `kebab
doctor` says so rather than leaving you with a feature that quietly does
nothing. Restart Neovim afterwards: Mason
installs the language tooling on first launch, and `jdtls` takes about a minute
to index a Maven project the first time.

### Doing it by hand

The spec `setup.sh` writes is a local one, pointing at your clone — so the layer
is yours to edit and lazy never tries to fetch it:

```lua
-- ~/.config/nvim/lua/plugins/kebab.lua
return {
  {
    dir = "~/Projects/kebab.nvim",
    name = "kebab.nvim",
    import = "kebab.plugins",
  },
}
```

`import = "kebab.plugins"` loads every module under `lua/kebab/plugins/`, so
anything added there is picked up automatically.

## The `kebab` command

`bin/kebab` opens and creates projects from the shell, so the IDE starts the way
`code .` does rather than only from inside Neovim. `setup.sh` links it for you;
by hand it is:

```bash
ln -s ~/Projects/kebab.nvim/bin/kebab ~/.local/bin/kebab
```

```bash
kebab                     # open the IDE here, project tree showing
kebab ~/Projects/thing    # open that directory
kebab open                # pick a project from your roots
kebab open alpha           # open it by name; offers a choice if ambiguous
kebab new                 # create a project, asking as it goes
kebab new demo-api --type spring --group io.gulay --deps web,data-jpa
kebab new thing --type go --module github.com/you/thing
kebab new app --type node --language javascript
kebab new demo --type empty --no-open   # create it and stop, for scripts
kebab list                # every project found under your roots
kebab types               # what can be created, and what each needs installed
kebab types --prompts     # ...and what each one asks you
kebab doctor              # check the install

kebab db                  # the SQL IDE: explorer open, connections on the left
kebab db shop_local       # a SQL console on that saved connection
kebab db --env ~/p/.env   # export a .env file first, so the passwords are there
```

Any question a project type asks is settable as `--name value`, so a language
that adds a prompt needs no change to the script — `kebab types --prompts` lists
them, generated from the declarations themselves. An answer the chosen type does
not ask for is reported rather than ignored, so a typo does not look like it
worked.

Project roots default to `~/Projects`, `~/src`, `~/code` and `~/dev` — generic
conventions, not whatever your editor named a folder after itself. Override
with `vim.g.kebab_project_roots`, or with `KEBAB_PROJECT_ROOTS` (colon
separated) for a single invocation, which wins. `KEBAB_DRY_RUN=1` prints the Lua a command would
run instead of running it.

Each root is scanned two levels deep, so `~/Projects/work/<project>` is found
as well as `~/Projects/<project>`; a directory that is itself a project is not
descended into, and `node_modules` and friends are never walked.
`vim.g.kebab_project_depth` (default 2) and `vim.g.kebab_project_scan_limit`
(default 2000 directories) bound it. A root that exists but cannot be read is
reported rather than silently skipped — `kebab list` says `skipped <path>:
EACCES`, and `kebab doctor` has a "project roots readable" check.

## Databases

Shaped like a dedicated database IDE: add a data source once, then browse it
and query it.
Connections are JDBC, and the driver is fetched from Maven Central the first
time you use it.

`kebab db` opens the three panes a database IDE opens with, and a **double
click** on a table in the tree writes its select into the statement pane and
its rows underneath — then `<leader>S` runs whatever you edit it into, and the
rows pane refreshes:

```
+-----------+--------------------------+
| explorer  | select * from "customers"|
|           +--------------------------+
|           | id | full_name           |
+-----------+--------------------------+
```

The statement pane is a real file under `stdpath("data")`, not a scratch
buffer, so the query you edited is still there tomorrow.

`:IdeDbStructure` (or right-click → Table) answers the other half of reading
somebody else's database — what the columns are, which is the key, and how the
tables are joined:

```
-- orders

columns
  id           INTEGER  not null  pk, auto
  customer_id  INTEGER  not null
  total_cents  INTEGER  not null  default 0

primary key
  id

foreign keys
  customer_id → customers.id

referenced by
  order_lines.order_id → id

indexes
  orders_by_customer  (customer_id, placed_at)
```

All of it comes from JDBC's own metadata, so it works on every driver rather
than on the two whose dialect someone remembered.

In the grid, `v` or `Enter` opens the cell under the cursor on its own — JSON
indented, long text wrapped, `y` to copy, `q` to close — because a document on
one line makes a column wider than the pane and pushes the rest off the side.
`a` fetches every row (capped by `vim.g.kebab_db_fetch_all_cap`, 10000) and `c`
counts them: on demand, never automatically, since `count(*)` is a full scan.

`Space D x` asks what the database will *do* with the statement, which is how
you find out whether a schema supports the question being asked:

```
-- shop · plan
detail
SEARCH c USING INTEGER PRIMARY KEY (rowid=?)
SEARCH o USING COVERING INDEX orders_by_customer (customer_id=?)
```

Each database is asked the way it expects: `explain (format text)` on
PostgreSQL, `explain query plan` on SQLite (plain `explain` there returns
bytecode), `explain` on MySQL, MariaDB, H2, DuckDB and ClickHouse, and for SQL
Server and Oracle the two or three statements they need — which have to share a
connection, so those use the warm process and say so if it is off. `Space D X`
adds ANALYZE where the database has it, and is refused for anything that is not
a select, because ANALYZE executes the statement.

Not provided, deliberately: an editable result grid and click-to-sort. Writing
and ordering are SQL you type.

| | |
|---|---|
| `<leader>DD` | Database explorer |
| `<leader>Da` | Add a connection (asks, then tests it) |
| `<leader>Dt` | Browse tables, open one to see its rows |
| `<leader>Dq` | New SQL console bound to a connection |
| `<leader>Dc` | Attach a connection to this buffer |
| `<leader>S` | Run the statement under the cursor |

Queries run against a process that is kept warm per connection, so the first
costs about 180ms and every one after it about 0.2ms. `:IdeDbStatus` reports
what is running; `:IdeDbDisconnect` closes them.

PostgreSQL, MySQL, MariaDB, SQLite, SQL Server, Oracle, H2, DuckDB and
ClickHouse are registered. Add your own:

```lua
vim.g.kebab_jdbc_drivers = {
  { key = "firebird", label = "Firebird",
    coords = { "org.firebirdsql.jdbc:jaybird" },
    url = "jdbc:firebirdsql://{host}:{port}/{database}", default_port = 3050 },
}
```

Connections live in `stdpath("data")/kebab/connections.json`, mode 0600, never
in the project. **A password is never stored** — a connection names an
environment variable to read it from:

```json
{ "connections": [
  { "name": "prod", "url": "jdbc:postgresql://db:5432/shop",
    "user": "ada", "password_env": "SHOP_DB_PASSWORD" }
] }
```

Pointing `password_env` at a name an existing project already exports — a
`.env` file it ships with — means sourcing that file is all the setup there is.
`kebab db --env <file>` does the sourcing itself, and `$KEBAB_DB_ENV` names a
file to use when `--env` is not given, so `kebab db` alone is enough. The
sourcing happens in the shell, before Neovim starts: a connection reads its
variable from the editor's own environment, which nothing can add to afterwards.

If a server rejects the connection with `FATAL: invalid value for parameter
"TimeZone"`, the machine's timezone is a legacy alias (`timedatectl show -p
Timezone` answering `Turkey`, `Japan`, `Poland`, anything without a `/`). The
JVM repeats that name verbatim and a server whose tzdata has no
backward-compatibility links refuses it. Set
`vim.g.kebab_jdbc_timezone = "Europe/Berlin"` — or fix it for every program
on the machine with `timedatectl set-timezone <Area/Location>`.

Completion knows tables, `customers.` → that table's columns with their types,
and aliases (`select c. from customers c`). It is a separate blink source from
`vim-dadbod-completion`, which covers table prefixes and aliases but not the
bare table list or `table.`.

## Adding a language

A language is one file. This is the whole of what makes Go work:

```lua
-- lua/kebab/languages/go.lua
return {
  key = "go",
  label = "Go",
  markers = { { file = "go.mod", kind = "go", deps = { command = function(pkg)
    return { "go", "get", pkg }
  end } } },
  extras = { "lazyvim.plugins.extras.lang.go" },
  tools = { "gopls", "delve", "gofumpt" },
  tasks = { { name = "go: test ./...", cmd = { "go" }, args = { "test", "./..." },
             desc = "Run all tests", marker = "go.mod" } },
  project_types = { … },   -- what :IdeNewProject offers
  templates = { … },       -- what :IdeNewFile offers
  project_files = { … },   -- what :IdeProjectFile offers
  scratch = { … },         -- what :IdeScratch offers
  codegen = { … },         -- what :IdeGenerate offers
}
```

From your own config, without forking anything:

```lua
-- add one, or override a field of a built-in one
vim.g.kebab_languages = {
  { key = "zig", label = "Zig", markers = { { file = "build.zig", kind = "zig" } },
    tools = { "zls" } },
  { key = "go", label = "Go (my way)" },   -- merged over the built-in
}

-- or drop one entirely
vim.g.kebab_disabled_languages = { "dart" }
```

`require("kebab.registry").register({ … })` does the same thing in Lua.

## Semantic queries, for a script or an agent

An AI agent working in a repository already has file I/O, grep and a shell.
What it cannot get from those is what the language server knows. These expose
exactly that, and **nothing here writes to the working tree** — an agent driving
them unattended cannot damage anything.

```bash
kebab diagnostics src/Main.java          # did my edit break something?
kebab definition  src/Main.java:42:18    # where is this defined?
kebab references  src/Main.java:42:18    # who calls it?
kebab symbols     src/Main.java          # what is in this file?
kebab hover       src/Main.java:42:18    # what type is it?
```

Output is `file:line:col: …`, so it is greppable and an editor can jump to it.
Add `--json` for a machine-readable answer, and `--exit-code` to make
`diagnostics` fail when it finds an error — the shape a pre-commit check wants:

```bash
kebab diagnostics src/Main.java --json
# {"ok":true,"command":"diagnostics","count":1,"clients":["gopls"],
#  "diagnostics":[{"line":11,"col":6,"severity":"error",
#                  "source":"compiler","message":"declared and not used: unused"}]}
```

The exit code says whether the *query* worked, not what it found. Finding errors
is a successful query; `--exit-code` opts into the other behaviour, with `0` for
a clean file the server reported on, `1` for an error, and `2` for inconclusive
— nothing published yet. That third code is the point: a gate that cannot tell
"clean" from "the language server was still cold" passes whenever it is slow.

### Keeping it warm

A one-shot query boots Neovim and waits for a language server: about **250ms**
for `gopls`, but jdtls needs up to **150s** to import a Maven project. For
anything more than an occasional question, keep an instance up:

```bash
kebab serve &                                      # listens on $XDG_RUNTIME_DIR/kebab.sock
kebab --server /run/user/1000/kebab.sock diagnostics src/Main.java
```

That is **~15ms** a query instead of 250ms, and jdtls indexes once rather than
per call. It uses Neovim's own `--listen`/`--remote-expr`, so there is no daemon
of ours in the picture.

Two things to know: a unix socket path is limited to about 108 bytes (`serve`
refuses a longer one rather than failing to bind silently), and **a warm
instance holds the code it started with** — restart it after editing the layer.

## Tests

```bash
./tests/run.sh            # everything
./tests/run.sh project    # only specs whose name contains "project"
KEBAB_TEST_KEEP=1 ./tests/run.sh   # keep the scratch directory for inspection
```

The suite runs inside one headless Neovim loaded from your real config, so the
plugins it checks are the ones that actually ship. It asserts on effects — files
created, a window opened, a file reverted — rather than on modules loading, and
it never touches a file outside its own scratch directory.

## Keymaps

See [CHEATSHEET.md](CHEATSHEET.md). Leader is `Space`; press it and wait for
which-key. The quickest way in:

| | |
|---|---|
| `<leader>pn` | New project |
| `<leader>po` | Open project |
| `<leader>pk` | The cheatsheet |
| `<leader>M` | Menu (or right-click anywhere) |
| `<leader>oo` | Run a task |
| `<leader>pd` | Add a dependency |
| `<leader>cg` | Generate code |
| `<leader>fN` | New file from a template |
| `<leader>or` | Run configuration |
| `<leader>uf` | Follow external edits |
| `<leader>pD` | Doctor |
| `<leader>sC` | Command palette |

## Publishing

```bash
./push "what changed"          # stage everything, commit, push
./push --dry-run "what changed"  # show what would happen, change nothing
./push --amend "better message"  # amend the last commit instead
```

It honours `.gitignore`, and on first run adds the `origin` remote, configures
git credentials through `gh`, and renames `master` to `main`.

## Design notes

[DESIGN.md](DESIGN.md) explains each module and the decisions behind it.
[BACKLOG.md](BACKLOG.md) is what is deliberately not done yet.

## Licence

MIT
