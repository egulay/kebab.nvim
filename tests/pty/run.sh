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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
