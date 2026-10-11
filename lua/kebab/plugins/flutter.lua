-- Flutter: device picker, emulator launch, hot reload/restart, outline.
-- LazyVim's dart extra starts dartls through lspconfig; flutter-tools starts
-- its own, so the lspconfig one is disabled to avoid two clients on one buffer.
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = { dartls = { enabled = false } },
    },
  },
  {
    "nvim-flutter/flutter-tools.nvim",
    ft = { "dart" },
    -- ft alone is not enough: the editor menu's Flutter submenu is reachable
    -- from any buffer, and with only `ft = dart` every entry in it failed with
    -- "E492: Not an editor command" until a .dart file happened to be open.
    cmd = {
      "FlutterRun", "FlutterDebug", "FlutterReload", "FlutterRestart", "FlutterQuit",
      "FlutterAttach", "FlutterDetach", "FlutterDevices", "FlutterEmulators",
      "FlutterLogToggle", "FlutterLogClear", "FlutterPubGet", "FlutterPubUpgrade",
      "FlutterOutlineToggle", "FlutterOutlineOpen", "FlutterDevTools", "FlutterCommands",
      "FlutterVisualDebug", "FlutterChangeTargetPlatform", "FlutterToggleBrightness",
      "FlutterInspectWidget", "FlutterLspRestart", "FlutterReanalyze", "FlutterSuper",
    },
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      ui = { border = "rounded", notification_style = "native" },
      decorations = { statusline = { app_version = true, device = true } },
      widget_guides = { enabled = true },
      dev_log = { enabled = true, open_cmd = "botright 15split" },
      lsp = {
        color = { enabled = true, background = false, virtual_text = true },
        settings = {
          showTodos = true,
          completeFunctionCalls = true,
          renameFilesWithClasses = "prompt",
          updateImportsOnRename = true,
        },
      },
    },
    keys = {
      { "<leader>F", "", desc = "+flutter", ft = "dart" },
      { "<leader>Fr", "<cmd>FlutterRun<cr>", desc = "Run", ft = "dart" },
      { "<leader>Fq", "<cmd>FlutterQuit<cr>", desc = "Quit", ft = "dart" },
      { "<leader>FR", "<cmd>FlutterRestart<cr>", desc = "Hot Restart", ft = "dart" },
      { "<leader>Fh", "<cmd>FlutterReload<cr>", desc = "Hot Reload", ft = "dart" },
      { "<leader>Fd", "<cmd>FlutterDevices<cr>", desc = "Devices", ft = "dart" },
      { "<leader>Fe", "<cmd>FlutterEmulators<cr>", desc = "Emulators", ft = "dart" },
      { "<leader>Fo", "<cmd>FlutterOutlineToggle<cr>", desc = "Outline", ft = "dart" },
      { "<leader>Fl", "<cmd>FlutterLogToggle<cr>", desc = "Dev Log", ft = "dart" },
      { "<leader>Fp", "<cmd>FlutterPubGet<cr>", desc = "Pub Get", ft = "dart" },
    },
  },
}
