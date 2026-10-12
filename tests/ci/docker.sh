#!/usr/bin/env bash
# The clean-machine check, on a clean machine.
#
#   tests/ci/docker.sh                 # build if needed, then run
#   tests/ci/docker.sh --rebuild       # force a rebuild first
#   NVIM_VERSION=stable tests/ci/docker.sh
#
# What it proves that ./tests/run.sh cannot: that this layer installs and
# passes on a machine with none of the author's configuration, tooling or
# plugin cache on it. Both bugs that shipped in the explorer and the version
# floor were invisible locally and obvious here.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
image=${KEBAB_CI_IMAGE:-kebab-ci}
nvim=${NVIM_VERSION:-v0.12.0}

rebuild=0
[ "${1:-}" = "--rebuild" ] && rebuild=1

if [ "$rebuild" -eq 1 ] || ! docker image inspect "$image" >/dev/null 2>&1; then
  printf '== building %s (Neovim %s)\n' "$image" "$nvim"
  docker build --build-arg "NVIM_VERSION=$nvim" -t "$image" -f "$root/tests/ci/Dockerfile" "$root/tests/ci"
fi

printf '== running the clean-machine check\n'
exec docker run --rm -v "$root:/src:ro" "$image"
