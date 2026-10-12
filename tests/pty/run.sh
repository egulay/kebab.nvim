#!/usr/bin/env bash
# Mouse behaviour, in a real terminal. See README.md -- this is not part of
# ./tests/run.sh because each case boots an editor and talks to a database.
set -uo pipefail
# $0 may be a copy somewhere else: a run that edits these files while they are
# executing re-reads a script from a byte offset and dies mid-line ("syntax
# error near unexpected token"), which cost a run and looked like a product
# failure. KEBAB_PTY_DIR lets a copy of this script keep using the real
# directory for drive.py and targets.lua.
here=${KEBAB_PTY_DIR:-$(cd "$(dirname "$0")" && pwd)}
root=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
pass=0

# The database the cases need. A throwaway SQLite file, so nothing here
# depends on a server being up or on anyone's credentials.
db="$work/shop.sqlite"
# One table, three rows. Both halves matter:
#
#   one table   -- these cases click at absolute rows in the tree, so adding a
#                  second table shifted every node below it and broke five
#                  cases that had nothing to do with the change.
#   three rows  -- with one row there is no next page, so Next correctly
#                  refuses to move and the click case fails looking like a
#                  broken button.
sqlite3 "$db" "CREATE TABLE customers (id INTEGER PRIMARY KEY, full_name TEXT);
               INSERT INTO customers (full_name)
                 VALUES ('Ada Lovelace'),('Alan Turing'),('Grace Hopper');" || exit 1

export KEBAB_DB_STORE="$work/connections.json"
cat > "$KEBAB_DB_STORE" <<JSON
{ "connections": [ { "name": "shop", "url": "jdbc:sqlite:$db" } ] }
JSON

