-- The Ghost Mode indicator: the panel that appears by itself while
-- :IdeFollow is on, so a cursor moving on its own is explained rather than
-- alarming.
local H = ...
local G = require("kebab.ghostbar")
local F = require("kebab.follow")

---Run `fn` with follow.running() reporting `value`.
---
---The indicator config is pinned to the shipped default too. The suite boots
---the real user config on purpose, so a config that sets
---`vim.g.kebab_follow_indicator` -- turning the panel off, say -- would
---otherwise fail every test here, which is a legitimate setting and not a
---regression. A test that wants a particular config sets it *inside* `fn`.
local function pretending(value, fn)
  local real = F.running
  local saved = vim.g.kebab_follow_indicator
  vim.g.kebab_follow_indicator = nil
  F.running = function()
    return value
  end
  local ok, err = pcall(fn)
  F.running = real
  vim.g.kebab_follow_indicator = saved
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
    pretending(true, function()
      -- an activity window of 0ms, so the name is stale immediately
      vim.g.kebab_follow_indicator = { activity_ms = 0 }
      G.show()
      G.activity("/x/Thing.java")
      H.matches("1 change", G.state().text, "it should report the count: " .. G.state().text)
      G.hide()
    end)
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
    pretending(true, function()
      vim.g.kebab_follow_indicator = false
      H.falsy(G.show(), "show should decline when the indicator is disabled")
      H.falsy(G.state().showing)
      H.eq(0, panels())
    end)
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

-- The panel is an *activity* light, not a status light: it appears because
-- something touched the project, and hides again once things are quiet. A
-- badge that sits there permanently says nothing about whether an agent is
-- doing anything, which is the only question it answers.
H.describe("the panel reports activity, not readiness", function()
  H.it("stays hidden while following is merely armed", function()
    if vim.fn.executable("inotifywait") == 0 then
      H.skip("inotify-tools is needed to start a watcher")
    end
    local saved = vim.g.kebab_follow_indicator
    vim.g.kebab_follow_indicator = nil
    local ran, err = pcall(function()
      local ok, serr = F.start(H.tmpdir("armed"))
      H.ok(ok, tostring(serr))
      H.drain(400)
      H.falsy(G.state().showing, "nothing has happened, so there is nothing to show")
      H.eq("", G.state().text, "and no text either")
    end)
    pcall(F.stop)
    vim.g.kebab_follow_indicator = saved
    H.ok(ran, tostring(err))
  end)

  H.it("appears when something touches the project, naming the file", function()
    pretending(true, function()
      H.falsy(G.state().showing)
      G.activity("/p/src/Thing.java")
      H.ok(G.state().showing, "an agent touching a file is what puts it on screen")
      H.matches("Thing%.java", G.state().text)
      G.hide()
    end)
  end)

  H.it("hides itself once things have been quiet", function()
    pretending(true, function()
      -- an idle window of 1ms, so it is stale immediately
      vim.g.kebab_follow_indicator = { idle_ms = 1 }
      G.activity("/p/src/Thing.java")
      H.ok(G.state().showing, "it should be up at first")
      H.wait(5000, function()
        return not G.state().showing
      end, "the panel should hide itself when nothing is happening")
    end)
  end)

  H.it("comes back for the next change", function()
    pretending(true, function()
      vim.g.kebab_follow_indicator = { idle_ms = 1 }
      G.activity("/p/one.go")
      H.wait(5000, function()
        return not G.state().showing
      end, "it should go quiet first")
      G.activity("/p/two.go")
      H.ok(G.state().showing, "a new change must bring it back")
      H.matches("two%.go", G.state().text)
      G.hide()
    end)
  end)

  H.it("goes away when following stops", function()
    if vim.fn.executable("inotifywait") == 0 then
      H.skip("inotify-tools is needed to start a watcher")
    end
    local saved = vim.g.kebab_follow_indicator
    vim.g.kebab_follow_indicator = nil
    local ran, err = pcall(function()
      H.ok(F.start(H.tmpdir("ghost-stop")))
      G.activity("/p/something.go")
      H.ok(G.state().showing, "showing because something happened")
      H.ok(F.stop())
      H.falsy(G.state().showing, "and gone once following stops")
      H.falsy(G.state().animating)
    end)
    pcall(F.stop)
    vim.g.kebab_follow_indicator = saved
    H.ok(ran, tostring(err))
  end)
end)
