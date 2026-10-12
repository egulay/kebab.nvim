# Neovim as an IDE — keymap reference

**How to read these.** Each shortcut is written as the keys you press, in
order, one after another — `Space c a` means press Space, then c, then a. Not
together. A capital letter means hold Shift: `Space f S` is Space, f,
Shift+S. `Ctrl+Enter` means hold Ctrl and press Enter. Anything starting with
`:` is a command you type, ending with Enter.

Nothing to memorise: press `Space` and wait half a second, and a panel lists
everything available, grouped, with descriptions. Right-click shows a menu with
the same keys beside each entry.

Nothing here is from memory — every binding below was read out of the live config.

## Navigation (the reflexes to relearn)

| Was | Here | |
|---|---|---|
| `Alt+Enter` | `Space c a` | Code action — the one you'll use most |
| `Ctrl+B` | `g d` | Go to definition |
| `Alt+F7` | `g r` | Find usages |
| `Ctrl+Alt+B` | `g I` | Go to implementation |
| `Ctrl+Shift+B` | `g y` | Go to type definition |
| `Ctrl+Q` | `K` | Quick docs (twice to enter the window) |
| `Shift+Shift` | `Space Space` | Find file |
| `Ctrl+Shift+F` | `Space /` | Find in project |
| `Ctrl+F12` | `Space c s` | File structure (Aerial) |
| `Ctrl+Alt+Shift+N` | `Space s S` | Go to symbol in project |
| `Ctrl+E` | `Space f r` | Recent files |
| `Ctrl+Tab` | `Space b b` | Previous buffer |
| `Alt+1` | `Space e` | Project tree (opens by itself; this toggles it) |
| `F2` | `] d` / `[ d` | Next / previous diagnostic |
| Problems | `Space x x` | Diagnostics list (Trouble) |
| Recent projects | `Space f p` | Project switcher |
| Git tool window | `Space g g` | lazygit |
| `Alt+Insert` | `Space c g` | Generate (constructor, getters, toString, override) |
| Find action / command palette | `Space s C` | Every command by name |
| `Ctrl+Alt+S` → Keymap | `Space s k` | Search the keymaps |

## Projects

| | |
|---|---|
| `Space p n` | New Project (wizard) |
| `:IdeInitHere` | Scaffold into the folder you already made |
| `Space p o` | Open Project (scans the configured project roots) |
| `Space f p` | Recent projects |
| `Space p r` | Restore session for this project |
| `Space p d` | Add a dependency to this project |
| `Space p k` | This cheatsheet (also `:IdeCheatsheet`) |

The dashboard (bare `nvim`) also has `p` Open Project and `N` New Project.

From the shell, the `kebab` command does the same without starting in the
editor first:

| | |
|---|---|
| `kebab` | open the IDE here, tree showing |
| `k e b a b   o p e n   name` | open a project by name |
| `k e b a b   n e w   name   - - t y p e   s p r i n g` | create one without being asked anything |
| `k e b a b   n e w   n   - - t y p e   g o   - - m o d u l e   g i t h u b . c o m / y o u / n` | any prompt is `--name value` |
| `kebab types --prompts` | what each type asks you |
| `kebab list` / `kebab types` | what exists / what can be created |
| `kebab doctor` | check the install; non-zero only if something required is missing |

Types: Spring Boot (Maven), Maven (plain), Kotlin (Gradle), Ruby (bundler +
rspec), Flutter, Go module, Rust (cargo), Python (venv + pyproject), Node
(TypeScript *or* JavaScript), Vite (React/Svelte/Vue/Solid, TS *or* JS), Empty.

### Generating code

`Space c g`, or `:IdeGenerate <name>`. Needs a language server attached —
in Java that means waiting for jdtls to finish importing the project.

| | |
|---|---|
| Constructor... | from the fields you pick |
| Getters and Setters... | or just getters, or just setters |
| toString()... | |
| equals() and hashCode()... | |
| Override/Implement Methods... | |
| Delegate Methods... | |
| Organize Imports | |

### New files

| | |
|---|---|
| `Space f N` | New file from a template (`:IdeNewFile`) |
| `Space f S` | New scratch file (`:IdeScratch http`, `sql`, `go`, …) |
| `Space f s` | Reopen a scratch file |
| `Space p f` | Generate a project file (`.gitignore`, Dockerfile, CI, `.editorconfig`) |

