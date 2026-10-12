#!/usr/bin/env bash
# Mouse behaviour, in a real terminal. See README.md -- this is not part of
# ./tests/run.sh because each case boots an editor and talks to a database.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
pass=0

# The database the cases need. A throwaway SQLite file, so nothing here
# depends on a server being up or on anyone's credentials.
db="$work/shop.sqlite"
sqlite3 "$db" "CREATE TABLE customers (id INTEGER PRIMARY KEY, full_name TEXT);
               INSERT INTO customers (full_name) VALUES ('Ada Lovelace');" || exit 1

export KEBAB_DB_STORE="$work/connections.json"
cat > "$KEBAB_DB_STORE" <<JSON
{ "connections": [ { "name": "shop", "url": "jdbc:sqlite:$db" } ] }
JSON

cat > "$work/child.lua" <<'LUA'
vim.g.kebab_db_store = vim.env.KEBAB_DB_STORE
vim.g.kebab_db_sql_dir = vim.env.WORK .. "/sql"
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

check() { # name pattern file
  if grep -q "$2" "$3" 2>/dev/null; then
    printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL %s\n' "$1"; printf '       wanted /%s/ in:\n' "$2"; sed 's/^/       | /' "$3"; fail=$((fail + 1))
  fi
}

run_case() { # json
  rm -f "$work/report.txt"
  WORK="$work" REPORT_AFTER="$1" python3 -I "$here/drive.py" "$work/case.json" >/dev/null
}

printf 'mouse tests (a real terminal, real mouse reports)\n\n'

# --- a double click on a connection expands it -----------------------------
cat > "$work/case.json" <<JSON
{ "nvim_args": ["-n", "-c", "luafile $work/child.lua"],
  "actions": [ {"kind":"wait","seconds":10}, {"kind":"click","col":6,"row":3,"count":2},
               {"kind":"wait","seconds":8} ],
  "report": "$work/report.txt", "idle": 2, "limit": 90 }
JSON
run_case 26000
check "a double click expands a connection" "Tables (1)" "$work/report.txt"

# --- a double click on a table opens it in the three panes -----------------
cat > "$work/case.json" <<JSON
{ "nvim_args": ["-n", "-c", "luafile $work/child.lua"],
  "actions": [ {"kind":"wait","seconds":10}, {"kind":"click","col":6,"row":3,"count":2},
               {"kind":"wait","seconds":6},  {"kind":"click","col":8,"row":6,"count":2},
               {"kind":"wait","seconds":6},  {"kind":"click","col":12,"row":7,"count":2},
               {"kind":"wait","seconds":10} ],
  "report": "$work/report.txt", "idle": 2, "limit": 120 }
JSON
run_case 42000
check "a double click on a table writes the select" "STATEMENT.*select .* from" "$work/report.txt"
check "the pager says where you are"                 "ROWS.*rows 1-1 of 1"     "$work/report.txt"
check "and shows its rows"                          "ROWS.*Ada Lovelace"       "$work/report.txt"
check "with the rows pane below the statement"       "^win row=[1-9].*dbout"    "$work/report.txt"

# --- the right-click menu, which only a real terminal can open -------------
#
# Reported as "there is nothing on right click menu" and "no re-run on right
# click or anywhere else". The menu renders as *virtual text* in a floating
# window, so reading its buffer lines shows blanks; what is asserted here is
# the composited screen, cell by cell, which is what the terminal draws.
cat > "$work/menuchild.lua" <<'LUA'
vim.g.kebab_db_store = vim.env.KEBAB_DB_STORE
vim.g.kebab_db_sql_dir = vim.env.WORK .. "/sql"
require("kebab.cli").db("")
vim.defer_fn(function()
  require("kebab.dbide").open_table(require("kebab.db").connection("shop"), "customers")
end, 7000)
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
               {"kind":"click","col":60,"row":3,"button":2,"count":1},
               {"kind":"wait","seconds":8} ],
  "report": "$work/report.txt", "idle": 2, "limit": 90 }
JSON
rm -f "$work/report.txt"
WORK="$work" REPORT_AFTER=26000 python3 -I "$here/drive.py" "$work/case.json" >/dev/null
check "a right click in the statement pane opens a menu" "SCREEN" "$work/report.txt"
check "with Run Statement at the top of it"              "SCREEN.*Run Statement" "$work/report.txt"
check "and its shortcut beside it"                       "Run Statement.*leader>S" "$work/report.txt"
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
vim.g.kebab_db_store = vim.env.KEBAB_DB_STORE
vim.g.kebab_db_sql_dir = vim.env.WORK .. "/sql"
require("kebab.cli").db("")
vim.defer_fn(function()
  require("kebab.dbide").open_table(require("kebab.db").connection("shop"), "customers")
end, 7000)
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
               {"kind":"click","col":60,"row":3,"button":2,"count":1},
               {"kind":"wait","seconds":4},
               {"kind":"click","col":50,"row":5,"button":0,"count":1},
               {"kind":"wait","seconds":10} ],
  "report": "$work/report.txt", "idle": 2, "limit": 110 }
JSON
rm -f "$work/report.txt"
WORK="$work" REPORT_AFTER=34000 python3 -I "$here/drive.py" "$work/case.json" >/dev/null
check "clicking a menu row runs that entry" "clicked-the-menu" "$work/report.txt"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
