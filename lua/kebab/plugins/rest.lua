-- The .http client.
--
-- kulala now asks for a paid licence token the moment a .http buffer opens: its
-- LSP backend downloads "kulala-core", and the download prompts with
-- `vim.fn.inputsecret("Kulala license token: ")`. In a headless session that
-- blocks forever; interactively it means the layer's advertised .http support
-- greets you with a paywall.
--
-- Sending a request does not need it -- that path is curl-based, and
-- kulala/cmd/init.lua only takes the core route for a request that carries
-- `_kulala_core`. So the backend stays off unless a token is actually present,
-- in which case nothing is taken away.
--- Where kulala keeps a saved licence token.
---
--- Asked of kulala itself when it is loadable, because this is its path to
--- choose and it has already changed once: the previous guesses
--- (`stdpath("data")/kulala.nvim/` and `$XDG_CONFIG_HOME/kulala/`) were both
--- wrong, so a user who had entered and saved a token still had the LSP
--- backend pinned off -- the opposite of "nothing is taken away".
---@return string[]
local function token_paths()
  local ok, bridge = pcall(require, "kulala.cmd.kulala_core_bridge")
  if ok and type(bridge) == "table" and type(bridge.effective_data_dir) == "function" then
    local resolved, dir = pcall(bridge.effective_data_dir)
    if resolved and type(dir) == "string" and dir ~= "" then
      return { dir .. "/license-token" }
    end
  end
  -- kulala is lazy-loaded on a .http buffer, so this runs before it exists.
  -- These mirror its own defaults (kulala_core_bridge.default_data_dir).
  local out = {}
  local function add(dir)
    if type(dir) == "string" and dir ~= "" then
      out[#out + 1] = dir .. "/license-token"
    end
  end
  add(vim.env.KULALA_CORE_DATA_DIR)
  if vim.fn.has("win32") == 1 and vim.env.LOCALAPPDATA then
    add((vim.env.LOCALAPPDATA:gsub("\\", "/")) .. "/kulala-core")
  end
  if (vim.uv.os_uname() or {}).sysname == "Darwin" then
    add(vim.fn.expand("~/Library/Application Support/kulala-core"))
  end
  add((vim.env.XDG_DATA_HOME or vim.fn.expand("~/.local/share")) .. "/kulala-core")
  return out
end

local function has_license_token()
  if (vim.env.KULALA_CORE_LICENSE_TOKEN or "") ~= "" then
    return true
  end
  -- a token entered once is saved; respect it rather than prompting again
  for _, path in ipairs(token_paths()) do
    local stat = vim.uv.fs_stat(path)
    if stat and stat.size > 0 then
      return true
    end
  end
  return false
end

return {
  {
    "mistweaverco/kulala.nvim",
    opts = function(_, opts)
      opts.lsp = vim.tbl_extend("force", opts.lsp or {}, { enable = has_license_token() })
      return opts
    end,
  },
}