A Java template fills the package line in from the directory. The JUnit
template writes into `src/test/java` with the same package, named after the
file you were on.

Scratch files are real files under `stdpath("data")`, so a language server
attaches and they survive a restart — and they cannot be committed by accident.

### Run configurations

Project-specific ones live in `.kebab/run.json` and are committed with the
project:

| | |
|---|---|
| `Space o r` | Run one (`:IdeRunConfig`) |
| `Space o e` | Edit them (`:IdeRunConfigEdit`, writes an example first time) |
| `Space o o` | Every task, project configurations first |

```json
{
  "configurations": [
    {
      "name": "api (local profile)",
      "cmd": ["./mvnw"],
      "args": ["spring-boot:run", "-Dspring-boot.run.profiles=local"],
      "env": { "LOG_LEVEL": "debug" },
      "cwd": "."
    }
  ]
}
```

### Adding a dependency

`Space p d`, or `:IdeAddDependency <what>`. `:IdeAddDependency!` adds it as a
dev dependency where the ecosystem has the idea.

| In a | Type | and it |
|---|---|---|
| Maven project | `data-jpa` | adds `spring-boot-starter-data-jpa`, no version needed |
| Maven project | `org.flywaydb:flyway-core:10.17.0` | adds it with that version |
| Flutter project | `provider` | runs `flutter pub add provider` |
| Node project | `z o d` | runs `npm install zod` |
| Python project | `httpx` | runs `uv add httpx`, or pip into `.venv` |
| Gradle project | `data-jpa` | edits `dependencies { }`, Kotlin or Groovy dialect |
| Go project | `github.com/go-chi/chi/v5` | runs `go get` |
| Ruby project | `sinatra` | runs `bundle add sinatra` |

On a system Ruby whose gem directory is root-owned, `bundle add` writes the
Gemfile and then fails to install. Fix it per project with
`bundle config set --local path vendor/bundle` — the generated `.gitignore`
already excludes `/vendor/bundle`.
| Rust project | `serde` | runs `cargo add serde` |

A coordinate with no version is refused unless the pom actually manages it —
better than a pom that will not build. A duplicate is reported, not added
twice.

## Run configurations & tasks

| | |
|---|---|
| `Space o o` | Run task (Maven, Flutter, Python, npm scripts) |
| `Space o w` | Task list |
| `Space o t` | Task action (restart, stop, open output) |

Registered automatically when the project matches: `mvn spring-boot:run`,
`mvn test`, `mvn package`, `mvn clean install`, `flutter run/test/pub get/
analyze`, `p y t h o n   file`, `pytest`. npm scripts come from `package.json`.
A project's `.vscode/launch.json` is loaded into nvim-dap if present.

## Flutter (in a .dart buffer)

| | |
|---|---|
| `Space F r` / `Space F q` | Run / Quit |
| `Space F h` / `Space F R` | Hot reload / Hot restart |
| `Space F d` / `Space F e` | Devices / Emulators |
| `Space F l` / `Space F o` | Dev log / Outline |

## Java tests

The Run menu's test entries dispatch per filetype: `jdtls` in a Java buffer,
neotest everywhere else. neotest has no Java adapter, so a single backend would
report "no tests found" on a file full of them.

jdtls owns these in Java buffers (neotest is not used there):
`Space t r` nearest test · `Space t t` whole class · `Space t T` pick test.

## Project tree & mouse

The tree opens by itself on the left. Mouse is enabled (`mouse=a`).

| | |
|---|---|
| single click a folder | expand / collapse |
| double click a file | open it |
| `Enter` | open file / toggle folder |
| drag the divider | resize the pane |
| `Ctrl+w >` / `Ctrl+w <` | resize by keyboard |
| `a` / `A` | new file / new folder |
| `r` / `d` | rename / delete |
| `y` / `x` / `p` | copy / cut / paste |
| `H` | toggle hidden files |
| `z` | collapse all |
| `R` | refresh |

Git, on the highlighted file:

| | |
|---|---|
| `g a` / `g u` | stage / unstage |
| `g t` | toggle staged |
| `g r` | revert |
| `g c` / `g p` / `g l` | commit / push / pull |
| `Space g e` | git status tree |

