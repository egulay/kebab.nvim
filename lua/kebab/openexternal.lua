-- Hand a file the editor cannot usefully show to whatever the desktop opens it
-- with.
--
-- Double clicking `logo.png` in the tree used to load the PNG's bytes into a
-- buffer: a screenful of mojibake, a buffer you then have to find and close,
-- and nothing resembling the image. A graphical IDE hands that file to the
-- system viewer, and so does this now -- images, PDFs, office documents,
-- archives, audio, video, fonts and compiled objects.
--
-- Two decisions worth stating:
--
-- **The list is by extension, not by sniffing**, for the paths where no read
-- has happened yet. Sniffing means reading the file to decide whether to read
-- the file, and for a 2 GB disk image that is the whole cost of the mistake we
-- are trying to avoid. The tree's own open path *does* sniff, because there it
-- is a 1 KB read of a file nobody has touched yet, and it is what catches the
-- long tail (`.bin`, `.dat`, a compiled artifact with no suffix).
--
-- **It falls back to the editor.** If nothing on the machine opens that type,
-- the opener's non-zero exit is reported and the file is opened in the editor
-- after all -- a binary buffer is a poor outcome, but it beats a double click
-- that does nothing at all and says nothing either.
local M = {}

-- Extensions the desktop has a better answer for than a text editor.
--
-- Deliberately *not* here: `.svg` and `.xml` (text you edit as often as you
-- view), `.json`, `.csv`, `.log`, `.md`, and `.sql` -- and `.jar`, because the
-- desktop handler for one is an archive manager or a JVM, and neither is what
-- clicking a build output in a Java project means.
M.DEFAULT_EXTENSIONS = {
  -- images
  "png", "jpg", "jpeg", "gif", "bmp", "webp", "avif", "tif", "tiff", "ico",
  "heic", "psd", "xcf", "ai",
  -- documents
  "pdf", "epub", "mobi", "djvu",
  "doc", "docx", "dot", "dotx", "odt", "rtf",
  "xls", "xlsx", "ods", "xlsb",
  "ppt", "pptx", "odp",
  -- archives
  "zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "iso", "dmg",
  -- audio and video
  "mp3", "wav", "flac", "ogg", "oga", "opus", "m4a", "aac", "wma",
  "mp4", "mkv", "mov", "avi", "webm", "wmv", "flv", "m4v", "mpg", "mpeg",
  -- fonts
  "ttf", "otf", "woff", "woff2", "eot",
  -- compiled or packaged output
  "exe", "msi", "dll", "so", "dylib", "o", "a", "class", "pyc", "wasm",
  "deb", "rpm", "pkg", "apk", "appimage",
  -- other binaries that have a viewer
  "sqlite", "sqlite3", "db", "blend", "fbx", "stl", "obj3d",
}

---Configuration, merged with the defaults.
---
---`vim.g.kebab_open_external = false` turns the whole thing off. A table
---carries:
---  extensions          extra extensions to treat as external
---  replace_extensions  true to use only `extensions`, not the defaults
---  sniff               false to stop checking file contents in the tree
---  command             the opener argv, e.g. { "handlr", "open" }
---  notify              false to open silently
---@return { enabled: boolean, extensions: string[], sniff: boolean, command: string[]|nil, notify: boolean }
function M.config()
  local given = vim.g.kebab_open_external
  if given == false then
    return { enabled = false, extensions = {}, sniff = false, notify = false }
  end
  given = type(given) == "table" and given or {}
  local extensions = M.DEFAULT_EXTENSIONS
  if type(given.extensions) == "table" then
    if given.replace_extensions then
      extensions = given.extensions
    else
      -- Merged, not replaced: `vim.tbl_deep_extend` would drop the defaults,
      -- which is the trap `follow.config` already carries a note about.
      extensions = vim.list_extend(vim.deepcopy(M.DEFAULT_EXTENSIONS), given.extensions)
    end
  end
  return {
    enabled = given.enabled ~= false,
    extensions = extensions,
    sniff = given.sniff ~= false,
    command = type(given.command) == "table" and given.command or nil,
    notify = given.notify ~= false,
  }
end

