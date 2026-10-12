-- The three-pane SQL IDE: tree left, the statement top right, its rows under
-- it, opened by double clicking a table.
--
-- The bug this covers: dadbod-ui has no mouse support at all, and its own
-- action on a table expands it into a "List" child you then have to click. So
-- "double click a table and see its data", which is what anyone arriving from
-- a graphical database IDE does first, did nothing at all.
local H = ...

local I = require("kebab.dbide")
local D = require("kebab.db")

local function with_store(fn)
  local saved = vim.g.kebab_db_store
  vim.g.kebab_db_store = H.tmpdir("dbide-store") .. "/connections.json"
  local ok, err = pcall(fn)
  vim.g.kebab_db_store = saved
  if not ok then error(err, 0) end
end

-- Never the user's own ~/.local/share/nvim/kebab/sql: a run wrote there and
-- the editor then asked whether to save it, which in a headless session is a
-- prompt nobody can answer.
vim.g.kebab_db_sql_dir = H.tmpdir("dbide-sql")

local fixture_url
local function fixture()
  if fixture_url then
    return { name = "shop", url = fixture_url }
  end
  local file = H.tmpdir("dbide-db") .. "/shop.sqlite"
  local sql = table.concat({
    "CREATE TABLE customers (id INTEGER PRIMARY KEY, full_name TEXT);",
    "CREATE TABLE orders (id INTEGER PRIMARY KEY, total_cents INTEGER);",
    "INSERT INTO customers (full_name) VALUES ('Ada Lovelace');",
    "INSERT INTO customers (full_name) VALUES ('Alan Turing');",
  }, "\n")
  H.eq(0, vim.system({ "sqlite3", file }, { stdin = sql, text = true }):wait(30000).code,
    "fixture creation failed")
  fixture_url = "jdbc:sqlite:" .. file
  return { name = "shop", url = fixture_url }
end

local function requires_jdbc()
  if vim.fn.executable("java") == 0 or vim.fn.executable("javac") == 0 or vim.fn.executable("sqlite3") == 0 then
    H.skip("a JDK and sqlite3 are needed")
  end
end

H.describe("reading the explorer tree", function()
  -- Rather than parse dadbod-ui's drawing -- indentation, expand arrows and
  -- whichever glyphs the Nerd Font has -- a candidate is checked against the
  -- table list this layer already has. That is also what keeps "New query"
  -- and "Saved queries (0)" from being taken for tables.
  local tables = { "inventory.stock_item", "customers", "sales.order_line" }

  H.it("finds the table on a tree line", function()
    H.eq("inventory.stock_item", I.table_on_line("      ▸  inventory.stock_item", tables))
    H.eq("customers", I.table_on_line("    ▾ 󰓱 customers", tables))
    H.eq("sales.order_line", I.table_on_line("sales.order_line", tables))
  end)

  H.it("does not take a node for a table", function()
    for _, line in ipairs({
      "  ▸ 󰆼 shop_local",
      "      󰓰 New query",
      "    ▸  Saved queries (0)",
      "    ▸ 󰓱 Tables (48)",
      "",
      "   ",
      '" Press ? for help',
    }) do
      H.eq(nil, I.table_on_line(line, tables), ("%q is not a table"):format(line))
    end
  end)

  H.it("finds which connection a line belongs to", function()
    local lines = {
      '" Press ? for help',
      "",
      "▸ 󰆼 alpha",
      "▾ 󰆼 shop ✓",
      "    󰓰 New query",
      "  ▾ 󰓱 Tables (2)",
      "    ▸  customers",
      "▸ 󰆼 other",
    }
    local names = { "alpha", "shop", "other" }
    H.eq("shop", I.connection_above(lines, 7, names), "the nearest connection above the table")
    H.eq("alpha", I.connection_above(lines, 3, names))
    H.eq("other", I.connection_above(lines, 8, names))
    H.eq(nil, I.connection_above(lines, 1, names), "nothing above the first connection")
  end)

  H.it("is not fooled by a connection whose name is a prefix of another", function()
    local lines = { "▾ 󰆼 alpha_reporting ✓", "  ▸  customers" }
    H.eq("alpha_reporting", I.connection_above(lines, 2, { "alpha", "alpha_reporting" }))
  end)
end)