Because `g` is now a prefix in the tree, `gg` (jump to top) pauses briefly
before it fires.

## Menus (right-click)

Terminal Neovim has no always-visible menu bar, so this is a popup instead.

- **Right-click in the editor** — File / Edit / Code / Run / Git / View.
  The Git section has stage/unstage hunk, stage whole file, **revert file
  (discard changes)**, blame, diff and file history.
- **Right-click in the tree** — open, new, rename, delete, copy path, and a
  Git submenu: stage / unstage / **Revert / Discard Changes** (restores
  tracked files *and* deletes untracked ones, with one confirmation) /
  undo last commit / commit / push / pull
- **`Space M`** — same editor menu from the keyboard
- Inside a menu: `h` / `l` move between levels, `Enter` runs, `q` closes

Each entry shows its keybinding on the right, so the menu doubles as a way to
learn the shortcuts.

## Completion (blink.cmp)

The menu pops up by itself as you type — there is no key to "turn it on".
If nothing appears, the language server has not attached yet; check `:LspInfo`.

| | |
|---|---|
| `Enter` | Accept the selected item |
| `Ctrl+n` / `Ctrl+p` | Next / previous item (arrows work too) |
| `Ctrl+Space` | Force the menu open, then toggle the doc panel |
| `Ctrl+e` | Dismiss |
| `Ctrl+b` / `Ctrl+f` | Scroll the documentation popup |
| `T a b` / `Shift+Tab` | Jump between snippet placeholders |
| `Ctrl+k` | Toggle signature help (parameter hints) |

Documentation auto-opens after 200ms on the highlighted item, and brackets are
inserted automatically when you accept a function.

## Refactoring

| | |
|---|---|
| `Space c r` | Rename (live preview) |
| `Space c f` | Format buffer |
| `Space c o` | Organize imports (Java) |
| `Space r f` | Extract function |
| `Space r F` | Extract function to file |
| `Space r x` | Extract variable |
| `Space r i` | Inline variable |
| `Space r s` | Select refactor (menu) |
| `Space c x v` | Extract variable (Java/jdtls) |
| `Space c x c` | Extract constant (Java/jdtls) |
| `Space c x m` | Extract method (Java, visual mode) |
| `Space c g s` | Go to super (Java) |

## Debugging

Note the capitalisation: `dO` steps **over**, `do` steps **out**.

| | |
|---|---|
| `Space d b` | Toggle breakpoint |
| `Space d B` | Conditional breakpoint |
| `Space d c` | Run / continue |
| `Space d C` | Run to cursor |
| `Space d O` | Step over |
| `Space d i` | Step into |
| `Space d o` | Step out |
| `Space d t` | Terminate |
| `Space d u` | Toggle debugger UI |
| `Space d e` | Evaluate expression |
| `Space d r` | Toggle REPL |
| `Space d s` | Session info |

## Testing

| | |
|---|---|
| `Space t r` | Run nearest test |
| `Space t t` | Run file |
| `Space t T` | Run all test files |
| `Space t s` | Toggle summary panel |
| `Space t o` | Show output |
| `Space t d` | Debug nearest test |
| `Space t w` | Toggle watch mode |
| `Space t l` | Run last |

## HTTP client (`.http` scratch files)

Open any `.http` file, then:

| | |
|---|---|
| `Space R s` | Send request |
| `Space R r` | Replay last |
| `Space R b` | Open scratchpad |
| `Space R e` | Set environment |
| `Space R c` | Copy as cURL |
| `Space R C` | Paste from cURL |
| `Space R t` | Toggle headers / body |

## Database (JDBC)

Drivers come from Maven Central on first use; no native client needed.

