#!/usr/bin/env bash
# kebab.nvim installer.
#
# Run it from a clone:  ./setup.sh
#
# It does three things, each one idempotent and each one skippable:
#   1. writes the lazy.nvim spec into your Neovim config
#   2. puts the `kebab` command on your PATH
#   3. runs `kebab doctor` so you find out what is missing now, not later
#
# Nothing is overwritten without asking. --dry-run shows every action instead
# of taking it.
set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# $KEBAB_NVIM, never $NVIM: Neovim exports **$NVIM** to every child process as
# the RPC socket path of the running instance, so reading it meant that running
# this installer from inside Neovim -- `:terminal ./setup.sh`, which is exactly
# how someone would try it -- attempted to execute a socket and failed with
# "/run/user/1000/nvim.116917.0 is not on PATH". `bin/kebab` always used
# KEBAB_NVIM; this did not. Found by a spec whose child inherited the editor's
# environment.
NVIM=${KEBAB_NVIM:-nvim}
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/nvim
BIN_DIR=${KEBAB_BIN_DIR:-$HOME/.local/bin}
SPEC="$CONFIG/lua/plugins/kebab.lua"

DRY=0
DO_PATH=1
DO_SPEC=1
DO_DOCTOR=1
# install.sh runs the same steps with more after them, so its closing summary
# is the one that should be read; two "Done" sections in one command look like
# two installers stacked.
SHOW_SUMMARY=1
FORCE=0

usage() {
  cat <<USAGE
kebab.nvim setup

  ./setup.sh [options]

Options:
  --dry-run      print what would happen, change nothing
  --no-path      do not touch $BIN_DIR
  --no-spec      do not write the Neovim plugin spec
  --no-doctor    skip the dependency check at the end
  --no-summary   skip the closing summary (install.sh prints its own)
  --force        overwrite an existing plugin spec without asking
  --yes          answer yes to everything (same as --force); for CI, and for
                 an install you do not want to sit through
  -h, --help     this

Environment:
  KEBAB_NVIM     the Neovim binary to use (default: nvim). Not \$NVIM --
                 Neovim exports that to its children as a socket path
  KEBAB_BIN_DIR  where to link the kebab command (default: ~/.local/bin)
USAGE
}

while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1; shift ;;
    --no-path) DO_PATH=0; shift ;;
    --no-spec) DO_SPEC=0; shift ;;
    --no-doctor) DO_DOCTOR=0; shift ;;
    --no-summary) SHOW_SUMMARY=0; shift ;;
    --force | --yes) FORCE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'setup: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '\nsetup failed: %s\n' "$*" >&2; exit 1; }

run() {
  if [ "$DRY" -eq 1 ]; then
    say "would run: $*"
    return 0
  fi
  "$@"
}

write_file() {
  # write_file <path> <<<content
  local path=$1 content
  content=$(cat)
  if [ "$DRY" -eq 1 ]; then
    say "would write $path:"
    printf '%s\n' "$content" | sed 's/^/      /'
    return 0
  fi
  mkdir -p -- "$(dirname -- "$path")"
  printf '%s\n' "$content" > "$path"
}

