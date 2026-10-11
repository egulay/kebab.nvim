-- Side-by-side diff and merge-conflict resolution. lazygit covers staging and
-- history well, but it has no real diff view and no 3-way merge UI.
return {
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory", "DiffviewToggleFiles" },
    opts = {
      enhanced_diff_hl = true,
      view = {
        -- 3-way merge layout for conflicts, like a graphical merge tool
        merge_tool = { layout = "diff3_mixed", disable_diagnostics = true },
      },
    },
    keys = {
      { "<leader>gv", "<cmd>DiffviewOpen<cr>", desc = "Diff View (working tree)" },
      { "<leader>gV", "<cmd>DiffviewFileHistory %<cr>", desc = "Diff View (file history)" },
      { "<leader>gq", "<cmd>DiffviewClose<cr>", desc = "Diff View (close)" },
    },
  },
}