| Was | Here | |
|---|---|---|
| Open the database IDE | `kebab db` | from a shell: explorer open, connections on the left |
| Open a table | **double click it** | the select top right, its rows under it |
| How a table is built | `:IdeDbStructure` | columns, keys both ways, indexes — or right-click → Table |
| One cell on its own | `v` or `Enter` | in the grid: JSON indented, long text wrapped, `y` copies it |
| What the database will do | `Space D x` | the query plan — a scan where you expected an index |
| Right-click a table | **right click** | in the tree: rows, structure, count, copy its name |
| ...and what it did do | `Space D X` | runs it as well; selects only |
| Every row | `a` | up to the cap; `c` counts them |
| Run what you edited | `Ctrl+Enter` | in either pane, and in insert mode too; rows refresh below |
| ...on one connection | `k e b a b   d b   name` | straight into a SQL console |
| Database tool window | `Space D D` | Explorer |
| New data source | `Space D a` | Add a connection, then test it |
| Open a table | `Space D t` | Browse tables, open one |
| New console | `Space D q` | SQL console bound to a connection |
| Attach console to source | `Space D c` | Attach to this buffer |
| Execute | `Ctrl+Enter` or `Space D r` | Run the statement under the cursor |
| | `Space D p` | Test the connection |
| | `Space D e` | Edit the connections file |
| | `:IdeDbStatus` | Connections, and warm processes |
| | `:IdeDbDisconnect` | Close the warm processes |

The first query on a connection costs about 180ms while the driver loads; every
one after it about 0.2ms, because the process is kept open.

Completion in a SQL buffer with a connection attached: tables, `customers.` →
its columns with types, and aliases. `Space D q` attaches for you; in a plain
`.sql` file use `Space D c` first, or completion has nothing to go on.

Note `Space d *` is the **debugger**, so the database namespace is the shifted
`Space D *`.

## Older notes on the SQL story

`Space D` — toggle DBUI. Add connections inside it; completion works in `.sql` buffers.

## Python

`Space c v` — select virtualenv. Do this first in a Python project or basedpyright
will resolve against the system interpreter instead of your venv.

## Claude Code

| | |
|---|---|
| `Space a c` | Toggle Claude |
| `Space a f` | Focus Claude |
| `Space a r` | Resume session |
| `Space a b` | Add current buffer to context |
| `Space a s` | Send selection (visual mode) |
| `Space a a` / `Space a d` | Accept / deny diff |

## Following edits made outside the editor

**On by default.** `Space u f` or `:IdeFollow` turns it off for the session.

When something else changes a file in the project — an AI agent working in it,
another editor, a formatter, a `git checkout` — the view moves to that file and
the cursor to the first changed line, highlighted briefly.

It gets out of your way rather than fighting you:

| It will not move the view when | |
|---|---|
| you are in insert mode, visual mode or the command line | |
| a completion menu or picker is open | |
| the current buffer has unsaved changes | |
| a terminal or prompt has focus | |

And it **never reloads a buffer that you have edited** — if the file also
changed on disk, that is a conflict and it says so rather than discarding
either side. `:IdeFollowStatus` reports what it has been doing.

### The Ghost Mode indicator

It is an **activity** light, not a status light: it appears *because* something
outside the editor has just touched the project, and hides itself again once
things have been quiet for a few seconds. Opening a project no agent is working
in shows nothing at all.

```
                                              ╭──────────────────────────────╮
                                              │  󰊠  Ghost Mode · Thing.java  │
                                              ╰──────────────────────────────╯
```

The ghost drifts while the agent works, names each file as it is followed, and
falls back to a running change count once that name is a couple of seconds old.
It is not focusable and has no mappings — it cannot take your cursor.

```lua
vim.g.kebab_follow_indicator = { idle_ms = 5000 }  -- how long it lingers
```

### It is on already

Opening a project starts the watcher, the badge appears by itself, and a file an
agent edits **or creates** pulls the view across with the cursor on the first
changed line. Nothing to configure.

`Space u f` turns it off, and a stop you asked for sticks — it will not restart
itself until you open another project. To have it off from the start:

```lua
vim.g.kebab_follow_autostart = false
```

An agent working in a repo you do *not* have open is a different tree, and a
watcher only ever sees its own. Name it:

```lua
vim.g.kebab_follow_roots = { "~/Projects/the-other-one" }
```

One inotify watch is placed per subdirectory, so name projects rather than all
of `~/Projects`, or you can exhaust `fs.inotify.max_user_watches`.

### Everything else it takes

```lua
vim.g.kebab_follow = {
  debounce_ms = 250,     -- coalesce a burst; the latest change wins
  follow = "latest",     -- or "first", to stay put during a big refactor
  open_new = true,       -- open files that are not already in a buffer
}

vim.g.kebab_follow_indicator = false   -- no panel at all
vim.g.kebab_follow_indicator = {       -- or tune it
  interval_ms = 120,     -- animation speed
  activity_ms = 2500,    -- how long a filename stays up
  title = "Ghost Mode",
}
vim.g.kebab_follow_spinner = { "󰊠  ", " 󰊠 ", "  󰊠", " 󰊠 " }
```