# Yes/no on a terminal; without one, assume no and say so.
confirm() {
  local prompt=$1
  if [ "$FORCE" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    warn "not a terminal, so assuming no: $prompt (--yes answers yes to everything)"
    return 1
  fi
  local reply
  printf '  %s [y/N] ' "$prompt"
  read -r reply || true
  case $reply in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------------ checks

step "Checking the essentials"

command -v "$NVIM" >/dev/null 2>&1 || die "$NVIM is not on PATH. Install Neovim 0.12 or newer first."

NVIM_VERSION=$("$NVIM" --version | head -1 | sed 's/^NVIM v//')
say "neovim $NVIM_VERSION"
# 0.12 is the floor, and it is checked here because `kebab doctor` checking it
# is too late: the plugins are installed by then. aerial returns from setup()
# after a notify_once below 0.12 -- which deletes the command stub lazy made,
# so :AerialToggle exists at startup and is gone afterwards -- and
# refactoring.nvim raises on load, abandoning the rest of the startup. Both
# were invisible here (0.12.5) and immediate in a container on 0.11.4.
NVIM_MAJOR=${NVIM_VERSION%%.*}
NVIM_REST=${NVIM_VERSION#*.}
NVIM_MINOR=${NVIM_REST%%.*}
if [ "${NVIM_MAJOR:-0}" -eq 0 ] && [ "${NVIM_MINOR:-0}" -lt 12 ]; then
  die "Neovim 0.12 or newer is required (found $NVIM_VERSION)."
fi

command -v git >/dev/null 2>&1 || die "git is not on PATH."
say "git $(git --version | awk '{print $3}')"

if [ ! -d "$CONFIG" ]; then
  # Dying here was the first wall a stranger hit. This layer is a set of
  # lazy.nvim specs, so it needs a LazyVim config to be imported into, and
  # "install LazyVim first" is a second set of instructions to go and follow.
  # Offer to do it -- never silently, because it creates a config in their
  # home directory.
  warn "no Neovim config at $CONFIG."
  if confirm "Clone the LazyVim starter into it?"; then
    command -v git >/dev/null 2>&1 || die "git is not on PATH."
    if [ "$DRY" -eq 1 ]; then
      say "would clone https://github.com/LazyVim/starter into $CONFIG"
    else
      mkdir -p "$(dirname "$CONFIG")"
      git clone --depth 1 https://github.com/LazyVim/starter "$CONFIG" \
        || die "could not clone the LazyVim starter."
      rm -rf "$CONFIG/.git"
      say "cloned the LazyVim starter into $CONFIG"
    fi
  else
    die "nothing was changed. Install LazyVim, then run this again: https://lazyvim.github.io"
  fi
fi
if [ ! -e "$CONFIG/lua/config/lazy.lua" ]; then
  warn "$CONFIG/lua/config/lazy.lua not found -- this expects a LazyVim config."
  confirm "Carry on anyway?" || die "nothing was changed."
fi
# A config that does not belong to this HOME is refused.
#
# Why: testing this installer with a throwaway HOME is routine, and
# $XDG_CONFIG_HOME is *not* derived from $HOME -- so `HOME=/tmp/fake ./setup.sh
# --yes` in a shell that exports XDG_CONFIG_HOME writes the real config and
# replaces the user's own spec. That happened: it cost a file holding this
# machine's project roots and its JDBC timezone, and the only reason nothing
# was lost is the .bak this script keeps. --yes must not wave that through,
# which is why it is an error rather than a prompt.
case "$CONFIG" in
  "$HOME"/*) ;;
  *)
    if [ "${KEBAB_ALLOW_FOREIGN_CONFIG:-0}" != "1" ]; then
      printf '\n'
      warn "refusing to write a config outside your home directory."
      say "  HOME:              $HOME"
      say "  config it chose:   $CONFIG"
      say "  (from \$XDG_CONFIG_HOME, which does not follow \$HOME)"
      say ""
      say "If that is really what you want:"
      say "  XDG_CONFIG_HOME=\"\$HOME/.config\" ./setup.sh      # the usual fix"
      say "  KEBAB_ALLOW_FOREIGN_CONFIG=1 ./setup.sh        # or allow it"
      exit 1
    fi
    warn "writing a config outside \$HOME, because KEBAB_ALLOW_FOREIGN_CONFIG=1"
    ;;
esac

say "config at $CONFIG"
say "this clone is $REPO"

# ------------------------------------------------------- the lazy.nvim spec

if [ "$DO_SPEC" -eq 1 ]; then
  step "Registering the layer with lazy.nvim"

  # A local path, not an owner/repo: it points at this clone, so the layer is
  # yours to edit and lazy does not try to fetch it.
  NEW_SPEC="-- kebab.nvim -- written by setup.sh
-- A local spec: it points at the clone, so edits here apply on the next start.
return {
  {
    dir = \"$REPO\",
    name = \"kebab.nvim\",
    import = \"kebab.plugins\",
  },
}"

  if [ -e "$SPEC" ]; then
    if [ "$DRY" -eq 0 ] && [ "$(cat -- "$SPEC")" = "$NEW_SPEC" ]; then
      say "already registered, unchanged"
    else
      warn "$SPEC already exists."
      if confirm "Replace it? (a .bak copy is kept)"; then
        run cp -- "$SPEC" "$SPEC.bak.$(date +%Y%m%d%H%M%S)"
        write_file "$SPEC" <<<"$NEW_SPEC"
        say "written, previous version kept as a .bak"
      else
        say "left alone -- add this yourself:"
        printf '%s\n' "$NEW_SPEC" | sed 's/^/      /'
      fi
    fi
  else
    write_file "$SPEC" <<<"$NEW_SPEC"
    say "wrote $SPEC"
  fi
fi

# --------------------------------------------- the extras LazyVim arbitrates
#
# LazyVim allows one explorer and one picker, and decides which while its own
# spec is built -- before this layer's spec exists. A nested import is
# invisible to that decision, so on a fresh config snacks explorer wins and
# `lazyvim.plugins.extras.editor.neo-tree` is refused with no warning at all:
# the always-on tree, the tree right-click menu and the pinned database panes
# have nothing to attach to. The one place LazyVim looks in time is its own
# lazyvim.json, which is what `:LazyExtras` writes -- so this merges the entry
# into it, keeping whatever else is there.
if [ "$DO_SPEC" -eq 1 ]; then
  step "Recording the file explorer LazyVim should use"
  if [ "$DRY" -eq 1 ]; then
    say "would add lazyvim.plugins.extras.editor.neo-tree to $CONFIG/lazyvim.json"
  else
    EXTRA_OUT=$("$NVIM" -n --headless --noplugin \
      --cmd "set runtimepath+=$REPO" \
      -c "lua local J = require('kebab.lazyvimjson')
          local changed, err, added = J.ensure({ path = '$CONFIG/lazyvim.json' })
          if err then print('ERR ' .. err)
          elseif changed then print('ADDED ' .. table.concat(added, ' '))
          else print('ALREADY') end" \
      -c "qa!" 2>&1 | tail -n 1)
    case "$EXTRA_OUT" in
      ADDED*) say "added the neo-tree extra to $CONFIG/lazyvim.json" ;;
      ALREADY*) say "already recorded" ;;
      *) warn "could not update $CONFIG/lazyvim.json: ${EXTRA_OUT#ERR }"
         say "add \"lazyvim.plugins.extras.editor.neo-tree\" to its extras list by hand" ;;
    esac
  fi
fi

# ------------------------------------------------------------- the command

if [ "$DO_PATH" -eq 1 ]; then
  step "Putting the kebab command on your PATH"

  TARGET="$BIN_DIR/kebab"
  run mkdir -p -- "$BIN_DIR"

  if [ -L "$TARGET" ] && [ "$(readlink -f -- "$TARGET")" = "$REPO/bin/kebab" ]; then
    say "already linked: $TARGET"
  elif [ -e "$TARGET" ]; then
    warn "$TARGET already exists and is not a link to this clone."
    if confirm "Replace it?"; then
      run ln -sfn -- "$REPO/bin/kebab" "$TARGET"
      say "relinked $TARGET"
    else
      say "left alone -- link it yourself: ln -s $REPO/bin/kebab $TARGET"
    fi
  else
    run ln -s -- "$REPO/bin/kebab" "$TARGET"
    say "linked $TARGET"
  fi

  case ":$PATH:" in
    *":$BIN_DIR:"*) say "$BIN_DIR is on PATH" ;;
    *)
      warn "$BIN_DIR is NOT on your PATH. Add this to your shell profile:"
      say "    export PATH=\"\$PATH:$BIN_DIR\""
      ;;
  esac
fi

# ------------------------------------------------------- shell completion

if [ "$DO_PATH" -eq 1 ]; then
  step "Teaching your shell to complete kebab"

  # Linked, not copied: the clone is the source of truth everywhere else in
  # this installer, and a copy would go stale the moment the completion
  # changes.
  BASH_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
  ZSH_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions"

  link_completion() { # source target shell
    local src=$1
    local dst=$2
    local shell=$3
    if [ -L "$dst" ] && [ "$(readlink -f -- "$dst")" = "$(readlink -f -- "$src")" ]; then
      say "$shell: already linked"
      return
    fi
    if [ -e "$dst" ]; then
      warn "$dst already exists."
      if confirm "Replace it?"; then
        run ln -sfn -- "$src" "$dst"
        say "$shell: relinked"
      else
        say "$shell: left alone -- link it yourself: ln -s $src $dst"
      fi
      return
    fi
    run mkdir -p -- "$(dirname -- "$dst")"
    run ln -s -- "$src" "$dst"
    say "$shell: linked $dst"
  }

  link_completion "$REPO/completions/kebab.bash" "$BASH_DIR/kebab" bash
  link_completion "$REPO/completions/_kebab" "$ZSH_DIR/_kebab" zsh

  # zsh only looks in directories on its fpath, and that one is not there by
  # default -- so say the single line that fixes it rather than leaving a file
  # nothing reads.
  case "${SHELL##*/}" in
    zsh)
      say "add this to ~/.zshrc if completion does not work after a restart:"
      say "    fpath=($ZSH_DIR \$fpath)"
      ;;
  esac
  say "open a new shell, then: kebab <Tab>"

  # Warm the cache the completion reads, so the first <Tab> in a new shell
  # offers project types and connections rather than only the command names.
  # @see lua/kebab/complete.lua
  if [ "$DRY" -eq 0 ]; then
    # -u NONE --noplugin: the cache needs this layer's own modules and nothing
    # else, and booting the *user's* config here is a first start -- which on a
    # fresh install means lazy.nvim installing seventy plugins and mason
    # starting on its own list, from an installer step that only wanted to
    # write a 43-line file. A leash too, because a step that can hang must not.
    timeout 60 "$NVIM" -n --headless -u NONE --noplugin \
      --cmd "set runtimepath+=$REPO" \
      -c "lua require('kebab.complete').write()" -c "qa!" >/dev/null 2>&1 \
      && say "completion cache written" \
      || warn "could not write the completion cache; it will fill in on first use"
  fi
fi

# ----------------------------------------------------------------- doctor

if [ "$DO_DOCTOR" -eq 1 ] && [ "$DRY" -eq 0 ]; then
  step "Checking what the languages you use need"
  say "(nothing is installed for you: a toolchain is the project's business)"
  printf '\n'
  # Non-zero only means something required is missing; report it, do not abort,
  # because the layer itself is installed either way.
  # KEBAB_NVIM, not NVIM: bin/kebab reads that name, and handing a child
  # $NVIM is the very confusion this rename was for.
  if KEBAB_NVIM="$NVIM" "$REPO/bin/kebab" doctor; then
    :
  else
    warn "doctor reported something missing -- see above."
  fi
fi

if [ "$SHOW_SUMMARY" -eq 1 ]; then
  step "Done"
  say "Start Neovim. Mason installs the tooling on first launch."
  say "A Maven project takes about a minute to index the first time."
  say "Keymaps: :IdeCheatsheet   Everything else: :Ide<Tab>"
fi
