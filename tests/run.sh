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

# Only a directory this script created is ever deleted. The old guard was a
# `/tmp/*` glob, which cannot tell mktemp's own output from a path the caller
# passed in -- so KEBAB_TEST_SCRATCH=/tmp/my-workspace was wiped on exit, and
# a trailing slash made the pattern match "/tmp/" itself (the `*` matches the
# empty string), which would have ended the run with `rm -rf /tmp/`.
if [ -n "${KEBAB_TEST_SCRATCH:-}" ]; then
  scratch="$KEBAB_TEST_SCRATCH"
  scratch_is_ours=0
  mkdir -p "$scratch"
else
  scratch="$(mktemp -d -t kebab-tests-XXXXXX)"
  scratch_is_ours=1
fi
export KEBAB_TEST_SCRATCH="$scratch"
[ $# -gt 0 ] && export KEBAB_TEST_ONLY="$1"

# A real git identity may be missing in CI; the harness sets one per repo.
export GIT_CONFIG_NOSYSTEM=1

timeout "${KEBAB_TEST_TIMEOUT:-600}" nvim -n --headless \
  --cmd "set runtimepath+=$root" \
  -c "luafile $root/tests/run.lua"
code=$?

if [ "${KEBAB_TEST_KEEP:-0}" = "1" ]; then
  echo "scratch kept: $scratch"
elif [ "$scratch_is_ours" = "1" ]; then
  # mktemp made it, so it is ours to remove -- wherever $TMPDIR points.
  rm -rf -- "$scratch"
else
  echo "scratch kept (you supplied it): $scratch"
fi

exit $code
