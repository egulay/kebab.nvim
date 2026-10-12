#!/usr/bin/env bash
# Install this layer the way a stranger would, into a config that does not
# exist yet, and then run its tests.
#
#   tests/ci/bootstrap.sh
#
# Why it exists: tests/run.sh deliberately boots the *real* user config,
# because the bugs this layer has are integration bugs. That makes the suite
# worthless as evidence that the layer works on a machine other than the one
# it was written on -- every "verified" claim in this repo was verified on a
# single box, with one Neovim, one font, one terminal and one plugin set.
#
# This script builds a config from nothing in a throwaway HOME: the LazyVim
# starter, then ./setup.sh, then `nvim --headless "+Lazy! sync"`, then the
# suite. It is what CI runs, and running it locally is the same test.
#
# Needs: git, nvim (>= 0.12), and whatever the suite needs -- a JDK for the
# database specs, sqlite3, inotify-tools. `kebab doctor` lists the rest and is
# run at the end on purpose.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="${KEBAB_CI_HOME:-$(mktemp -d -t kebab-ci-XXXXXX)}"
keep="${KEBAB_CI_KEEP:-0}"

say() { printf '\n== %s\n' "$1"; }
fail() { printf '\nFAILED: %s\n' "$1" >&2; exit 1; }

cleanup() {
  if [ "$keep" = "1" ]; then
    printf '\nkept: %s\n' "$work"
    return
  fi
  # Go's module cache is written read-only on purpose, so a plain `rm -rf`
  # prints a "Permission denied" line *per file* -- three hundred of them in
  # CI, after the test results, which is where the reader looks. The failure
  # that mattered was the line above all that noise. Make it writable first,
  # and say nothing either way: this is a temporary directory being removed.
  chmod -R u+w "$work" >/dev/null 2>&1 || true
  rm -rf "$work" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A HOME of its own. Everything Neovim and lazy.nvim write lands here, so the
# run cannot read -- or damage -- the config of whoever started it.
export HOME="$work"
export XDG_CONFIG_HOME="$work/.config"
export XDG_DATA_HOME="$work/.local/share"
export XDG_STATE_HOME="$work/.local/state"
export XDG_CACHE_HOME="$work/.cache"
export PATH="$work/.local/bin:$PATH"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$work/.local/bin"

# git needs an identity for the specs that build scratch repositories
export GIT_CONFIG_NOSYSTEM=1
git config --global user.email "ci@example.com"
git config --global user.name "kebab ci"
git config --global init.defaultBranch main

say "neovim"
nvim --version | head -2 || fail "nvim is not on PATH"
# The floor, stated here as well as in doctor: below it aerial and
# refactoring refuse to initialise, and the suite fails in ways that say
# nothing about this layer.
nvim --headless -n -c 'lua os.exit(vim.fn.has("nvim-0.12") == 1 and 0 or 1)' -c qa \
  || fail "this layer needs Neovim 0.12 or newer"

say "the LazyVim starter, into a config that did not exist"
git clone --depth 1 https://github.com/LazyVim/starter "$XDG_CONFIG_HOME/nvim" \
  || fail "could not clone the LazyVim starter"
rm -rf "$XDG_CONFIG_HOME/nvim/.git"

say "./setup.sh, as a stranger runs it"
# --yes so nothing waits for an answer; the point is that it needs no answers
# on a clean machine. KEBAB_BIN_DIR keeps the symlink inside the throwaway
# HOME rather than in ~/.local/bin.
KEBAB_BIN_DIR="$work/.local/bin" "$root/setup.sh" --yes --no-doctor \
  || fail "setup.sh did not complete"

test -f "$XDG_CONFIG_HOME/nvim/lua/plugins/kebab.lua" \
  || fail "setup.sh did not write the lazy spec"
test -x "$work/.local/bin/kebab" \
  || fail "setup.sh did not put kebab on PATH"

# Deterministic, not well equipped: mason's installs are abandoned when this
# editor exits, and what survives differs every run. @see plugins/mason.lua
export KEBAB_NO_MASON_INSTALL=1

say "installing the plugins (this is where a bad pin shows up)"
nvim --headless -n "+Lazy! sync" +qa 2>&1 | tail -20
# Lazy writes nothing to stdout on success, so the check is the lockfile
test -f "$XDG_CONFIG_HOME/nvim/lazy-lock.json" || fail "lazy installed nothing"
printf 'plugins installed: %s\n' "$(grep -c '": {' "$XDG_CONFIG_HOME/nvim/lazy-lock.json")"

# mason.nvim *prepends* its bin directory to PATH, and `nvim +Lazy! sync +qa`
# exits while its installs are still running -- it says so: "Neovim is exiting
# while packages are still installing. Terminating all installations". Whatever
# that leaves behind shadows the real tool: a half-installed gopls made four
# specs wait out their 120s attach budget and fail with "no language server
# attached", which names neither mason nor the install it aborted. Anything in
# there that cannot answer `--version` is removed.
say "pruning anything mason left half-installed"
pruned=0
for binary in "$XDG_DATA_HOME"/nvim/mason/bin/*; do
  [ -e "$binary" ] || continue
  if ! "$binary" --version >/dev/null 2>&1 && ! "$binary" version >/dev/null 2>&1; then
    rm -f "$binary"
    pruned=$((pruned + 1))
    printf '  removed %s (it does not run)\n' "$(basename "$binary")"
  fi
done
printf 'pruned: %d\n' "$pruned"

say "every plugin this layer reaches into, at the commit it was pinned to"
for pin in $(grep -rhoE '[0-9a-f]{40}' "$root/lua/kebab/plugins/"*.lua | sort -u); do
  name=$(grep -rl "$pin" "$XDG_DATA_HOME/nvim/lazy/"*/.git/HEAD 2>/dev/null | head -1)
  printf '  %s %s\n' "${pin:0:12}" "${name:-(not matched to a clone)}"
done

say "kebab doctor"
"$work/.local/bin/kebab" doctor
doctor=$?
printf 'doctor exit: %d\n' "$doctor"

say "the test suite, against this freshly built config"
"$root/tests/run.sh"
suite=$?

say "result"
printf 'suite exit: %d   doctor exit: %d\n' "$suite" "$doctor"
# doctor exits non-zero when something *required* is missing, which on a bare
# container it will be (a JDK, a toolchain). That is information, not failure:
# the gate is the suite.
[ "$suite" -eq 0 ] || fail "the suite did not pass on a clean machine"
printf '\nclean-machine run passed.\n'
