# Neovim as an IDE — keymap reference

Leader is `<Space>`. Press `<Space>` and wait: which-key lists everything.
Nothing here is from memory — every binding below was read out of the live config.

## Navigation (the reflexes to relearn)

| Was | Here | |
|---|---|---|
| `Alt+Enter` | `<leader>ca` | Code action — the one you'll use most |
| `Ctrl+B` | `gd` | Go to definition |
| `Alt+F7` | `gr` | Find usages |
| `Ctrl+Alt+B` | `gI` | Go to implementation |
| `Ctrl+Shift+B` | `gy` | Go to type definition |
| `Ctrl+Q` | `K` | Quick docs (twice to enter the window) |
| `Shift+Shift` | `<leader><space>` | Find file |
| `Ctrl+Shift+F` | `<leader>/` | Find in project |
| `Ctrl+F12` | `<leader>cs` | File structure (Aerial) |
| `Ctrl+Alt+Shift+N` | `<leader>sS` | Go to symbol in project |
| `Ctrl+E` | `<leader>fr` | Recent files |
| `Ctrl+Tab` | `<leader>bb` | Previous buffer |
| `Alt+1` | `<leader>e` | Project tree (opens by itself; this toggles it) |
| `F2` | `]d` / `[d` | Next / previous diagnostic |
| Problems | `<leader>xx` | Diagnostics list (Trouble) |
| Recent projects | `<leader>fp` | Project switcher |
| Git tool window | `<leader>gg` | lazygit |
| `Alt+Insert` | `<leader>cg` | Generate (constructor, getters, toString, override) |
| Find action / command palette | `<leader>sC` | Every command by name |
| `Ctrl+Alt+S` → Keymap | `<leader>sk` | Search the keymaps |

## Projects

| | |
|---|---|
| `<leader>pn` | New Project (wizard) |
| `:IdeInitHere` | Scaffold into the current folder (a graphical editor style) |
| `<leader>po` | Open Project (scans the configured project roots) |
| `<leader>fp` | Recent projects |
| `<leader>pr` | Restore session for this project |
| `<leader>pd` | Add a dependency to this project |
| `<leader>pk` | This cheatsheet (also `:IdeCheatsheet`) |

The dashboard (bare `nvim`) also has `p` Open Project and `N` New Project.

From the shell, the `kebab` command does the same without starting in the
editor first:

| | |
|---|---|
| `kebab` | open the IDE here, tree showing |
| `kebab open <name>` | open a project by name |
| `kebab new <name> --type spring` | create one without being asked anything |
| `kebab new <n> --type go --module github.com/you/n` | any prompt is `--name value` |
| `kebab types --prompts` | what each type asks you |
| `kebab list` / `kebab types` | what exists / what can be created |
| `kebab doctor` | check the install; non-zero only if something required is missing |

Types: Spring Boot (Maven), Maven (plain), Kotlin (Gradle), Ruby (bundler +
rspec), Flutter, Go module, Rust (cargo), Python (venv + pyproject), Node
(TypeScript *or* JavaScript), Vite (React/Svelte/Vue/Solid, TS *or* JS), Empty.

### Generating code

`<leader>cg`, or `:IdeGenerate <name>`. Needs a language server attached —
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
| `<leader>fN` | New file from a template (`:IdeNewFile`) |
| `<leader>fS` | New scratch file (`:IdeScratch http`, `sql`, `go`, …) |
| `<leader>fs` | Reopen a scratch file |
| `<leader>pf` | Generate a project file (`.gitignore`, Dockerfile, CI, `.editorconfig`) |

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
| `<leader>or` | Run one (`:IdeRunConfig`) |
| `<leader>oe` | Edit them (`:IdeRunConfigEdit`, writes an example first time) |
| `<leader>oo` | Every task, project configurations first |

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

`<leader>pd`, or `:IdeAddDependency <what>`. `:IdeAddDependency!` adds it as a
dev dependency where the ecosystem has the idea.

| In a | Type | and it |
|---|---|---|
| Maven project | `data-jpa` | adds `spring-boot-starter-data-jpa`, no version needed |
| Maven project | `org.flywaydb:flyway-core:10.17.0` | adds it with that version |
| Flutter project | `provider` | runs `flutter pub add provider` |
| Node project | `zod` | runs `npm install zod` |
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
| `<leader>oo` | Run task (Maven, Flutter, Python, npm scripts) |
| `<leader>ow` | Task list |
| `<leader>ot` | Task action (restart, stop, open output) |

