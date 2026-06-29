# Ubuntu-based image that runs rubino-agent FROM SOURCE, for manual testing.
#
#   Build:  docker build -t rubino:latest .
#   Run:    docker run --rm -it \
#             -v "$PWD":/work \                  # the dir the agent works on
#             -v "$HOME/.rubino":/root/.rubino \ # reuse your host config + keys
#             rubino:latest rubino
#
# The agent is launched via the `rubino` wrapper from any cwd; mount your project
# at /work. Secrets are NEVER baked in — provide them by mounting ~/.rubino or
# passing *_API_KEY env vars (-e RUBINO_API_KEY=...).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    TERM=xterm-256color \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Two groups: (1) runtime tools the agent shells out to — git, ripgrep, sqlite3,
# tmux, curl, less, procps; (2) the toolchain ruby-build (via mise) needs to
# COMPILE Ruby 3.3.3 and the native gems (nokogiri / ffi / sqlite3).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git less procps tmux ripgrep sqlite3 \
      build-essential autoconf bison \
      libssl-dev libyaml-dev libreadline-dev zlib1g-dev \
      libncurses-dev libffi-dev libgdbm-dev libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

# Ruby 3.3.3 via mise — Ubuntu's apt ships only 3.2, but the repo pins 3.3.3
# (.ruby-version), so we compile the exact version. Put the install's bin dir
# straight on PATH (no shims) so ruby/gem/bundler resolve deterministically.
ENV MISE_DATA_DIR=/opt/mise \
    PATH=/opt/mise/installs/ruby/3.3.3/bin:/usr/local/bin:$PATH
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && mise install ruby@3.3.3 \
    && gem install bundler -v 4.0.12

WORKDIR /app
COPY . /app
# The lockfile is resolved on macOS (arm64-darwin); add the Linux platforms so
# `bundle install` stays in lockstep with the pinned versions instead of
# re-resolving, then install.
RUN bundle lock --add-platform x86_64-linux aarch64-linux \
    && bundle install

# Run rubino from the source checkout WITHOUT changing the caller's cwd, so the
# agent operates on the mounted /work dir, not /app. (A source checkout has no
# working binstub; this wrapper replaces it.)
RUN printf '#!/usr/bin/env bash\nexport BUNDLE_GEMFILE=/app/Gemfile\nexec bundle exec /app/exe/rubino "$@"\n' \
      > /usr/local/bin/rubino \
    && chmod +x /usr/local/bin/rubino

ENV RUBINO_HOME=/root/.rubino
RUN mkdir -p /root/.rubino /work
WORKDIR /work
CMD ["bash"]
