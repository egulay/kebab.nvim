-- The right-click menu in a SQL statement pane or a result grid.
--
-- The editor menu has these actions too, two levels down under "Database".
-- That is the wrong place when the buffer under the pointer *is* a query: you
-- have just edited a select and want to run it, and "right-click, Database,
-- Run Statement" is not where anyone looks. Reported as "I changed the query
-- and there is no re-run on right click or anywhere else".
--
-- Everything the editor menu offers is still here, as a submenu, so nothing is
-- lost by the switch.
local A = require("kebab.menus.action")
local editor = require("kebab.menus.editor")

local rows = {
  { name = "Next Page", cmd = A.ex("IdeDbNextPage"), rtxt = "<leader>Dn" },
  { name = "Previous Page", cmd = A.ex("IdeDbPrevPage"), rtxt = "<leader>Db" },
  { name = "First Page", cmd = A.ex("IdeDbFirstPage"), rtxt = "<leader>Df" },
  { name = "separator" },
  { name = "Re-run This Page", cmd = A.ex("IdeDbRefreshPage"), rtxt = "<leader>DR" },
}

local connection = {
  { name = "Database Explorer", cmd = A.ex("DBUIToggle", { plugin = "vim-dadbod-ui" }), rtxt = "<leader>DD" },
  { name = "separator" },
  { name = "Attach Connection to Buffer...", cmd = A.ex("IdeDbConnect"), rtxt = "<leader>Dc" },
  { name = "Test Connection", cmd = A.ex("IdeDbPing"), rtxt = "<leader>Dp" },
  { name = "separator" },
  { name = "Browse Tables...", cmd = A.ex("IdeDbTables"), rtxt = "<leader>Dt" },
  { name = "New SQL Console", cmd = A.ex("IdeDbConsole"), rtxt = "<leader>Dq" },
  { name = "separator" },
  { name = "Connections and Processes", cmd = A.ex("IdeDbStatus"), rtxt = ":IdeDbStatus" },
  { name = "Close Warm Processes", cmd = A.ex("IdeDbDisconnect"), rtxt = ":IdeDbDisconnect" },
}

-- Run first, and at the top level: it is the reason the menu was opened.
local items = {
  { name = "Run Statement", cmd = A.ex("IdeDbRun"), rtxt = "<C-CR>" },
  { name = "Run Whole Buffer", cmd = A.ex("IdeDbRunAll"), rtxt = ":IdeDbRunAll" },
  { name = "separator" },
  { name = "Rows", items = rows },
  { name = "Connection", items = connection },
  { name = "separator" },
}

-- ...then everything the editor menu has, so a SQL buffer loses nothing.
for _, section in ipairs(editor) do
  if section.name ~= "Database" then
    items[#items + 1] = section
  end
end

-- Shown as what a person presses ("Space S"), not as <leader>S. The canonical
-- form stays in `keyspec` for the sweep.
return require("kebab.keys").humanise(items)