cat > "$work/child.lua" <<'LUA'
-- Ghost Mode follows files changed outside the editor -- including this repo,
-- if anything is editing it while the suite runs. Measured: a statement pane
-- holding kebab/cli.lua, a CHEATSHEET.md in another, two noice floats and the
-- ghost badge, and three cases failing for a window count. tests/run.lua pins
-- this off for the headless suite; the pty one needs it just as much.
vim.g.kebab_follow_autostart = false
vim.g.kebab_db_store = vim.env.KEBAB_DB_STORE
vim.g.kebab_db_sql_dir = vim.env.WORK .. "/sql"
-- tell the driver where things are, so clicks are aimed and not guessed
package.path = vim.env.HERE .. "/?.lua;" .. package.path
require("targets").publish(vim.env.TARGETS)
require("kebab.cli").db("")
vim.defer_fn(function()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    local pos = vim.api.nvim_win_get_position(w)
    out[#out + 1] = ("win row=%d col=%d ft=%s"):format(pos[1], pos[2], vim.bo[b].filetype)
    if vim.b[b].kebab_db_editor then
      out[#out + 1] = "STATEMENT " .. table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), " / ")
    end
    if vim.b[b].kebab_db_output then
      out[#out + 1] = "ROWS " .. table.concat(vim.api.nvim_buf_get_lines(b, 0, 10, false), " / ")
    end
    if vim.bo[b].filetype == "dbui" then
      out[#out + 1] = "TREE " .. table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), " / ")
    end
  end
  vim.fn.writefile(out, vim.env.REPORT)
  vim.cmd("qa!")
end, tonumber(vim.env.REPORT_AFTER) or 30000)
LUA

check() { # name pattern file           -- or: name -v file pattern (must NOT match)
  local ok
  if [ "$2" = "-v" ]; then
    grep -q "$4" "$3" 2>/dev/null && ok=1 || ok=0
    if [ "$ok" -eq 0 ]; then
      printf '  ok   %s\n' "$1"; pass=$((pass + 1)); return
    fi
    printf '  FAIL %s\n' "$1"; printf '       did not want /%s/ in:\n' "$4"
    sed 's/^/       | /' "$3"; fail=$((fail + 1)); return
  fi
  if grep -q "$2" "$3" 2>/dev/null; then
    printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL %s\n' "$1"; printf '       wanted /%s/ in:\n' "$2"; sed 's/^/       | /' "$3"; fail=$((fail + 1))
  fi
}

run_case() { # json
  rm -f "$work/report.txt"
  WORK="$work" HERE="$here" TARGETS="$work/targets" REPORT_AFTER="$1" \
    python3 -I "$here/drive.py" "$work/case.json" >/dev/null
}

printf 'mouse tests (a real terminal, real mouse reports)\n\n'

# --- a double click on a connection expands it -----------------------------
cat > "$work/case.json" <<JSON
{ "nvim_args": ["-n", "-c", "luafile $work/child.lua"],
  "actions": [ {"kind":"wait","seconds":10}, {"kind":"click_target","name":"connection","file":"$work/targets","count":2},
               {"kind":"wait","seconds":8} ],
  "report": "$work/report.txt", "idle": 2, "limit": 90 }
JSON
run_case 26000
check "a double click expands a connection" "Tables (1)" "$work/report.txt"

# --- a double click on a table opens it in the three panes -----------------
cat > "$work/case.json" <<JSON
{ "nvim_args": ["-n", "-c", "luafile $work/child.lua"],
  "actions": [ {"kind":"wait","seconds":10}, {"kind":"click_target","name":"connection","file":"$work/targets","count":2},
               {"kind":"wait","seconds":6},  {"kind":"click_target","name":"tables","file":"$work/targets","count":2},
               {"kind":"wait","seconds":6},  {"kind":"click_target","name":"table","file":"$work/targets","count":2},
               {"kind":"wait","seconds":10} ],
  "report": "$work/report.txt", "idle": 2, "limit": 120 }
JSON
run_case 42000
check "a double click on a table writes the select" "STATEMENT.*select .* from" "$work/report.txt"
check "the pager says where you are"                 "ROWS.*rows 1-3"          "$work/report.txt"
check "and shows its rows"                          "ROWS.*Ada Lovelace"       "$work/report.txt"
check "with the rows pane below the statement"       "^win row=[1-9].*dbout"    "$work/report.txt"

# --- the right-click menu, which only a real terminal can open -------------
#
# Reported as "there is nothing on right click menu" and "no re-run on right
# click or anywhere else". The menu renders as *virtual text* in a floating
# window, so reading its buffer lines shows blanks; what is asserted here is
# the composited screen, cell by cell, which is what the terminal draws.
cat > "$work/menuchild.lua" <<'LUA'
-- Ghost Mode follows files changed outside the editor -- including this repo,
-- if anything is editing it while the suite runs. Measured: a statement pane
-- holding kebab/cli.lua, a CHEATSHEET.md in another, two noice floats and the
-- ghost badge, and three cases failing for a window count. tests/run.lua pins
-- this off for the headless suite; the pty one needs it just as much.
vim.g.kebab_follow_autostart = false
vim.g.kebab_db_store = vim.env.KEBAB_DB_STORE
vim.g.kebab_db_sql_dir = vim.env.WORK .. "/sql"
-- tell the driver where things are, so clicks are aimed and not guessed
package.path = vim.env.HERE .. "/?.lua;" .. package.path
require("targets").publish(vim.env.TARGETS)
require("kebab.cli").db("")
-- Not a fixed delay: db mode's setup is scheduled and tears down windows
-- twice on the way, so a table opened too early is opened into a layout that
-- is about to be rebuilt. @see targets.when
require("targets").when(function()
  local I = require("kebab.dbide")
  return I.tree_win() ~= nil and require("kebab.db").connection("shop") ~= nil
end, function()
  require("kebab.dbide").open_table(require("kebab.db").connection("shop"), "customers")
end)
vim.defer_fn(function()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= "" then
      local pos = vim.api.nvim_win_get_position(w)
      for r = pos[1] + 1, pos[1] + vim.api.nvim_win_get_height(w) do
        local cells = {}
        for c = pos[2] + 1, pos[2] + vim.api.nvim_win_get_width(w) do
          cells[#cells + 1] = vim.fn.screenstring(r, c)
        end
        out[#out + 1] = "SCREEN " .. table.concat(cells)
      end
    end
  end
  if #out == 0 then out[1] = "no menu opened" end
  vim.fn.writefile(out, vim.env.REPORT)
  vim.cmd("qa!")
end, tonumber(vim.env.REPORT_AFTER) or 26000)
LUA
cat > "$work/case.json" <<JSON
{ "nvim_args": ["-n", "-c", "luafile $work/menuchild.lua"],
  "actions": [ {"kind":"wait","seconds":16},
               {"kind":"click_target","name":"statement","file":"$work/targets","button":2},
               {"kind":"wait","seconds":8} ],
  "report": "$work/report.txt", "idle": 2, "limit": 90 }
JSON
rm -f "$work/report.txt"
WORK="$work" HERE="$here" TARGETS="$work/targets" REPORT_AFTER=26000 python3 -I "$here/drive.py" "$work/case.json" >/dev/null
check "a right click in the statement pane opens a menu" "SCREEN" "$work/report.txt"
check "with Run Statement at the top of it"              "SCREEN.*Run Statement" "$work/report.txt"
check "and its shortcut beside it"                       "Run Statement.*Ctrl+Enter" "$work/report.txt"
check "the rows pager is in there"                       "SCREEN.*Rows" "$work/report.txt"

# --- clicking a menu row actually runs it ----------------------------------
#
# The sweeps prove every entry points at something real, and
# menu_behaviour_spec proves invoking that target has the effect it claims.
# Neither proves that *clicking the row* dispatches to it -- which is the link
# this layer has twice been wrong about. So: open a table, replace the
# statement with something unmistakable, right-click, click "Run Statement",
# and look for the result in the rows pane.
cat > "$work/clickchild.lua" <<'LUA'
-- Ghost Mode follows files changed outside the editor -- including this repo,
-- if anything is editing it while the suite runs. Measured: a statement pane
-- holding kebab/cli.lua, a CHEATSHEET.md in another, two noice floats and the
-- ghost badge, and three cases failing for a window count. tests/run.lua pins
-- this off for the headless suite; the pty one needs it just as much.
vim.g.kebab_follow_autostart = false
vim.g.kebab_db_store = vim.env.KEBAB_DB_STORE
vim.g.kebab_db_sql_dir = vim.env.WORK .. "/sql"
-- tell the driver where things are, so clicks are aimed and not guessed
package.path = vim.env.HERE .. "/?.lua;" .. package.path
require("targets").publish(vim.env.TARGETS)
require("kebab.cli").db("")
-- Not a fixed delay: db mode's setup is scheduled and tears down windows
-- twice on the way, so a table opened too early is opened into a layout that
-- is about to be rebuilt. @see targets.when
require("targets").when(function()
  local I = require("kebab.dbide")
  return I.tree_win() ~= nil and require("kebab.db").connection("shop") ~= nil
end, function()
  require("kebab.dbide").open_table(require("kebab.db").connection("shop"), "customers")
end)
vim.defer_fn(function()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.b[b].kebab_db_editor then
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "select 'clicked-the-menu' as proof" })
    end
  end
end, 14000)
vim.defer_fn(function()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.b[b].kebab_db_output then
      out[#out + 1] = "ROWS " .. table.concat(vim.api.nvim_buf_get_lines(b, 0, 8, false), " | ")
    end
  end
  if #out == 0 then out[1] = "no rows pane" end
  vim.fn.writefile(out, vim.env.REPORT)
  vim.cmd("qa!")
end, tonumber(vim.env.REPORT_AFTER) or 34000)
LUA
cat > "$work/case.json" <<JSON
{ "nvim_args": ["-n", "-c", "luafile $work/clickchild.lua"],
  "actions": [ {"kind":"wait","seconds":17},
               {"kind":"click_target","name":"statement","file":"$work/targets","button":2},
               {"kind":"wait","seconds":4},
               {"kind":"click_target","name":"menu_run_statement","file":"$work/targets"},
               {"kind":"wait","seconds":10} ],
  "report": "$work/report.txt", "idle": 2, "limit": 110 }
JSON
rm -f "$work/report.txt"
WORK="$work" HERE="$here" TARGETS="$work/targets" REPORT_AFTER=34000 python3 -I "$here/drive.py" "$work/case.json" >/dev/null
check "clicking a menu row runs that entry" "clicked-the-menu" "$work/report.txt"

# --- the layout survives a session that already had windows ----------------
#
# Reported as "UI is broken completely when I clicked to the tabs on the top on
# db mode", after creating a new query. With two files already open the layout
# came out as five windows: the data source tree gone, the statement pane open
# twice, the file tree back, and a leftover code window five columns wide --
# then clicking a tab loaded a Go file into the tree's window. None of it is
# visible without a real terminal: window geometry needs a UI, and the tab bar
# hides itself until two buffers are listed.
printf 'package main\nfunc main() {}\n' > "$work/a.go"
printf 'package main\nfunc other() {}\n' > "$work/b.go"
cat > "$work/tabchild.lua" <<'LUA'
-- Ghost Mode follows files changed outside the editor -- including this repo,
-- if anything is editing it while the suite runs. Measured: a statement pane
-- holding kebab/cli.lua, a CHEATSHEET.md in another, two noice floats and the
-- ghost badge, and three cases failing for a window count. tests/run.lua pins
-- this off for the headless suite; the pty one needs it just as much.
vim.g.kebab_follow_autostart = false
vim.g.kebab_db_store = vim.env.KEBAB_DB_STORE
vim.g.kebab_db_sql_dir = vim.env.WORK .. "/sql"
-- tell the driver where things are, so clicks are aimed and not guessed
package.path = vim.env.HERE .. "/?.lua;" .. package.path
require("targets").publish(vim.env.TARGETS)
vim.cmd("edit " .. vim.env.WORK .. "/a.go")
vim.cmd("edit " .. vim.env.WORK .. "/b.go")
require("kebab.cli").db("")
-- Not a fixed delay: db mode's setup is scheduled and tears down windows
-- twice on the way, so a table opened too early is opened into a layout that
-- is about to be rebuilt. @see targets.when
require("targets").when(function()
  local I = require("kebab.dbide")
  return I.tree_win() ~= nil and require("kebab.db").connection("shop") ~= nil
end, function()
  require("kebab.dbide").open_table(require("kebab.db").connection("shop"), "customers")
end)
vim.defer_fn(function()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    local pos = vim.api.nvim_win_get_position(w)
    -- the buffer's name as well as its filetype: a run that failed with
    -- `ft=markdown` where the statement pane belongs left no way to tell
    -- which file had ended up there
    out[#out + 1] = ("WIN row=%d col=%d ft=%s fixbuf=%s name=%s"):format(pos[1], pos[2],
      vim.bo[b].filetype, tostring(vim.wo[w].winfixbuf),
      vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t"))
  end
  out[#out + 1] = "COUNT " .. #vim.api.nvim_list_wins()
  vim.fn.writefile(out, vim.env.REPORT)
  vim.cmd("qa!")
end, tonumber(vim.env.REPORT_AFTER) or 30000)
LUA
cat > "$work/case.json" <<JSON
{ "nvim_args": ["-n", "-c", "luafile $work/tabchild.lua"],
  "actions": [ {"kind":"wait","seconds":17},
               {"kind":"click_target","name":"tab_a.go","file":"$work/targets"},
               {"kind":"wait","seconds":7} ],
  "report": "$work/report.txt", "idle": 2, "limit": 110 }
JSON
rm -f "$work/report.txt"
WORK="$work" HERE="$here" TARGETS="$work/targets" REPORT_AFTER=30000 python3 -I "$here/drive.py" "$work/case.json" >/dev/null
check "db mode leaves exactly three windows"   "COUNT 3"              "$work/report.txt"
check "the file tree is not one of them"       -v                     "$work/report.txt" "neo-tree"
check "the explorer window is pinned"          "ft=dbui fixbuf=true"  "$work/report.txt"
check "the rows window is pinned"              "ft=dbout fixbuf=true" "$work/report.txt"
# The reported bug, and the reason this case clicks a tab at all: the file
# went into the *tree's* window. So what matters afterwards is that a.go is in
# the statement column (36, beside the tree at 0) and that the window took it,
# i.e. is not pinned. This used to assert the statement pane still held its
# .sql -- which was only ever true because the case's clicks were silently not
# happening: it aimed at a tree node that needs a connection expanded first,
# the target never appeared, and the driver gave up before the tab click.
check "clicking a tab loads the file beside the tree, not into it" \
  "col=36 ft=go fixbuf=false name=a.go" "$work/report.txt"

# --- no files open: the splash screen must not survive ---------------------
#
# Reported as "lazyvim splash always there", "shortcuts are not working at
# all" and `Space S` opening something else -- all one fault. With no files
# open, `:only` keeps the window holding the dashboard, the statement pane
# refuses to reuse a special buffer, and so the splash sat in the layout
# keeping its own keymaps. Anything typed while focused there went to the
# dashboard. Four cases above this one failed on it too, and the suite's own
# exit code was masked by piping it through `tail`.
cat > "$work/splashchild.lua" <<'LUA'
-- Ghost Mode follows files changed outside the editor -- including this repo,
-- if anything is editing it while the suite runs. Measured: a statement pane
-- holding kebab/cli.lua, a CHEATSHEET.md in another, two noice floats and the
-- ghost badge, and three cases failing for a window count. tests/run.lua pins
-- this off for the headless suite; the pty one needs it just as much.
vim.g.kebab_follow_autostart = false
vim.g.kebab_db_store = vim.env.KEBAB_DB_STORE
vim.g.kebab_db_sql_dir = vim.env.WORK .. "/sql"
-- tell the driver where things are, so clicks are aimed and not guessed
package.path = vim.env.HERE .. "/?.lua;" .. package.path
require("targets").publish(vim.env.TARGETS)
require("kebab.cli").db("")
-- Not a fixed delay: db mode's setup is scheduled and tears down windows
-- twice on the way, so a table opened too early is opened into a layout that
-- is about to be rebuilt. @see targets.when
require("targets").when(function()
  local I = require("kebab.dbide")
  return I.tree_win() ~= nil and require("kebab.db").connection("shop") ~= nil
end, function()
  require("kebab.dbide").open_table(require("kebab.db").connection("shop"), "customers")
end)
vim.defer_fn(function()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    out[#out + 1] = ("WIN ft=%s buftype=%s"):format(vim.bo[b].filetype, vim.bo[b].buftype)
  end
  out[#out + 1] = "COUNT " .. #vim.api.nvim_list_wins()
  -- and the keys that must work in both panes
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.b[b].kebab_db_editor or vim.b[b].kebab_db_output then
      local lhs = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
        lhs[#lhs + 1] = m.lhs
      end
      out[#out + 1] = ("KEYS %s %s"):format(
        vim.b[b].kebab_db_editor and "statement" or "rows", table.concat(lhs, " "))
    end
  end
  vim.fn.writefile(out, vim.env.REPORT)
  vim.cmd("qa!")
end, tonumber(vim.env.REPORT_AFTER) or 28000)
LUA
cat > "$work/case.json" <<JSON
{ "nvim_args": ["-n", "-c", "luafile $work/splashchild.lua"],
  "actions": [ {"kind":"wait","seconds":22} ],
  "report": "$work/report.txt", "idle": 2, "limit": 90 }
JSON
rm -f "$work/report.txt"
WORK="$work" HERE="$here" TARGETS="$work/targets" REPORT_AFTER=28000 python3 -I "$here/drive.py" "$work/case.json" >/dev/null
check "with no files open, there is no splash screen" -v "$work/report.txt" "dashboard\|alpha\|starter"
check "and still exactly three windows"              "COUNT 3"                "$work/report.txt"
check "Run is bound on the statement pane"           "KEYS statement.*C-CR"   "$work/report.txt"
check "Run is bound on the rows pane too"            "KEYS rows.*C-CR"        "$work/report.txt"

# --- the pager bar is clickable --------------------------------------------
#
# "WHICH COMBINATION AS A HUMAN BEING I SHOULD PRESS TO EXECUTE NEXT OR
# PREVIOUS PAGE?" -- a fair question about a three-keystroke leader sequence.
# The bar reads "[ n next ]  [ p prev ]" and both the letter and a click work.
# Only a real terminal can be clicked.
cat > "$work/barchild.lua" <<'LUA'
-- Ghost Mode follows files changed outside the editor -- including this repo,
-- if anything is editing it while the suite runs. Measured: a statement pane
-- holding kebab/cli.lua, a CHEATSHEET.md in another, two noice floats and the
-- ghost badge, and three cases failing for a window count. tests/run.lua pins
-- this off for the headless suite; the pty one needs it just as much.
vim.g.kebab_follow_autostart = false
vim.g.kebab_db_store = vim.env.KEBAB_DB_STORE
vim.g.kebab_db_sql_dir = vim.env.WORK .. "/sql"
-- tell the driver where things are, so clicks are aimed and not guessed
package.path = vim.env.HERE .. "/?.lua;" .. package.path
require("targets").publish(vim.env.TARGETS)
vim.g.kebab_db_page_size = 1
require("kebab.cli").db("")
-- Not a fixed delay: db mode's setup is scheduled and tears down windows
-- twice on the way, so a table opened too early is opened into a layout that
-- is about to be rebuilt. @see targets.when
require("targets").when(function()
  local I = require("kebab.dbide")
  return I.tree_win() ~= nil and require("kebab.db").connection("shop") ~= nil
end, function()
  require("kebab.dbide").open_table(require("kebab.db").connection("shop"), "customers")
end)
vim.defer_fn(function()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.b[b].kebab_db_output then
      local pos = vim.api.nvim_win_get_position(w)
      out[#out + 1] = ("ROWSWIN row=%d col=%d"):format(pos[1], pos[2])
      for i, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, 2, false)) do
        out[#out + 1] = ("LINE%d %s"):format(i, line)
      end
    end
  end
  vim.fn.writefile(out, vim.env.REPORT)
  vim.cmd("qa!")
end, tonumber(vim.env.REPORT_AFTER) or 30000)
LUA
cat > "$work/case.json" <<JSON
{ "nvim_args": ["-n", "-c", "luafile $work/barchild.lua"],
  "actions": [ {"kind":"wait","seconds":17},
               {"kind":"click_target","name":"button_n","file":"$work/targets"},
               {"kind":"wait","seconds":8} ],
  "report": "$work/report.txt", "idle": 2, "limit": 100 }
JSON
rm -f "$work/report.txt"
WORK="$work" HERE="$here" TARGETS="$work/targets" REPORT_AFTER=30000 python3 -I "$here/drive.py" "$work/case.json" >/dev/null
check "the rows pane shows a button bar"      "LINE2 -- \[ n"          "$work/report.txt"
check "clicking [ n next ] turns the page"    "LINE1.*page 2"           "$work/report.txt"

# --- a project made entirely through the UI, no code -----------------------
#
# Asked for directly: "did you try to create projects from scratch? to test
# built in wizards (such as spring boot) not asking via its code but via some
# UX elements or shortcuts".
#
# The headless suite calls project.create() with its answers as data, and
# scripts vim.ui.select/input for the wizard -- which exercises the wizard's
# logic but never the picker a user actually types into. This case touches
# nothing but the mouse and the keyboard: right-click, Project, New Project...,
# then type into the real pickers, and then look on disk for a Spring Boot
# project that nobody asked for in Lua.
mkdir -p "$work/projects"
cat > "$work/wizchild.lua" <<'LUA'
-- Ghost Mode follows files changed outside the editor -- including this repo,
-- if anything is editing it while the suite runs. Measured: a statement pane
-- holding kebab/cli.lua, a CHEATSHEET.md in another, two noice floats and the
-- ghost badge, and three cases failing for a window count. tests/run.lua pins
-- this off for the headless suite; the pty one needs it just as much.
vim.g.kebab_follow_autostart = false
package.path = vim.env.HERE .. "/?.lua;" .. package.path
require("targets").publish(vim.env.TARGETS)
-- The wizard offers the first configured project root. Pointing it at the
-- sandbox is what keeps a test run out of the real ~/Projects.
vim.g.kebab_project_roots = { vim.env.WORK .. "/projects" }
vim.defer_fn(function()
  local dest = vim.env.WORK .. "/projects/sample-app"
  local out = {}
  for _, rel in ipairs({ "pom.xml", "mvnw", "src/main/java" }) do
    out[#out + 1] = ("FILE %s %s"):format(rel, vim.uv.fs_stat(dest .. "/" .. rel) and "yes" or "no")
  end
  local pom = ""
  if vim.fn.filereadable(dest .. "/pom.xml") == 1 then
    pom = table.concat(vim.fn.readfile(dest .. "/pom.xml"), " ")
  end
  out[#out + 1] = "POM " .. (pom:find("spring%-boot%-starter%-parent") and "spring-boot-parent" or "none")
  out[#out + 1] = "ARTIFACT " .. (pom:find("<artifactId>sample%-app</artifactId>") and "sample-app" or "?")
  out[#out + 1] = "STARTER " .. (pom:find("spring%-boot%-starter%-web") and "web" or "none")
  local java = vim.fn.globpath(dest, "**/*.java", false, true)
  out[#out + 1] = ("JAVA %d %s"):format(#java, vim.fn.fnamemodify(java[1] or "", ":t"))
  out[#out + 1] = "CWD " .. vim.fn.getcwd()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name:find("sample%-app") then
      out[#out + 1] = "BUF " .. name
    end
  end
  vim.fn.writefile(out, vim.env.REPORT)
  vim.cmd("qa!")
end, tonumber(vim.env.REPORT_AFTER) or 95000)
LUA
cat > "$work/case.json" <<JSON
{ "nvim_args": ["-n", "-c", "luafile $work/wizchild.lua"],
  "actions": [ {"kind":"wait","seconds":12},
               {"kind":"click_target","name":"editor_area","file":"$work/targets","button":2},
               {"kind":"wait","seconds":4},
               {"kind":"click_target","name":"menu_project","file":"$work/targets"},
               {"kind":"wait","seconds":3},
               {"kind":"click_target","name":"menu_new_project","file":"$work/targets"},
               {"kind":"wait","seconds":4},
               {"kind":"keys","text":"Spring"},
               {"kind":"wait","seconds":3},
               {"kind":"keys","text":"\\r"},
               {"kind":"wait","seconds":3},
               {"kind":"keys","text":"sample-app\\r"},
               {"kind":"wait","seconds":3},
               {"kind":"keys","text":"\\r"},
               {"kind":"wait","seconds":3},
               {"kind":"keys","text":"\\r"},
               {"kind":"wait","seconds":2},
               {"kind":"keys","text":"\\r"},
               {"kind":"wait","seconds":30} ],
  "report": "$work/report.txt", "idle": 2, "limit": 170 }
JSON
rm -f "$work/report.txt"
WORK="$work" HERE="$here" TARGETS="$work/targets" REPORT_AFTER=95000 python3 -I "$here/drive.py" "$work/case.json" >/dev/null
check "the wizard, driven by mouse and keyboard, writes a pom" "FILE pom.xml yes"        "$work/report.txt"
check "it is a Spring Boot project"                            "POM spring-boot-parent"  "$work/report.txt"
check "named after what was typed"                             "ARTIFACT sample-app"     "$work/report.txt"
check "with the dependency the wizard offered"                 "STARTER web"             "$work/report.txt"
check "and a Java source file in it"                           "JAVA [1-9]"              "$work/report.txt"
check "the editor moved into the new project"                  "CWD .*projects/sample-app" "$work/report.txt"

# --- a double click on an image goes to the desktop, not into a buffer ----
#
# Asked for directly: "when user double click some image files or pdf or any
# other file which is not text based to open via nvim could you please make the
# OS open it with its default app". A unit test can prove the decision; only a
# real double click in a real tree proves the mapping, neo-tree's command
# merge and the autocmd all line up -- and the control half of this case (a
# text file, double clicked the same way) is what shows the test can tell the
# two apart rather than just never opening anything.
#
# No image viewer is launched: vim.g.kebab_open_external.command points at a
# script that appends its argument to a file.
mkdir -p "$work/tree"
printf '\211PNG\r\n\032\n\000\000\000binary' > "$work/tree/logo.png"
printf 'plain text\n' > "$work/tree/notes.txt"
cat > "$work/opener.sh" <<'OPENER'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$WORK/opened.log"
OPENER
chmod +x "$work/opener.sh"
cat > "$work/extchild.lua" <<'LUA'
vim.g.kebab_follow_autostart = false
package.path = vim.env.HERE .. "/?.lua;" .. package.path
require("targets").publish(vim.env.TARGETS)
vim.g.kebab_open_external = { command = { vim.env.WORK .. "/opener.sh" } }
vim.defer_fn(function()
  local out = {}
  local log = vim.env.WORK .. "/opened.log"
  if vim.fn.filereadable(log) == 1 then
    for _, line in ipairs(vim.fn.readfile(log)) do
      out[#out + 1] = "OPENED " .. vim.fn.fnamemodify(line, ":t")
    end
  else
    out[#out + 1] = "OPENED (nothing)"
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name ~= "" and vim.api.nvim_buf_is_loaded(b) then
      out[#out + 1] = ("BUF %s lines=%d"):format(vim.fn.fnamemodify(name, ":t"),
        #vim.api.nvim_buf_get_lines(b, 0, -1, false))
    end
  end
  vim.fn.writefile(out, vim.env.REPORT)
  vim.cmd("qa!")
end, tonumber(vim.env.REPORT_AFTER) or 40000)
LUA
cat > "$work/case.json" <<JSON
{ "nvim_args": ["-n", "$work/tree", "-c", "luafile $work/extchild.lua"],
  "actions": [ {"kind":"wait","seconds":12},
               {"kind":"click_target","name":"tree_logo_png","file":"$work/targets","count":2},
               {"kind":"wait","seconds":6},
               {"kind":"click_target","name":"tree_notes_txt","file":"$work/targets","count":2},
               {"kind":"wait","seconds":6} ],
  "report": "$work/report.txt", "idle": 2, "limit": 110 }
JSON
rm -f "$work/report.txt" "$work/opened.log"
KEBAB_PTY_TREE_FILES="logo.png notes.txt" WORK="$work" HERE="$here" TARGETS="$work/targets" \
  REPORT_AFTER=40000 python3 -I "$here/drive.py" "$work/case.json" >/dev/null
check "a double click on a PNG hands it to the desktop" "OPENED logo.png"  "$work/report.txt"
check "and does not open it in a buffer"                -v                "$work/report.txt" "BUF logo.png"
check "a double click on a text file still opens it"    "BUF notes.txt"   "$work/report.txt"
check "and that one is not sent to the desktop"         -v                "$work/report.txt" "OPENED notes.txt"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