Registered automatically when the project matches: `mvn spring-boot:run`,
`mvn test`, `mvn package`, `mvn clean install`, `flutter run/test/pub get/
analyze`, `python <file>`, `pytest`. npm scripts come from `package.json`.
A project's `.vscode/launch.json` is loaded into nvim-dap if present.

## Flutter (in a .dart buffer)

| | |
|---|---|
| `<leader>Fr` / `<leader>Fq` | Run / Quit |
| `<leader>Fh` / `<leader>FR` | Hot reload / Hot restart |
| `<leader>Fd` / `<leader>Fe` | Devices / Emulators |
| `<leader>Fl` / `<leader>Fo` | Dev log / Outline |

## Java tests

The Run menu's test entries dispatch per filetype: `jdtls` in a Java buffer,
neotest everywhere else. neotest has no Java adapter, so a single backend would
report "no tests found" on a file full of them.

jdtls owns these in Java buffers (neotest is not used there):
`<leader>tr` nearest test · `<leader>tt` whole class · `<leader>tT` pick test.

## Project tree & mouse

The tree opens by itself on the left. Mouse is enabled (`mouse=a`).

| | |
|---|---|
| single click a folder | expand / collapse |
| double click a file | open it |
| `Enter` | open file / toggle folder |
| drag the divider | resize the pane |
| `<C-w>>` / `<C-w><` | resize by keyboard |
| `a` / `A` | new file / new folder |
| `r` / `d` | rename / delete |
| `y` / `x` / `p` | copy / cut / paste |
| `H` | toggle hidden files |
| `z` | collapse all |
| `R` | refresh |

Git, on the highlighted file:

| | |
|---|---|
| `ga` / `gu` | stage / unstage |
| `gt` | toggle staged |
| `gr` | revert |
| `gc` / `gp` / `gl` | commit / push / pull |
| `<leader>ge` | git status tree |

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
- **`<leader>M`** — same editor menu from the keyboard
- Inside a menu: `h` / `l` move between levels, `Enter` runs, `q` closes

Each entry shows its keybinding on the right, so the menu doubles as a way to
learn the shortcuts.

## Completion (blink.cmp)

The menu pops up by itself as you type — there is no key to "turn it on".
If nothing appears, the language server has not attached yet; check `:LspInfo`.

| | |
|---|---|
| `<CR>` | Accept the selected item |
| `<C-n>` / `<C-p>` | Next / previous item (arrows work too) |
| `<C-space>` | Force the menu open, then toggle the doc panel |
| `<C-e>` | Dismiss |
| `<C-b>` / `<C-f>` | Scroll the documentation popup |
| `<Tab>` / `<S-Tab>` | Jump between snippet placeholders |
| `<C-k>` | Toggle signature help (parameter hints) |

Documentation auto-opens after 200ms on the highlighted item, and brackets are
inserted automatically when you accept a function.

## Refactoring

| | |
|---|---|
| `<leader>cr` | Rename (live preview) |
| `<leader>cf` | Format buffer |
| `<leader>co` | Organize imports (Java) |
| `<leader>rf` | Extract function |
| `<leader>rF` | Extract function to file |
| `<leader>rx` | Extract variable |
| `<leader>ri` | Inline variable |
| `<leader>rs` | Select refactor (menu) |
| `<leader>cxv` | Extract variable (Java/jdtls) |
| `<leader>cxc` | Extract constant (Java/jdtls) |
| `<leader>cxm` | Extract method (Java, visual mode) |
| `<leader>cgs` | Go to super (Java) |

## Debugging

Note the capitalisation: `dO` steps **over**, `do` steps **out**.

| | |
|---|---|
| `<leader>db` | Toggle breakpoint |
| `<leader>dB` | Conditional breakpoint |
| `<leader>dc` | Run / continue |
| `<leader>dC` | Run to cursor |
| `<leader>dO` | Step over |
| `<leader>di` | Step into |
| `<leader>do` | Step out |
| `<leader>dt` | Terminate |
| `<leader>du` | Toggle debugger UI |
| `<leader>de` | Evaluate expression |
| `<leader>dr` | Toggle REPL |
| `<leader>ds` | Session info |

