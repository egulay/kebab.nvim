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
NVIM=${NVIM:-nvim}
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/nvim
BIN_DIR=${KEBAB_BIN_DIR:-$HOME/.local/bin}
SPEC="$CONFIG/lua/plugins/kebab.lua"

DRY=0
DO_PATH=1
DO_SPEC=1
DO_DOCTOR=1
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
  --force        overwrite an existing plugin spec without asking
  -h, --help     this

Environment:
  NVIM           the Neovim binary to use (default: nvim)
  KEBAB_BIN_DIR  where to link the kebab command (default: ~/.local/bin)
USAGE
}

while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1; shift ;;
    --no-path) DO_PATH=0; shift ;;
    --no-spec) DO_SPEC=0; shift ;;
    --no-doctor) DO_DOCTOR=0; shift ;;
    --force) FORCE=1; shift ;;
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
    warn "not a terminal, so assuming no: $prompt (use --force to say yes)"
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

command -v "$NVIM" >/dev/null 2>&1 || die "$NVIM is not on PATH. Install Neovim 0.11 or newer first."

NVIM_VERSION=$("$NVIM" --version | head -1 | sed 's/^NVIM v//')
say "neovim $NVIM_VERSION"
# 0.11 is the floor: this layer uses vim.uv, vim._watch and vim.system.
NVIM_MAJOR=${NVIM_VERSION%%.*}
NVIM_REST=${NVIM_VERSION#*.}
NVIM_MINOR=${NVIM_REST%%.*}
if [ "${NVIM_MAJOR:-0}" -eq 0 ] && [ "${NVIM_MINOR:-0}" -lt 11 ]; then
  die "Neovim 0.11 or newer is required (found $NVIM_VERSION)."
fi

command -v git >/dev/null 2>&1 || die "git is not on PATH."
say "git $(git --version | awk '{print $3}')"

if [ ! -d "$CONFIG" ]; then
  die "no Neovim config at $CONFIG. Install LazyVim first: https://lazyvim.github.io"
fi
if [ ! -e "$CONFIG/lua/config/lazy.lua" ]; then
  warn "$CONFIG/lua/config/lazy.lua not found -- this expects a LazyVim config."
  confirm "Carry on anyway?" || die "nothing was changed."
fi
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

# ----------------------------------------------------------------- doctor

if [ "$DO_DOCTOR" -eq 1 ] && [ "$DRY" -eq 0 ]; then
  step "Checking what the languages you use need"
  say "(nothing is installed for you: a toolchain is the project's business)"
  printf '\n'
  # Non-zero only means something required is missing; report it, do not abort,
  # because the layer itself is installed either way.
  if NVIM="$NVIM" "$REPO/bin/kebab" doctor; then
    :
  else
    warn "doctor reported something missing -- see above."
  fi
fi

step "Done"
say "Start Neovim. Mason installs the tooling on first launch."
say "A Maven project takes about a minute to index the first time."
say "Keymaps: :IdeCheatsheet   Everything else: :Ide<Tab>"
