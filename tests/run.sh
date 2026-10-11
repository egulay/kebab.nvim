#!/usr/bin/env bash
# Run the kebab.nvim test suite.
#
#   tests/run.sh                 everything
#   tests/run.sh project         only specs whose name contains "project"
#
# Runs headless with -n (no swap file). CLAUDE.md explains why that matters:
# a killed headless session that had swap enabled leaves an E325 landmine in
# the user's real files.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="${KEBAB_TEST_SCRATCH:-$(mktemp -d -t kebab-tests-XXXXXX)}"
export KEBAB_TEST_SCRATCH="$scratch"
[ $# -gt 0 ] && export KEBAB_TEST_ONLY="$1"

# A real git identity may be missing in CI; the harness sets one per repo.
export GIT_CONFIG_NOSYSTEM=1

timeout "${KEBAB_TEST_TIMEOUT:-600}" nvim -n --headless \
  --cmd "set runtimepath+=$root" \
  -c "luafile $root/tests/run.lua"
code=$?

if [ "${KEBAB_TEST_KEEP:-0}" != "1" ]; then
  case "$scratch" in
    /tmp/*|/var/folders/*) rm -rf "$scratch" ;;
  esac
else
  echo "scratch kept: $scratch"
fi

exit $code
