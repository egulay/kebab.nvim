#!/usr/bin/env bash
# kebab.nvim, in one command.
#
# From a clone:
#
#     ./install.sh
#
# From nothing, without cloning first:
#
#     curl -fsSL <this file's raw URL> | bash
#
# Either way it ends with a working editor: it clones the layer if it has to,
# clones the LazyVim starter if there is no Neovim config, writes the plugin
# spec, puts `kebab` on PATH, installs the plugins, and tells you what is
# still missing. It asks nothing -- `--ask` if you would rather it did.
#
# Options:
#   --ask          confirm each step instead of assuming yes
#   --dir <path>   where to put the clone (default ~/Projects/kebab.nvim)
#   --dry-run      print what would happen, change nothing
#
# Environment:
#   KEBAB_REPO     the git URL to clone (default: this clone's origin)
#   KEBAB_DIR      same as --dir
set -euo pipefail

BOLD=$(printf '\033[1m')
DIM=$(printf '\033[2m')
OFF=$(printf '\033[0m')

step() { printf '\n%s%s%s\n' "$BOLD" "$1" "$OFF"; }
say() { printf '  %s\n' "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$OFF"; }
die() {
  printf '\ninstall failed: %s\n' "$1" >&2
  exit 1
}

ASK=0
DRY=0
DEST=${KEBAB_DIR:-$HOME/Projects/kebab.nvim}

while [ $# -gt 0 ]; do
  case $1 in
    --ask) ASK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --dir) shift; [ $# -gt 0 ] || die "--dir needs a path"; DEST=$1; shift ;;
    --dir=*) DEST=${1#--dir=}; shift ;;
    -h | --help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# Where this script is running from. A pipe has no file, so $0 is "bash" or
# "-" and `dirname` would answer "." -- which is why the clone is detected by
# looking for the layer itself rather than by trusting $0.
here=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
fi

step "kebab.nvim"

command -v git >/dev/null 2>&1 || die "git is not on PATH."
command -v "${NVIM:-nvim}" >/dev/null 2>&1 \
  || die "${NVIM:-nvim} is not on PATH. Install Neovim 0.11 or newer first."

# ------------------------------------------------------------------- the clone

if [ -n "$here" ] && [ -f "$here/setup.sh" ] && [ -d "$here/lua/kebab" ]; then
  REPO=$here
  say "using this clone: $REPO"
else
  URL=${KEBAB_REPO:-}
  if [ -z "$URL" ]; then
    die "run this from a clone, or set KEBAB_REPO to the git URL to clone from."
  fi
  if [ -d "$DEST/.git" ]; then
    say "updating the clone at $DEST"
    if [ "$DRY" -eq 0 ]; then
      git -C "$DEST" pull --ff-only --quiet || note "could not fast-forward; using it as it is"
    fi
  else
    say "cloning into $DEST"
    if [ "$DRY" -eq 0 ]; then
      mkdir -p "$(dirname "$DEST")"
      git clone --quiet "$URL" "$DEST" || die "could not clone $URL"
    fi
  fi
  REPO=$DEST
fi

# ------------------------------------------------------------------- the setup

step "Setting it up"
args=()
# Written as `if`, not `[ ... ] && ...`: a false test is the last command of
# the line, so under `set -e` the script would exit on it.
if [ "$ASK" -eq 0 ]; then args+=(--yes); fi
if [ "$DRY" -eq 1 ]; then args+=(--dry-run); fi
# doctor runs at the end of this script instead, after the plugins are in --
# otherwise it reports the language servers as missing when they are simply
# not installed yet.
args+=(--no-doctor)

if [ "$DRY" -eq 1 ] && [ ! -x "$REPO/setup.sh" ]; then
  note "would run $REPO/setup.sh ${args[*]}"
else
  "$REPO/setup.sh" "${args[@]}" || die "setup.sh did not complete"
fi

# ------------------------------------------------------------------ the plugins

step "Installing the plugins"
if [ "$DRY" -eq 1 ]; then
  note "would run: nvim --headless \"+Lazy! sync\" +qa"
else
  say "this takes a minute the first time"
  "${NVIM:-nvim}" --headless -n "+Lazy! sync" +qa >/dev/null 2>&1 || true
  config=${XDG_CONFIG_HOME:-$HOME/.config}/nvim
  if [ -f "$config/lazy-lock.json" ]; then
    say "$(grep -c '": {' "$config/lazy-lock.json") plugins installed"
  else
    note "lazy.nvim wrote no lockfile; open nvim and run :Lazy to see why"
  fi
fi

# ------------------------------------------------------------------- the report

step "What is still missing"
kebab=${KEBAB_BIN_DIR:-$HOME/.local/bin}/kebab
if [ "$DRY" -eq 1 ]; then
  note "would run: kebab doctor"
elif [ -x "$kebab" ]; then
  "$kebab" doctor || true
else
  note "kebab is not on PATH yet; run $REPO/bin/kebab doctor"
fi

step "Done"
say "open a project:   kebab ~/some/project"
say "the SQL IDE:      kebab db"
say "the keymaps:      :IdeCheatsheet   (or press Space and wait)"
case ":$PATH:" in
  *":${KEBAB_BIN_DIR:-$HOME/.local/bin}:"*) ;;
  *) note "add ${KEBAB_BIN_DIR:-$HOME/.local/bin} to your PATH to use the kebab command" ;;
esac
