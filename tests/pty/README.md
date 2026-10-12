# Mouse tests

A headless Neovim has **no screen grid**, so `nvim_input_mouse()` is dropped
and `vim.fn.feedkeys("<2-LeftMouse>")` does nothing. Two separate claims that
"the double click works" were made here on the strength of a registered
mapping, and both were wrong: the mapping was there and the click did nothing.

`drive.py` runs a real Neovim under a pty, with a real UI attached
(`#vim.api.nvim_list_uis() == 1`), and sends the SGR mouse reports a terminal
emulator sends. The editor under test writes a report file and quits, so the
assertions are made on buffer and window state rather than by scraping the
screen.

Not part of `./tests/run.sh`: each case boots a full editor and waits on a real
database, which is ~60s a case. Run it when mouse behaviour changes.

```bash
./tests/pty/run.sh
```

A case is a JSON file:

```json
{ "nvim_args": ["-n", "-c", "luafile /path/to/child.lua"],
  "actions": [ {"kind": "wait", "seconds": 12},
               {"kind": "click", "col": 6, "row": 5, "count": 2},
               {"kind": "keys", "text": "jj"} ],
  "report": "/tmp/report.txt", "idle": 2, "limit": 120 }
```

`count: 2` sends two press/release pairs 80ms apart, which is inside the
default `'mousetime'` (500ms), so Neovim counts them as one double click.
