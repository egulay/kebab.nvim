-- Which databases can be asked for a page, and in what words.
--
-- Written because the first version of this table listed two dialects by name
-- and left the rest to a silent default, which read as "only MySQL is
-- supported" and would have given a driver added later whatever syntax the
-- default happened to be.
local H = ...

local D = require("kebab.db")
local J = require("kebab.jdbc")

H.describe("asking the server for a page", function()
  H.it("has a clause for every driver this layer can connect with", function()
    -- The point of the spec: adding a driver to kebab.jdbc without deciding
    -- how it pages fails here, rather than silently inheriting LIMIT/OFFSET.
    local missing = {}
    for _, driver in ipairs(J.drivers()) do
      local sql = D.page_sql("jdbc:" .. driver.key .. "://host/db", "select * from t", 10, 5)
      if not sql then
        missing[#missing + 1] = driver.key
      end
    end
    H.eq({}, missing, "a registered driver with no paging clause")
    H.ok(#J.drivers() >= 9, "expected the full driver list, got " .. #J.drivers())
  end)

  H.it("uses each vendor's own spelling", function()
    local function page(key)
      return D.page_sql("jdbc:" .. key .. "://host/db", "select * from t", 200, 100)
    end
    for _, key in ipairs({ "postgresql", "sqlite", "mysql", "mariadb", "h2", "duckdb", "clickhouse" }) do
      H.eq("select * from (select * from t) kebab_page limit 100 offset 200", page(key), key)
    end
    H.eq("select * from (select * from t) kebab_page offset 200 rows fetch next 100 rows only",
      page("oracle"), "Oracle 12c spells it the SQL:2008 way")
    H.eq(
      "select * from (select * from t) kebab_page order by (select null) offset 200 rows fetch next 100 rows only",
      page("sqlserver"),
      "SQL Server refuses OFFSET with no ORDER BY to attach it to"
    )
  end)

  H.it("wraps the statement rather than extending it", function()
    -- So a query that carries its own LIMIT, ORDER BY, CTE or UNION is not
    -- quietly changed into something else.
    local busy = "with recent as (select * from t order by id desc limit 50) select * from recent union select * from u"
    local sql = D.page_sql("jdbc:postgresql://h/d", busy, 0, 10)
    H.matches("^select %* from %(" .. vim.pesc(busy) .. "%) kebab_page limit 10 offset 0$", sql)
  end)

  H.it("answers nil for a database it has no clause for", function()
    -- Not a failure: kebab.dbide pages on the cursor instead, which is
    -- dialect-free and always correct.
    H.eq(nil, D.page_sql("jdbc:firebirdsql://host/db", "select * from t", 0, 10))
    H.eq(nil, D.page_sql("not a url at all", "select * from t", 0, 10))
  end)

  H.it("lists what it can page", function()
    local names = D.paging_dialects()
    table.sort(names)
    H.eq({ "clickhouse", "duckdb", "h2", "mariadb", "mysql", "oracle", "postgresql", "sqlite", "sqlserver" }, names)
  end)
end)
