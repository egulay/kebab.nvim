# bash completion for kebab.
#
# Everything is decided by `kebab __complete`, which answers in about 3ms
# because it reads a cache rather than starting an editor -- a completion that
# shells out to the thing it completes is one nobody keeps installed.
#
# Three sentinels ask the shell to do what only the shell can: __files,
# __dirs and __nothing (the word is the user's to invent, so offer nothing
# rather than every file in the directory).
_kebab() {
  local line files=0 dirs=0
  local -a candidates=()
  while IFS= read -r line; do
    case "$line" in
      __files) files=1 ;;
      __dirs) dirs=1 ;;
      __nothing) ;;
      "") ;;
      *) candidates+=("$line") ;;
    esac
  done < <(kebab __complete "$COMP_CWORD" "${COMP_WORDS[@]}" 2>/dev/null)

  COMPREPLY=()
  local current=${COMP_WORDS[COMP_CWORD]}
  if ((${#candidates[@]})); then
    while IFS= read -r line; do
      COMPREPLY+=("$line")
    done < <(compgen -W "$(printf '%s\n' "${candidates[@]}")" -- "$current")
  fi
  if ((files)); then
    while IFS= read -r line; do
      COMPREPLY+=("$line")
    done < <(compgen -f -- "$current")
    compopt -o filenames 2>/dev/null
  fi
  if ((dirs)); then
    while IFS= read -r line; do
      COMPREPLY+=("$line")
    done < <(compgen -d -- "$current")
    compopt -o filenames 2>/dev/null
  fi
}

complete -F _kebab kebab