H.describe("the three panes", function()
  H.it("puts the rows under the statement, not beside it", function()
    requires_jdbc()
    vim.cmd("only")
    local c = fixture()
    local layout = I.layout(c)
    H.ok(layout.editor, "there should be a statement pane")
    H.ok(layout.output, "there should be a rows pane")
    local ed = vim.api.nvim_win_get_position(layout.editor)
    local out = vim.api.nvim_win_get_position(layout.output)
    H.eq(ed[2], out[2], "same column")
    H.ok(out[1] > ed[1], ("rows should be below the statement, got rows row=%d statement row=%d"):format(out[1], ed[1]))
    H.eq("sql", vim.bo[vim.api.nvim_win_get_buf(layout.editor)].filetype)
    H.eq("dbout", vim.bo[vim.api.nvim_win_get_buf(layout.output)].filetype)
  end)

  H.it("reuses the panes rather than stacking more", function()
    requires_jdbc()
    vim.cmd("only")
    local c = fixture()
    I.layout(c)
    local first = #vim.api.nvim_list_wins()
    I.layout(c)
    I.layout(c)
    H.eq(first, #vim.api.nvim_list_wins(), "three opens should not make six windows")
  end)

  H.it("gives the rows pane the larger share", function()
    requires_jdbc()
    vim.cmd("only")
    local layout = I.layout(fixture())
    local ed = vim.api.nvim_win_get_height(layout.editor)
    local out = vim.api.nvim_win_get_height(layout.output)
    H.ok(out > ed, ("rows %d should be taller than the statement %d"):format(out, ed))
  end)
end)

H.describe("opening a table", function()
  H.it("writes the select and shows the rows", function()
    requires_jdbc()
    vim.cmd("only")
    local c = fixture()
    local ok, err = I.open_table(c, "customers")
    H.ok(ok, tostring(err))

    local editor = I.layout(c).editor
    local statement = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(editor), 0, -1, false), "\n")
    H.matches("select %* from", statement, "the statement pane should hold the query")
    H.matches("customers", statement)

    local out
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.b[b].kebab_db_output then out = b end
    end
    H.ok(out, "there should be a rows pane")
    local rows = table.concat(vim.api.nvim_buf_get_lines(out, 0, -1, false), "\n")
    H.matches("Ada Lovelace", rows, "the rows pane should hold the data, got: " .. rows:sub(1, 200))
    H.matches("full_name", rows, "with its header")
  end)

  H.it("leaves the cursor in the statement, on the statement", function()
    -- So the next thing typed edits the query, which is the point of having an
    -- editor rather than a grid.
    requires_jdbc()
    vim.cmd("only")
    local c = fixture()
    H.ok(I.open_table(c, "customers"))
    H.ok(vim.b.kebab_db_editor, "the statement pane should have focus")
    local line = vim.api.nvim_get_current_line()
    H.matches("select", line, "cursor should be on the select, got: " .. line)
  end)

  H.it("replaces the statement when another table is opened", function()
    requires_jdbc()
    vim.cmd("only")
    local c = fixture()
    H.ok(I.open_table(c, "customers"))
    H.ok(I.open_table(c, "orders"))
    local statement = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    H.matches("orders", statement)
    H.ok(not statement:match("customers"), "the previous table should be gone: " .. statement)
  end)

  H.it("keeps the rows pane read-only", function()
    requires_jdbc()
    vim.cmd("only")
    local c = fixture()
    H.ok(I.open_table(c, "customers"))
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.b[b].kebab_db_output then
        H.eq(false, vim.bo[b].modifiable, "a result grid is not for typing in")
        H.eq("nofile", vim.bo[b].buftype)
      end
    end
  end)

  H.it("reports a failing query in the rows pane rather than silently", function()
    requires_jdbc()
    vim.cmd("only")
    local c = fixture()
    I.layout(c)
    local notes = H.capture_notify(function()
      I.run(c, "select * from no_such_table")
    end)
    H.ok(#notes > 0, "a failure should be reported")
    local out
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.b[b].kebab_db_output then out = b end
    end
    local rows = table.concat(vim.api.nvim_buf_get_lines(out, 0, -1, false), "\n")
    H.matches("no_such_table", rows, "and shown where the rows would be")
  end)
end)