## Testing

| | |
|---|---|
| `<leader>tr` | Run nearest test |
| `<leader>tt` | Run file |
| `<leader>tT` | Run all test files |
| `<leader>ts` | Toggle summary panel |
| `<leader>to` | Show output |
| `<leader>td` | Debug nearest test |
| `<leader>tw` | Toggle watch mode |
| `<leader>tl` | Run last |

## HTTP client (`.http` scratch files)

Open any `.http` file, then:

| | |
|---|---|
| `<leader>Rs` | Send request |
| `<leader>Rr` | Replay last |
| `<leader>Rb` | Open scratchpad |
| `<leader>Re` | Set environment |
| `<leader>Rc` | Copy as cURL |
| `<leader>RC` | Paste from cURL |
| `<leader>Rt` | Toggle headers / body |

## Database (JDBC)

Drivers come from Maven Central on first use; no native client needed.

| Was | Here | |
|---|---|---|
| Open the database IDE | `kebab db` | from a shell: explorer open, connections on the left |
| Open a table | **double click it** | the select top right, its rows under it |
| Run what you edited | `<leader>S` or `<C-CR>` | in the statement pane; rows refresh below |
| ...on one connection | `kebab db <name>` | straight into a SQL console |
| Database tool window | `<leader>DD` | Explorer |
| New data source | `<leader>Da` | Add a connection, then test it |
| Open a table | `<leader>Dt` | Browse tables, open one |
| New console | `<leader>Dq` | SQL console bound to a connection |
| Attach console to source | `<leader>Dc` | Attach to this buffer |
| Execute | `<leader>S` | Run the statement under the cursor |
| | `<leader>Dp` | Test the connection |
| | `<leader>De` | Edit the connections file |
| | `:IdeDbStatus` | Connections, and warm processes |
| | `:IdeDbDisconnect` | Close the warm processes |

The first query on a connection costs about 180ms while the driver loads; every
one after it about 0.2ms, because the process is kept open.

Completion in a SQL buffer with a connection attached: tables, `customers.` →
its columns with types, and aliases. `<leader>Dq` attaches for you; in a plain
`.sql` file use `<leader>Dc` first, or completion has nothing to go on.

Note `<leader>d*` is the **debugger**, so the database namespace is the shifted
`<leader>D*`.

## Older notes on the SQL story

`<leader>D` — toggle DBUI. Add connections inside it; completion works in `.sql` buffers.

## Python

`<leader>cv` — select virtualenv. Do this first in a Python project or basedpyright
will resolve against the system interpreter instead of your venv.

## Claude Code

| | |
|---|---|
| `<leader>ac` | Toggle Claude |
| `<leader>af` | Focus Claude |
| `<leader>ar` | Resume session |
| `<leader>ab` | Add current buffer to context |
| `<leader>as` | Send selection (visual mode) |
| `<leader>aa` / `<leader>ad` | Accept / deny diff |

## Following edits made outside the editor

**On by default.** `<leader>uf` or `:IdeFollow` turns it off for the session.

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

`<leader>uf` turns it off, and a stop you asked for sticks — it will not restart
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
| `<C-/>` or `<leader>ft` | floating terminal, at the project root |
| `<leader>fT` | the same, in the current file's directory |

`%` expands to the current file, so `:!python3 %` runs what you are looking at,
and `:!kebab doctor` works because the command is on your PATH. Inside a
terminal buffer, `<C-\><C-n>` returns you to normal mode so you can scroll and
copy; `i` goes back to typing.

For anything you run more than once, put it in `.kebab/run.json` instead
(`<leader>or`) so it becomes a task with a name, output pane and exit code,
rather than a line you retype.

## Asking the editor questions from a shell

Read-only, and meant for a script or an AI agent as much as for you.

| | |
|---|---|
| `kebab diagnostics <file>` | errors and warnings from the language server |
| `kebab definition <file>:<line>:<col>` | where that symbol is defined |
| `kebab references <file>:<line>:<col>` | everywhere it is used |
| `kebab symbols <file>` | the outline of a file |
| `kebab hover <file>:<line>:<col>` | its type and docs |

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

`kebab doctor` from a shell, or `<leader>pD` / `:IdeDoctor` in the editor.

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
