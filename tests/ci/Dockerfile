# A machine that is not the one this layer was written on.
#
# tests/ci/bootstrap.sh installs the layer into a throwaway HOME and runs the
# suite; this gives it a throwaway *machine* as well, so "it works" stops
# meaning "it works here". Everything the suite needs is installed explicitly,
# which is also the list CI installs -- when the two drift, this file is the
# one that gets run by hand, so it is the one to keep honest.
#
#   docker build -t kebab-ci -f tests/ci/Dockerfile tests/ci
#   docker run --rm -v "$PWD:/src:ro" kebab-ci
#
# tests/ci/docker.sh does both.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# The floor. 0.12 because aerial and refactoring refuse to initialise below
# it -- which running this on 0.11.4 is what proved.
ARG NVIM_VERSION=v0.12.0

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      git curl ca-certificates unzip xz-utils jq fontconfig \
      xdg-utils \
      sqlite3 inotify-tools \
      python3 python3-venv \
      nodejs npm \
      openjdk-21-jdk-headless \
    && rm -rf /var/lib/apt/lists/*

# Neovim from the release tarball: the distribution package is far older than
# the floor this layer states.
RUN curl -fsSL -o /tmp/nvim.tar.gz \
      "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-x86_64.tar.gz" \
    && tar -C /opt -xzf /tmp/nvim.tar.gz \
    && ln -s /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim \
    && rm /tmp/nvim.tar.gz

# lazygit is not in the distribution repositories, and LazyVim binds
# <leader>gg only when it is installed -- three menu entries advertise that
# key, so without it they are reported as unmapped.
# The version comes from the redirect of /releases/latest, not from the API:
# the API is rate limited per IP for anonymous callers and a build that worked
# in the morning fails in the afternoon with no useful message.
RUN LG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
          https://github.com/jesseduffield/lazygit/releases/latest | sed 's#.*/tag/v##') \
    && curl -fsSL -o /tmp/lazygit.tar.gz \
      "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LG}_Linux_x86_64.tar.gz" \
    && tar -C /usr/local/bin -xzf /tmp/lazygit.tar.gz lazygit \
    && rm /tmp/lazygit.tar.gz

# Go, and gopls built from it. CI installs both, and the whole point of this
# image is that a failure shows up here rather than in CI: the gopls specs
# skipped locally and ran there, which is exactly how a half-installed mason
# gopls got to spend 480 seconds of a 600 second budget before anyone saw it.
ARG GO_VERSION=1.27.2
RUN curl -fsSL -o /tmp/go.tar.gz \
      "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
    && tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}" GOTOOLCHAIN=local
RUN GOBIN=/usr/local/bin go install golang.org/x/tools/gopls@latest \
    && gopls version && rm -rf /root/go /root/.cache/go-build

RUN useradd -m tester
USER tester
WORKDIR /home/tester

# The repo is mounted read-only at /src and copied, because the run writes
# into the clone (scratch directories, a lazy-lock) and must not touch yours.
CMD cp -r /src /home/tester/kebab.nvim \
    && cd /home/tester/kebab.nvim \
    && git config --global --add safe.directory /home/tester/kebab.nvim \
    && ./tests/ci/bootstrap.sh
