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
      "▸ 󰆼 MII",
      "▾ 󰆼 shop ✓",
      "    󰓰 New query",
      "  ▾ 󰓱 Tables (2)",
      "    ▸  customers",
      "▸ 󰆼 other",
    }
    local names = { "MII", "shop", "other" }
    H.eq("shop", I.connection_above(lines, 7, names), "the nearest connection above the table")
    H.eq("MII", I.connection_above(lines, 3, names))
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

  H.it("binds its own execute key in the statement pane", function()
    requires_jdbc()
    vim.cmd("only")
    I.layout(fixture())
    local found = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      if m.lhs == " S" then found = true end
    end
    H.ok(found, "<leader>S should be buffer-local here, so it beats dadbod's own")
  end)
end)