`follow.status()` returns the same thing as a plain string, for a statusline.

## When git changes outside the editor

A commit, checkout, stash or push made in another terminal is picked up
automatically: the tree's git markers and colours, the gutter signs and the
statusline all re-read their state within a moment. A **push** is the one that
nothing else could notice, because it changes no file — only
`.git/refs/remotes/…`.

| | |
|---|---|
| `:IdeGitRefresh` | re-read it now, by hand |
| `vim.g.kebab_git_watch = false` | stop watching `.git` |
| `vim.g.kebab_git_watch_debounce = 300` | coalescing window, ms |

## Running a shell command without leaving the editor

`:` opens Vim's own command line, so it takes Ex commands — but `!` escapes to
the shell, and that is the whole trick.

| | |
|---|---|
| `:!ls -la` | run it, show the output, `Enter` to come back |
| `:silent !cmd` | run it with no output and no prompt |
| `:r !date` | *read* the output into the buffer at the cursor |
| `:%!sort` | *filter* the whole buffer through a command |
| `:.!bash` | run the current line as bash, replace it with the output |
| `:'<,'>!jq .` | filter just the visual selection |
| `:term htop` | open it in a real terminal buffer |
| `Ctrl+/` or `Space f t` | floating terminal, at the project root |
| `Space f T` | the same, in the current file's directory |

`%` expands to the current file, so `:!python3 %` runs what you are looking at,
and `:!kebab doctor` works because the command is on your PATH. Inside a
terminal buffer, `Ctrl+\ Ctrl+n` returns you to normal mode so you can scroll and
copy; `i` goes back to typing.

For anything you run more than once, put it in `.kebab/run.json` instead
(`Space o r`) so it becomes a task with a name, output pane and exit code,
rather than a line you retype.

## Asking the editor questions from a shell

Read-only, and meant for a script or an AI agent as much as for you.

| | |
|---|---|
| `k e b a b   d i a g n o s t i c s   file` | errors and warnings from the language server |
| `k e b a b   d e f i n i t i o n   file : line : col` | where that symbol is defined |
| `k e b a b   r e f e r e n c e s   file : line : col` | everywhere it is used |
| `k e b a b   s y m b o l s   file` | the outline of a file |
| `k e b a b   h o v e r   file : line : col` | its type and docs |

`--json` for a machine-readable answer. By default the exit code says whether
the *query* worked, not what it found — finding errors is a successful query.

`--exit-code` opts into the shape a pre-commit hook wants, and it has three
outcomes rather than two, because "clean" and "the server never answered" must
not look the same to a gate:

| | |
|---|---|
| `0` | the file is clean, and the server said so |
| `1` | an error-severity diagnostic was reported |
| `2` | inconclusive — nothing was published within the settle window |

A cold `jdtls` can take well over a minute, so for a gate either raise
`--timeout`/settle or keep an instance warm with `kebab serve`.

For more than the odd question, keep an instance warm — 250ms a query becomes
15ms, and jdtls indexes once instead of per call:

```bash
kebab serve &
kebab --server "$XDG_RUNTIME_DIR/kebab.sock" diagnostics src/Main.java
```

A warm instance runs the code it started with, so restart it after editing the
layer.

## Checking the install

`kebab doctor` from a shell, or `Space p D` / `:IdeDoctor` in the editor.

Grouped by who owns the version:

| | |
|---|---|
| **Required** | the layer does not work without these |
| **Language toolchains** | the *project* picks the version, so these are reported, never installed for you |
| **Optional** | something degrades, nothing breaks |

For anything missing it prints what you lose and the command to install it,
using mise if you have it and the system package manager otherwise:

```
Language toolchains
  --   gradle           not installed
         costs:   run configurations
         install: mise use --global gradle@latest
```

It exits non-zero only when a **required** check fails, so it works in a
script. A missing toolchain costs a feature; it is not a broken install.

## Housekeeping

- `:LazyExtras` — toggle language/feature extras
- `:Lazy` — plugin manager, `U` to update
- `:Mason` — language servers, `u` to update
- `:LspInfo` / `:checkhealth` — when something isn't attaching
