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
local function has_license_token()
  if (vim.env.KULALA_CORE_LICENSE_TOKEN or "") ~= "" then
    return true
  end
  -- a token entered once is saved; respect it rather than prompting again
  local candidates = {
    vim.fn.stdpath("data") .. "/kulala.nvim/license-token",
    (vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. "/.config")) .. "/kulala/license-token",
  }
  for _, path in ipairs(candidates) do
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