---The desktop's "open this with whatever handles it" command, as argv.
---@return string[]|nil argv, string|nil why there is none
function M.opener()
  local configured = M.config().command
  if configured and #configured > 0 then
    if vim.fn.executable(configured[1]) == 0 then
      return nil, ("%s is not on PATH (vim.g.kebab_open_external.command)"):format(configured[1])
    end
    return vim.deepcopy(configured)
  end
  if vim.fn.has("mac") == 1 then
    return { "open" }
  end
  if vim.fn.has("win32") == 1 or vim.fn.has("wsl") == 1 then
    -- `start` is a cmd builtin, and its first quoted argument is the window
    -- title, which is why the empty string is there.
    return { "cmd.exe", "/c", "start", "" }
  end
  for _, candidate in ipairs({ "xdg-open", "handlr", "gio" }) do
    if vim.fn.executable(candidate) == 1 then
      return candidate == "gio" and { "gio", "open" }
        or (candidate == "handlr" and { "handlr", "open" } or { candidate })
    end
  end
  return nil, "no desktop opener found (install xdg-utils for xdg-open)"
end

---@param path string
---@return string lowercase extension, without the dot
function M.extension(path)
  return (vim.fn.fnamemodify(path, ":e") or ""):lower()
end

---Does this file have a NUL byte in its first kilobyte?
---
---The cheap definition of "not text". Only used where nothing has read the
---file yet, so it costs one 1 KB read rather than loading the whole thing.
---@param path string
---@return boolean
function M.looks_binary(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return false
  end
  local ok, chunk = pcall(vim.uv.fs_read, fd, 1024, 0)
  pcall(vim.uv.fs_close, fd)
  if not ok or type(chunk) ~= "string" or chunk == "" then
    return false
  end
  return chunk:find("\0", 1, true) ~= nil
end

---Should the desktop open this rather than the editor?
---@param path string
---@param opts? { sniff?: boolean }
---@return boolean external, string|nil why  "extension" or "binary"
function M.is_external(path, opts)
  opts = opts or {}
  local cfg = M.config()
  if not cfg.enabled or type(path) ~= "string" or path == "" then
    return false, nil
  end
  -- A directory is the tree's business, and a buffer that is not a file on
  -- disk (a terminal, a picker, `oil://...`) is nobody's.
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return false, nil
  end
  if vim.tbl_contains(cfg.extensions, M.extension(path)) then
    return true, "extension"
  end
  if opts.sniff and cfg.sniff and M.looks_binary(path) then
    return true, "binary"
  end
  return false, nil
end

---Hand `path` to the desktop.
---
---`opts.spawn` exists so a test can see the argv instead of launching a PDF
---viewer, and `opts.fallback` is what runs when the machine has no handler for
---the type -- the editor, normally.
---@param path string
---@param opts? { spawn?: function, fallback?: fun(reason: string), notify?: boolean }
---@return boolean started, string|nil err
function M.open(path, opts)
  opts = opts or {}
  local cfg = M.config()
  local argv, why = M.opener()
  if not argv then
    if opts.fallback then
      opts.fallback(why)
    end
    return false, why
  end
  argv[#argv + 1] = path

  local spawn = opts.spawn or vim.system
  local name = vim.fn.fnamemodify(path, ":t")
  local notify = opts.notify
  if notify == nil then
    notify = cfg.notify
  end

  local ran, handle_or_err = pcall(spawn, argv, {
    -- Detached: the viewer must outlive the editor. Closing Neovim should not
    -- take the image you opened from it down with it.
    detach = true,
    text = true,
  }, function(result)
    -- The opener answers immediately; a non-zero code here means nothing on
    -- this machine claims the type, so the editor gets it after all.
    if result and result.code ~= 0 then
      local detail = vim.trim((result.stderr or "") .. (result.stdout or ""))
      vim.schedule(function()
        vim.notify(
          ("Nothing on this machine opens %s%s"):format(name, detail ~= "" and (": " .. detail) or ""),
          vim.log.levels.WARN
        )
        if opts.fallback then
          opts.fallback(detail ~= "" and detail or "the desktop opener failed")
        end
      end)
    end
  end)
  if not ran then
    -- vim.system throws for a missing executable rather than reporting it.
    if opts.fallback then
      opts.fallback(tostring(handle_or_err))
    end
    return false, tostring(handle_or_err)
  end

  if notify then
    -- Present tense on purpose: the exit code arrives later, and "Opened X"
    -- followed by "Nothing on this machine opens X" is a contradiction the
    -- reader has to resolve.
    vim.notify(("Opening %s with the system default"):format(name))
  end
  return true, nil
end

---The whole decision: if the desktop should have this file, give it to the
---desktop and say so.
---@param path string
---@param opts? table passed through to M.is_external and M.open
---@return boolean handled
function M.handle(path, opts)
  opts = opts or {}
  local external = M.is_external(path, opts)
  if not external then
    return false
  end
  M.open(path, opts)
  return true
end

-- --------------------------------------------------------------- the editor

---Step the window off `buf` and wipe it.
---
---`BufReadCmd` has already created the buffer by the time it runs, so handing
---the file to the desktop leaves an empty buffer named `logo.png` sitting in
---the window. Going back to the alternate buffer is what a person expects --
---the file they were reading. There may not be one (`nvim logo.png` from a
---shell), so an empty buffer is the fallback.
---@param buf integer
local function dismiss(buf)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.api.nvim_win_call(win, function()
        local alt = vim.fn.bufnr("#")
        if alt > 0 and alt ~= buf and vim.api.nvim_buf_is_valid(alt) then
          pcall(vim.cmd, "buffer #")
        else
          pcall(vim.cmd, "enew")
        end
      end)
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end

---Open it in the editor after all, which is what BufReadCmd was going to do.
---
---`noautocmd`, and that is the whole point: a plain `:edit` fires BufReadCmd
---again, which hands the file back to the desktop, which fails again. Measured
---before this guard: "Opened logo.png with the system default" twice, a
---warning in between, and an empty buffer at the end of it. Suppressing the
---autocmd lets Neovim's own read happen; `filetype detect` is then run by
---hand, since that is an autocmd too.
---@param path string
local function editor_read(path)
  vim.schedule(function()
    local escaped = vim.fn.fnameescape(path)
    if not pcall(vim.cmd, "noautocmd edit " .. escaped) then
      return
    end
    pcall(vim.cmd, "filetype detect")
    pcall(vim.cmd, "doautocmd BufReadPost")
  end)
end

---Register the autocmds.
---
---`BufReadCmd` rather than `BufReadPre`: it replaces the read entirely, so the
---bytes of a 4 GB video are never loaded to decide not to look at them. The
---pattern list is the extensions, which is why the content sniff cannot apply
---here -- a pattern has to be known before the file is seen. @see M.handle
function M.setup()
  local group = vim.api.nvim_create_augroup("kebab_open_external", { clear = true })
  local patterns = {}
  for _, ext in ipairs(M.config().extensions) do
    patterns[#patterns + 1] = "*." .. ext
    patterns[#patterns + 1] = "*." .. ext:upper()
  end
  if #patterns == 0 then
    return
  end
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = patterns,
    desc = "Open a file the editor cannot show with the desktop's default application",
    callback = function(args)
      local path = vim.fn.fnamemodify(args.match ~= "" and args.match or args.file, ":p")
      if not M.config().enabled then
        return editor_read(path)
      end
      if vim.uv.fs_stat(path) == nil then
        -- A file that does not exist yet: Neovim fires BufNewFile rather than
        -- BufReadCmd for those, so this is belt and braces -- but creating
        -- `diagram.png` from the editor has to keep working.
        return editor_read(path)
      end
      local started = M.open(path, { fallback = function()
        editor_read(path)
      end })
      if started then
        dismiss(args.buf)
      end
    end,
  })
end

-- ------------------------------------------------------------ the file tree

---The neo-tree commands this layer overrides.
---
---One override covers every way the tree opens a file -- `<CR>`, a double
---click, and the right-click menu's "Open", which all dispatch through the
---`open` command -- plus the split and tab variants, where handing a PDF to
---the viewer is just as right as splitting the window for its bytes is wrong.
---
---A directory is passed straight through: `open` on one toggles it, which is
---neo-tree's business and not this module's.
---
---Merged into `opts.filesystem.commands`, not `opts.commands`: neo-tree merges
---a top-level `commands` table with `tbl_extend("keep", ...)` *under* the
---source's own, so a top-level `open` would be silently ignored -- the source
---already has one.
---@return table<string, fun(state: table)>
function M.neotree_commands()
  local names = {
    "open", "open_split", "open_vsplit", "open_tabnew",
    "open_rightbelow_vs", "open_leftabove_vs", "open_with_window_picker",
  }
  local commands = {}
  for _, name in ipairs(names) do
    commands[name] = function(state)
      local node = state and state.tree and state.tree:get_node()
      local path = node and node.type == "file" and node.path or nil
      -- sniff: the path is in hand and nothing has read the file yet
      if path and M.handle(path, { sniff = true }) then
        return
      end
      local ok, source = pcall(require, "neo-tree.sources.filesystem.commands")
      if ok and type(source[name]) == "function" then
        return source[name](state)
      end
      local common_ok, common = pcall(require, "neo-tree.sources.common.commands")
      if common_ok and type(common[name]) == "function" then
        return common[name](state)
      end
      vim.notify("neo-tree has no command called " .. name, vim.log.levels.WARN)
    end
  end
  return commands
end

return M
