-- The Ghost Mode indicator: the panel that appears by itself while
-- :IdeFollow is on, so a cursor moving on its own is explained rather than
-- alarming.
local H = ...
local G = require("kebab.ghostbar")
local F = require("kebab.follow")

---Run `fn` with follow.running() reporting `value`.
local function pretending(value, fn)
  local real = F.running
  F.running = function()
    return value
  end
  local ok, err = pcall(fn)
  F.running = real
  if not ok then
    error(err, 0)
  end
end

---How many windows the panel currently owns. Counting *all* windows is no use:
---a leftover explorer split from another spec would be counted too.
local function panels()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "kebabghost" then
      n = n + 1
    end
  end
  return n
end

H.describe("the Ghost Mode panel", function()
  H.it("shows a window and animates it", function()
    pretending(true, function()
      H.eq(0, panels(), "no panel should be up yet")
      H.ok(G.show(), "show should succeed")
      H.ok(G.state().showing, "a window should be open")
      H.ok(G.state().animating, "the animation timer should be running")
      H.eq(1, panels(), "exactly one panel window")

      local frames, start = {}, G.state().frame
      H.wait(3000, function()
        frames[G.state().text] = true
        return G.state().frame >= start + 4
      end, "the frame counter should advance on its own")
      H.ok(vim.tbl_count(frames) > 1, "the text should change between frames: " .. vim.inspect(frames))

      G.hide()
      H.falsy(G.state().showing)
      H.falsy(G.state().animating, "the timer must be closed, not just stopped")
      H.eq(0, panels(), "and the panel window must be gone")
    end)
  end)

  H.it("names the file it just followed", function()
    pretending(true, function()
      G.show()
      G.activity("/some/project/src/main/java/Thing.java")
      H.matches("Thing%.java", G.state().text, "the panel should say what moved")
      H.matches("Ghost Mode", G.state().text)
      H.eq(1, G.state().count)
      G.activity("/some/project/other.go")
      H.matches("other%.go", G.state().text)
      H.eq(2, G.state().count)
      G.hide()
    end)
  end)

  H.it("falls back to a change count once the filename is stale", function()
    local saved = vim.g.kebab_follow_indicator
    -- an activity window of 0ms, so the name is stale immediately
    vim.g.kebab_follow_indicator = { activity_ms = 0 }
    pretending(true, function()
      G.show()
      G.activity("/x/Thing.java")
      H.matches("1 change", G.state().text, "it should report the count: " .. G.state().text)
      G.hide()
    end)
    vim.g.kebab_follow_indicator = saved
  end)

  H.it("stops itself when following ends", function()
    pretending(true, function()
      G.show()
    end)
    H.ok(G.state().showing)
    -- the animation checks follow.running() on every tick
    pretending(false, function()
      H.wait(3000, function()
        return not G.state().showing
      end, "the panel should close itself once following stops")
    end)
    H.falsy(G.state().animating)
    H.eq(0, panels(), "no panel window should be left behind")
  end)

  H.it("can be turned off", function()
    local saved = vim.g.kebab_follow_indicator
    vim.g.kebab_follow_indicator = false
    pretending(true, function()
      H.falsy(G.show(), "show should decline when the indicator is disabled")
      H.falsy(G.state().showing)
      H.eq(0, panels())
    end)
    vim.g.kebab_follow_indicator = saved
  end)

  H.it("survives the window being closed by hand", function()
    pretending(true, function()
      local mine = vim.api.nvim_get_current_win()
      G.show()
      -- find the panel's own window and close it, as a user could
      local panel
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if w ~= mine and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "kebabghost" then
          panel = w
        end
      end
      H.ok(panel, "the panel should have a window of its own")
      vim.api.nvim_win_close(panel, true)
      H.falsy(G.state().showing, "it is gone for now")

      -- the next animation tick must not error, and should put it back,
      -- because following is still on
      H.wait(3000, function()
        return G.state().showing
      end, "the animation should re-open the panel it still owns")
      G.hide()
    end)
  end)

  H.it("cannot be resurrected by a render after hide", function()
    pretending(true, function()
      G.show()
      G.hide()
      G.render()
      H.falsy(G.state().showing, "render must not re-open a hidden panel")
      H.eq(0, panels())
    end)
  end)

  H.it("is not focusable, so it cannot steal the cursor", function()
    pretending(true, function()
      local win = vim.api.nvim_get_current_win()
      G.show()
      H.eq(win, vim.api.nvim_get_current_win(), "showing it must not move the cursor")
      G.hide()
    end)
  end)
end)

H.describe("follow turns the panel on and off by itself", function()
  H.it("shows it on start and hides it on stop", function()
    if vim.fn.executable("inotifywait") == 0 then
      H.skip("inotify-tools is needed to start a watcher")
    end
    local dir = H.tmpdir("ghost-follow")
    local ok, err = F.start(dir)
    H.ok(ok, tostring(err))
    H.ok(G.state().showing, "the indicator should appear without being asked for")
    H.ok(F.stop())
    H.falsy(G.state().showing, "and go away when following stops")
    H.falsy(G.state().animating)
  end)
end)