H.describe("paging the rows", function()
  -- Every SQL editor pages its result grid. This one did not: a select ran
  -- whole and `limit 200` was baked into the preview, so "show me this table"
  -- meant "show me some of this table, once".
  local many_url
  local function many()
    if many_url then
      return { name = "many", url = many_url }
    end
    local file = H.tmpdir("dbide-pages") .. "/many.sqlite"
    local rows = {}
    for i = 1, 250 do
      rows[#rows + 1] = ("insert into nums (label) values ('row %d');"):format(i)
    end
    local sql = "create table nums (id integer primary key, label text);\n" .. table.concat(rows, "\n")
    H.eq(0, vim.system({ "sqlite3", file }, { stdin = sql, text = true }):wait(60000).code)
    many_url = "jdbc:sqlite:" .. file
    return { name = "many", url = many_url }
  end

  local function rows_pane()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.b[b].kebab_db_output then
        return b
      end
    end
  end

  local function header()
    return vim.api.nvim_buf_get_lines(rows_pane(), 0, 1, false)[1]
  end

  H.it("reads the runner's footer and keeps it off the screen", function()
    local lines = {
      "id | label",
      "---+------",
      "1  | row 1",
      "",
      "(rows 1-100 of more)",
      "-- kebab-page offset=0 shown=100 more=1",
    }
    local rows, info = I.split_footer(lines)
    H.eq(5, #rows, "the footer line should not be shown")
    H.eq({ kind = "page", offset = 0, shown = 100, more = true }, info)
    local _, none = I.split_footer({ "(1 row)" })
    H.eq(nil, none, "output with no footer is not a page")
  end)

  H.it("asks the server for the page, not the whole table", function()
    -- The first version of paging read every row and skipped them on the
    -- client, so page 50 pulled five thousand rows to show a hundred. That is
    -- a workaround, not paging.
    local D = require("kebab.db")
    H.eq("select * from (select * from t) kebab_page limit 100 offset 200",
      D.page_sql("jdbc:postgresql://h/d", "select * from t", 200, 100))
    H.eq("select * from (select * from t) kebab_page limit 100 offset 200",
      D.page_sql("jdbc:sqlite:/x.db", "select * from t", 200, 100))
    -- SQL Server and Oracle spell it differently, and SQL Server refuses
    -- OFFSET without an ORDER BY to attach it to
    H.matches("order by %(select null%) offset 200 rows fetch next 100 rows only",
      D.page_sql("jdbc:sqlserver://h;database=d", "select * from t", 200, 100))
    H.matches("offset 200 rows fetch next 100 rows only",
      D.page_sql("jdbc:oracle:thin:@h/x", "select * from t", 200, 100))
  end)

  H.it("does not let a statement's own semicolon land inside the wrap", function()
    local D = require("kebab.db")
    H.eq("select * from (select 1) kebab_page limit 10 offset 0",
      D.page_sql("jdbc:sqlite:/x.db", "select 1;  ", 0, 10))
  end)

  H.it("survives a percent sign in the statement", function()
    -- gsub treats % in a *replacement* as an escape, and a LIKE pattern is
    -- full of them. The substitution passes a function for that reason.
    local D = require("kebab.db")
    H.matches("like '%%ada%%'", D.page_sql("jdbc:sqlite:/x.db", "select * from t where n like '%ada%'", 0, 5))
  end)

  H.it("pages the rows themselves, not just the header", function()
    requires_jdbc()
    vim.cmd("only")
    local c = many()
    H.ok(I.open_table(c, "nums"))
    local function span()
      local lines = vim.api.nvim_buf_get_lines(rows_pane(), 0, -1, false)
      local first, last
      for _, line in ipairs(lines) do
        local text = line:match("^%d+%s+| (row %d+)")
        if text then
          first = first or text
          last = text
        end
      end
      return first, last
    end
    local first, last = span()
    H.eq("row 1", first)
    H.eq("row 100", last)
    I.turn_page(1)
    first, last = span()
    H.eq("row 101", first, "the second page must hold the second hundred rows")
    H.eq("row 200", last)
    I.turn_page(1)
    first, last = span()
    H.eq("row 201", first)
    H.eq("row 250", last, "and the last page stops at the end")
  end)

  H.it("knows there is a next page without counting the table", function()
    -- One row beyond the page is requested and not shown; that leftover is the
    -- whole answer. Asking for exactly `size` rows made `more` false on every
    -- page, so Next refused to move while the header said "page 1 of 100".
    requires_jdbc()
    vim.cmd("only")
    local c = many()
    H.ok(I.open_table(c, "nums"))
    local pager = I.pager(c.url)
    H.ok(pager.info.more, "page 1 of 250 rows has a next page")
    H.eq(100, pager.info.shown, "and shows one page, not one page plus the probe row")
    H.eq("cursor", pager.info.kind, "the result set is held open, and the batch came off it")
  end)

  H.it("says where you are", function()
    local c = { name = "shop", url = "jdbc:sqlite:/tmp/x.db" }
    H.matches("rows 1%-100 of more", (I.pager_line(c, { offset = 0, shown = 100, more = true })))
    H.matches("page 1", (I.pager_line(c, { offset = 0, shown = 100, more = true })))
    H.matches("rows 101%-150 of 150", (I.pager_line(c, { offset = 100, shown = 50, more = false })))
    H.matches("page 2", (I.pager_line(c, { offset = 100, shown = 50, more = false })))
    -- Two lines: position, then the keys. Spelled out as keystrokes, and on
    -- keys that are free -- `]p`, `[p` and `R` are built-in Vim commands and
    -- the first version shadowed all three in the pane where you edit SQL.
    local where, bar, spans = I.pager_line(c, { offset = 0, shown = 1, more = false })
    H.matches("rows 1%-1 of 1", where)
    -- A pager is pressed constantly, so it is one keypress or one click, and
    -- the bar says which: "[ n next ]". `Space D n` -- spacebar, Shift+D, n --
    -- was three keystrokes with a shift in the middle to turn a page.
    H.matches("%[ n next %]", bar, "the bar should read like buttons: " .. bar)
    H.matches("%[ p prev %]", bar)
    H.matches("%[ f first %]", bar)
    H.matches("%[ r re%-run %]", bar)
    H.matches("run: Ctrl%+Enter", bar)
    for _, line in ipairs({ where, bar }) do
      H.ok(not line:find("<"), "no key-spec jargon on screen: " .. line)
    end
    -- and each button's columns, which is what makes it clickable
    H.eq(4, #spans)
    for _, span in ipairs(spans) do
      H.matches("^%[ " .. span.key .. " ", bar:sub(span.from, span.to), "the span should cover its own button")
    end
  end)

  H.it("shows one page, not the whole table", function()
    requires_jdbc()
    vim.cmd("only")
    local c = many()
    H.ok(I.open_table(c, "nums"))
    local lines = vim.api.nvim_buf_get_lines(rows_pane(), 0, -1, false)
    -- header, blank, column names, rule, 100 rows, blank, count
    H.ok(#lines < 120, ("one page should be about 100 rows, got %d lines"):format(#lines))
    H.matches("rows 1%-100 of more", lines[1])
    local text = table.concat(lines, "\n")
    H.matches("row 100", text)
    H.ok(not text:match("row 101"), "the next page should not be on screen")
  end)

  H.it("leaves the statement unlimited, because the pager owns the limit", function()
    requires_jdbc()
    vim.cmd("only")
    local c = many()
    H.ok(I.open_table(c, "nums"))
    local statement = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    H.ok(not statement:lower():match("limit"),
      "the select shown should be the one you would have written: " .. statement)
  end)

  H.it("runs the statement once and pages off the held result set", function()
    -- The difference between paging and a workaround, and the reason this is
    -- how every SQL editor does it: with the result set held open, the pages
    -- are a snapshot. Re-running the statement per page with LIMIT/OFFSET
    -- executes the whole query again each time *and* shifts the pages under
    -- you whenever anyone else writes to the table.
    requires_jdbc()
    vim.cmd("only")
    local file = H.tmpdir("dbide-snapshot") .. "/snap.sqlite"
    -- WAL, so another connection may write while a read is open
    local setup = "pragma journal_mode=wal;\ncreate table t (id integer primary key, label text);\n"
    local rows = {}
    for i = 1, 250 do
      rows[#rows + 1] = ("insert into t (id,label) values (%d,'row %d');"):format(i, i)
    end
    H.eq(0, vim.system({ "sqlite3", file }, { stdin = setup .. table.concat(rows, "\n"), text = true })
      :wait(60000).code)

    local c = { name = "snap", url = "jdbc:sqlite:" .. file }
    I.layout(c)
    I.run(c, "select * from t order by id")

    local function span()
      local first, last
      for _, line in ipairs(vim.api.nvim_buf_get_lines(rows_pane(), 0, -1, false)) do
        local text = line:match("^%d+%s+| (row %d+)")
        if text then
          first = first or text
          last = text
        end
      end
      return first, last
    end

    local first, last = span()
    H.eq("row 1", first)
    H.eq("row 100", last)
    H.eq("cursor", I.pager(c.url).info.kind, "the result set should be held open")

    -- somebody else deletes a row from the first page
    H.eq(0, vim.system({ "sqlite3", file }, { stdin = "delete from t where id = 50;", text = true })
      :wait(30000).code)

    I.turn_page(1)
    first, last = span()
    H.eq("row 101", first,
      "a held cursor pages its own snapshot; a re-queried page would start at row 102")
    H.eq("row 200", last)
  end)

  H.it("goes back without asking the database again", function()
    -- A forward-only result set cannot be rewound, so the pages already
    -- fetched are kept. That is also why going back is instant.
    requires_jdbc()
    vim.cmd("only")
    local c = many()
    H.ok(I.open_table(c, "nums"))
    I.turn_page(1)
    local pager = I.pager(c.url)
    H.eq(2, pager.fetched, "two pages fetched")
    I.turn_page(-1)
    H.eq(2, I.pager(c.url).fetched, "going back must not fetch a third time")
    H.matches("rows 1%-100", header())
  end)

  H.it("walks forward and back", function()
    requires_jdbc()
    vim.cmd("only")
    local c = many()
    H.ok(I.open_table(c, "nums"))
    I.turn_page(1)
    H.matches("rows 101%-200 of more", header())
    H.matches("row 101", table.concat(vim.api.nvim_buf_get_lines(rows_pane(), 0, -1, false), "\n"))
    I.turn_page(1)
    H.matches("rows 201%-250 of 250", header(), "the last page knows it is the last")
    I.turn_page(-1)
    H.matches("rows 101%-200", header())
    I.first_page()
    H.matches("rows 1%-100", header())
  end)

  H.it("will not walk off either end, and says so", function()
    requires_jdbc()
    vim.cmd("only")
    local c = many()
    H.ok(I.open_table(c, "nums"))
    local notes = H.capture_notify(function() I.turn_page(-1) end)
    H.eq(1, #notes)
    H.matches("first page", notes[1].msg)
    H.matches("rows 1%-100", header(), "and the page did not move")

    I.turn_page(1)
    I.turn_page(1)
    notes = H.capture_notify(function() I.turn_page(1) end)
    H.eq(1, #notes)
    H.matches("last page", notes[1].msg)
    H.matches("rows 201%-250", header())
  end)

  H.it("pages whatever was last run, not whatever the editor now says", function()
    -- The statement is kept with the pager: you can edit the query in the pane
    -- without the pager silently flipping to a page of a different result.
    requires_jdbc()
    vim.cmd("only")
    local c = many()
    H.ok(I.open_table(c, "nums"))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "select 'edited' as x" })
    I.turn_page(1)
    H.matches("rows 101%-200", header(), "editing the pane must not change what is paged")
  end)

  H.it("turns a page with one keypress in the grid", function()
    -- The grid is read-only, so n, p, f and r are free there: nothing to paste
    -- into, nothing to replace, no search to continue. In the statement pane
    -- those letters are editing commands and must stay that way.
    requires_jdbc()
    vim.cmd("only")
    local c = many()
    H.ok(I.open_table(c, "nums"))
    local buf = rows_pane()
    local keys = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      keys[m.lhs] = m.desc
    end
    H.eq("Next page", keys.n)
    H.eq("Previous page", keys.p)
    H.eq("First page", keys.f)
    H.eq("Re-run this page", keys.r)
    H.ok(keys["<LeftMouse>"], "and the bar should be clickable")

    -- the statement pane must keep its letters
    local editor
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.b[b].kebab_db_editor then editor = b end
    end
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(editor, "n")) do
      H.ok(m.lhs ~= "n" and m.lhs ~= "p" and m.lhs ~= "r",
        ("%s must not be taken in the pane where you edit SQL"):format(m.lhs))
    end
  end)

  H.it("binds the pager on both panes", function()
    requires_jdbc()
    vim.cmd("only")
    local c = many()
    H.ok(I.open_table(c, "nums"))
    for _, buf in ipairs({ vim.api.nvim_get_current_buf(), rows_pane() }) do
      local keys = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        keys[m.lhs] = true
      end
      -- <leader> is a space here, so the stored lhs is " Dn".
      for _, lhs in ipairs({ " Dn", " Db", " Df", " DR", "<C-CR>" }) do
        H.ok(keys[lhs], ("%s should be mapped in buffer %d"):format(lhs, buf))
      end
    end
  end)

  H.it("respects vim.g.kebab_db_page_size", function()
    requires_jdbc()
    vim.cmd("only")
    local saved = vim.g.kebab_db_page_size
    vim.g.kebab_db_page_size = 10
    local c = many()
    H.ok(I.open_table(c, "nums"))
    local got = header()
    vim.g.kebab_db_page_size = saved
    H.matches("rows 1%-10 of more", got)
  end)

  H.it("runs a script whole rather than refusing to page it", function()
    requires_jdbc()
    vim.cmd("only")
    local c = many()
    I.layout(c)
    I.run(c, "select 1 as a; select 2 as b;")
    local text = table.concat(vim.api.nvim_buf_get_lines(rows_pane(), 0, -1, false), "\n")
    H.matches("not paged", text, "got: " .. text:sub(1, 160))
    H.matches("1", text)
  end)
end)

H.describe("how a table is built", function()
  -- The half of a database IDE that is not the data: sitting down with
  -- somebody else's database means asking what the columns are, which is the
  -- key, and how the tables are joined.
  local RAW = {
    "-- columns",
    "id\tINTEGER\tnot null\t\tpk\tauto",
    "customer_id\tINTEGER\tnot null\t\t\t",
    "total_cents\tINTEGER\tnot null\t0\t\t",
    "note\tVARCHAR(40)\tnull\t\t\t",
    "-- primary key",
    "id",
    "-- foreign keys",
    "customer_id\tcustomers\tid\torders_customer_fk",
    "-- referenced by",
    "order_lines\torder_id\tid\tlines_order_fk",
    "-- indexes",
    "orders_by_customer\t\tcustomer_id, placed_at",
    "orders_email_uq\tunique\temail",
  }

  H.it("reads every section the runner prints", function()
    local p = I.parse_structure(RAW)
    H.eq(4, #p.columns)
    H.eq({ name = "id", type = "INTEGER", null = "not null", pk = true, auto = true }, p.columns[1])
    H.eq("0", p.columns[3].default, "a default is worth seeing")
    H.eq("VARCHAR(40)", p.columns[4].type, "and so is the size")
    H.eq({ "id" }, p.key)
    H.eq({ column = "customer_id", table = "customers", target = "id", name = "orders_customer_fk" },
      p.foreign[1])
    H.eq({ table = "order_lines", column = "order_id", target = "id", name = "lines_order_fk" },
      p.referenced[1])
    H.eq(2, #p.indexes)
    H.eq(true, p.indexes[2].unique)
    H.eq("customer_id, placed_at", p.indexes[1].columns, "an index on (a, b) is not one on (b, a)")
  end)

  H.it("lays it out so it can be read aloud", function()
    local out = I.render_structure("orders", I.parse_structure(RAW))
    local text = table.concat(out, "\n")
    H.matches("^%-%- orders", text)
    H.matches("columns", text)
    H.matches("id%s+INTEGER%s+not null%s+pk, auto", text)
    H.matches("total_cents%s+INTEGER%s+not null%s+default 0", text)
    H.matches("primary key\n  id", text)
    H.matches("customer_id → customers%.id", text)
    H.matches("order_lines%.order_id → id", text)
    H.matches("orders_email_uq  unique", text)
    for _, line in ipairs(out) do
      H.ok(not line:match("%s$"), ("a trailing space makes a copy-paste dirty: %q"):format(line))
    end
  end)

  H.it("says none rather than leaving a section out", function()
    -- "no foreign keys" is an answer, and a missing heading reads as a bug.
    local out = I.render_structure("thing", I.parse_structure({ "-- columns", "-- primary key",
      "-- foreign keys", "-- referenced by", "-- indexes" }))
    local text = table.concat(out, "\n")
    for _, section in ipairs({ "primary key", "foreign keys", "referenced by", "indexes" }) do
      H.matches(section, text)
    end
    H.eq(4, select(2, text:gsub("  none", "")), "each empty section should say so")
  end)

  H.it("asks a real database", function()
    requires_jdbc()
    local file = H.tmpdir("dbide-structure") .. "/shop.sqlite"
    local sql = table.concat({
      "create table customers (id integer primary key, email text not null unique);",
      "create table orders (id integer primary key,",
      "  customer_id integer not null references customers(id),",
      "  total_cents integer not null default 0);",
      "create index orders_by_customer on orders (customer_id);",
      "create table order_lines (id integer primary key, order_id integer references orders(id));",
    }, "\n")
    H.eq(0, vim.system({ "sqlite3", file }, { stdin = sql, text = true }):wait(30000).code)

    local c = { name = "shop", url = "jdbc:sqlite:" .. file }
    local lines, err = require("kebab.db").structure(c, "orders")
    H.ok(lines, tostring(err))
    local p = I.parse_structure(lines)
    H.eq({ "id" }, p.key)
    H.eq(1, #p.foreign, "orders points at customers")
    H.eq("customers", p.foreign[1].table)
    H.eq(1, #p.referenced, "and order_lines points at orders")
    H.eq("order_lines", p.referenced[1].table)
    H.ok(#p.columns >= 3)
    local names = vim.tbl_map(function(col) return col.name end, p.columns)
    H.ok(vim.tbl_contains(names, "total_cents"), "got: " .. table.concat(names, ","))
  end)

  H.it("shows it where the rows go, with no pager", function()
    requires_jdbc()
    vim.cmd("only")
    local c = fixture()
    I.layout(c)
    H.ok(I.show_structure(c, "customers"))
    local out
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.b[b].kebab_db_output then out = b end
    end
    H.ok(out, "the rows pane should be there")
    local text = table.concat(vim.api.nvim_buf_get_lines(out, 0, -1, false), "\n")
    H.matches("^%-%- customers", text)
    H.matches("columns", text)
    H.matches("full_name", text, "got: " .. text:sub(1, 160))
    H.eq(nil, I.pager(c.url), "a structure is one answer, not a page of rows")
  end)
end)

H.describe("running a statement from the editor", function()
  H.it("runs the one under the cursor and refreshes the rows", function()
    requires_jdbc()
    vim.cmd("only")
    local c = fixture()
    with_store(function()
      H.ok(D.save({ c }))
      H.ok(I.open_table(c, "customers"))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "select full_name from customers where id = 2;",
        "select 'not this one' as wrong;",
      })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      I.run_current()
      local out
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local b = vim.api.nvim_win_get_buf(w)
        if vim.b[b].kebab_db_output then out = b end
      end
      local rows = table.concat(vim.api.nvim_buf_get_lines(out, 0, -1, false), "\n")
      H.matches("Alan Turing", rows, "got: " .. rows:sub(1, 200))
      H.ok(not rows:match("not this one"), "only the statement under the cursor should run")
    end)
  end)

  H.it("binds its own execute keys in the statement pane", function()
    -- Buffer-local, so they beat the global ones -- dadbod's own exec would
    -- open a second result window. Not <leader>S, which snacks owns as
    -- "Select Scratch Buffer", and not R, which is Replace mode.
    requires_jdbc()
    vim.cmd("only")
    I.layout(fixture())
    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      lhs[m.lhs] = true
    end
    H.ok(lhs["<C-CR>"], "Ctrl+Enter should run the statement")
    H.ok(lhs[" Dr"], "and so should the leader key in the database namespace")
    -- <leader>S is bound here too, but to *ours*: dadbod-ui takes that key in
    -- any sql buffer and its execute opens a second result window. It is not
    -- advertised, because outside these panes the same key is snacks'
    -- scratch-buffer picker -- which is what the user got when they pressed it.
    local ours = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      ours[m.lhs] = m.desc
    end
    H.eq("Run the statement", ours[" S"], "if that key is live here it must run the statement")
    H.ok(not lhs["R"], "R is Replace mode; the pager must not shadow it in an editor pane")
    -- insert mode too, so a query can be run without leaving the mode it was
    -- typed in
    local imaps = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "i")) do
      imaps[m.lhs] = true
    end
    H.ok(imaps["<C-CR>"], "Ctrl+Enter should work while typing")
  end)
end)
