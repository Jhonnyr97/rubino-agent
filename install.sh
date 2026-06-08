#!/usr/bin/env bash
#
# rubino installer
#
#   curl -fsSL https://raw.githubusercontent.com/Jhonnyr97/rubino-agent/main/install.sh | bash
#
# What it does (all in user space, no sudo):
#   1. Installs `rv` (https://github.com/spinel-coop/rv), a fast Ruby version
#      manager, if it isn't already present.
#   2. Uses rv to install a compatible Ruby (precompiled, no build step).
#   3. Installs the `rubino-agent` gem under that Ruby. If a published gem with
#      the CLI isn't available yet, it falls back to building from this repo.
#   4. Prints the exact PATH line for the `rubino` executable.
#
# Security note: you are piping a script from the internet into a shell.
# Review it first:  curl -fsSL <url> -o install.sh && less install.sh && bash install.sh
#
# Re-running is safe: every step is idempotent.

set -euo pipefail

# --- configuration ----------------------------------------------------------

REPO_OWNER="Jhonnyr97"
REPO_NAME="rubino-agent"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
REPO_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"

# Ruby to install via rv. Matches the gem's .ruby-version; the gem itself
# requires >= 3.1.0, so any 3.1+ works, but we pin a known-good precompiled one.
RUBY_VERSION="${RUBINO_RUBY_VERSION:-3.3.3}"

# The gem name on RubyGems (rubino-agent) vs. the executable it ships (rubino).
GEM_NAME="rubino-agent"
BIN_NAME="rubino"

# --- output helpers ---------------------------------------------------------

if [ -t 1 ]; then
  BOLD=$(printf '\033[1m'); GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m')
  RED=$(printf '\033[31m'); DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m')
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; DIM=""; RESET=""
fi

info()  { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
ok()    { printf '%s==>%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '%s==>%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()   { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# --- preflight: OS / arch ---------------------------------------------------

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux) ;;
  Darwin)
    die "this installer is Linux-only. On macOS, install rv with Homebrew (brew install rv) then: rv ruby install ${RUBY_VERSION} && rv run --ruby ${RUBY_VERSION} gem install ${GEM_NAME}"
    ;;
  *)
    die "unsupported OS: ${OS}. rubino's installer supports Linux x86_64/arm64."
    ;;
esac

case "$ARCH" in
  x86_64|amd64) ;;
  aarch64|arm64) ;;
  *)
    die "unsupported architecture: ${ARCH}. Supported: x86_64, arm64."
    ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1 (please install it and re-run)"; }
need curl
need uname

info "Detected ${OS} ${ARCH}. Installing rubino (Ruby ${RUBY_VERSION})."

# --- step 1: install rv -----------------------------------------------------

# rv's installer (cargo-dist) drops the binary in $CARGO_HOME/bin or
# $HOME/.cargo/bin and writes a $HOME/.cargo/env helper. We don't want this
# script to edit the user's shell rc, so we pass RV_NO_MODIFY_PATH=1 and locate
# the binary ourselves.
locate_rv() {
  if command -v rv >/dev/null 2>&1; then command -v rv; return 0; fi
  for d in "${CARGO_HOME:-}/bin" "$HOME/.cargo/bin" "$HOME/.local/bin"; do
    [ -n "$d" ] && [ -x "$d/rv" ] && { printf '%s\n' "$d/rv"; return 0; }
  done
  return 1
}

if RV_BIN="$(locate_rv)"; then
  ok "rv already installed: ${RV_BIN}"
else
  info "Installing rv (fast Ruby version manager)..."
  # RV_NO_MODIFY_PATH=1: don't touch shell rc; we add it to PATH ourselves below.
  RV_NO_MODIFY_PATH=1 curl -fsSL https://rv.dev/install | sh
  RV_BIN="$(locate_rv)" || die "rv install completed but the rv binary wasn't found on PATH or in ~/.cargo/bin."
  ok "Installed rv: ${RV_BIN}"
fi

RV_BIN_DIR="$(dirname "$RV_BIN")"
export PATH="${RV_BIN_DIR}:${PATH}"

# --- step 2: install Ruby via rv -------------------------------------------

info "Installing Ruby ${RUBY_VERSION} via rv (precompiled, no build step)..."
# Idempotent: rv ruby install is a no-op if the version is already present.
"$RV_BIN" ruby install "${RUBY_VERSION}"
RUBY_BIN="$("$RV_BIN" ruby find "${RUBY_VERSION}")"
[ -x "$RUBY_BIN" ] || die "rv reported Ruby ${RUBY_VERSION} installed but its ruby binary wasn't found."
RUBY_BIN_DIR="$(dirname "$RUBY_BIN")"
ok "Ruby ${RUBY_VERSION} ready: ${RUBY_BIN_DIR}"

# Helper: run any command under the rv-managed Ruby without touching shell rc.
rvrun() { "$RV_BIN" run --ruby "${RUBY_VERSION}" "$@"; }

# --- step 3: install the rubino gem ------------------------------------

# The CLI executable lands in the Ruby's own bin dir.
gem_bin_present() { [ -x "${RUBY_BIN_DIR}/${BIN_NAME}" ]; }

install_published() {
  info "Trying published gem: gem install ${GEM_NAME}..."
  if rvrun gem install "${GEM_NAME}" >/dev/null 2>&1; then
    if gem_bin_present; then
      ok "Installed ${GEM_NAME} from RubyGems."
      return 0
    fi
    # A gem by this name exists but ships no '${BIN_NAME}' executable
    # (e.g. an unrelated/older package). Fall through to the git build.
    warn "A '${GEM_NAME}' gem was installed but it doesn't provide the '${BIN_NAME}' CLI; building from source instead."
    rvrun gem uninstall "${GEM_NAME}" -aIx >/dev/null 2>&1 || true
  fi
  return 1
}

install_from_git() {
  warn "Building ${GEM_NAME} from ${REPO_URL} (the CLI gem isn't on RubyGems yet)."
  need git
  local work
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  git clone --depth 1 "$REPO_URL" "$work/${REPO_NAME}" >/dev/null 2>&1 \
    || die "git clone of ${REPO_URL} failed."
  (
    cd "$work/${REPO_NAME}"
    info "Resolving dependencies (bundle install)..."
    rvrun bundle install >/dev/null 2>&1 || die "bundle install failed."
    info "Building the gem (rake build)..."
    rvrun rake build >/dev/null 2>&1 || die "rake build failed."
    local pkg
    pkg="$(ls -1 pkg/${GEM_NAME}-*.gem 2>/dev/null | head -n1)"
    [ -n "$pkg" ] || die "rake build produced no gem in pkg/."
    info "Installing ${pkg}..."
    rvrun gem install "$pkg" >/dev/null 2>&1 || die "gem install of the built package failed."
  )
  gem_bin_present || die "built and installed ${GEM_NAME} but the '${BIN_NAME}' executable is missing."
  ok "Installed ${GEM_NAME} from source."
}

if gem_bin_present; then
  CURRENT_VER="$("${RUBY_BIN_DIR}/${BIN_NAME}" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  ok "${BIN_NAME} ${CURRENT_VER:+v$CURRENT_VER }is already installed (re-run safe)."
elif ! install_published; then
  install_from_git
fi

# --- step 4: PATH guidance + success ---------------------------------------

printf '\n'
ok "rubino installed."
printf '\n'

if command -v "${BIN_NAME}" >/dev/null 2>&1 && [ "$(command -v "${BIN_NAME}")" = "${RUBY_BIN_DIR}/${BIN_NAME}" ]; then
  PATH_OK=1
else
  PATH_OK=0
fi

if [ "$PATH_OK" -ne 1 ]; then
  printf '%sAdd this line to your shell profile%s (~/.bashrc, ~/.zshrc, ~/.profile):\n' "$BOLD" "$RESET"
  printf '\n  %sexport PATH="%s:$PATH"%s\n\n' "$DIM" "${RUBY_BIN_DIR}" "$RESET"
  printf 'Then open a new shell (or run the export above) so %s%s%s is on your PATH.\n\n' "$BOLD" "${BIN_NAME}" "$RESET"
fi

printf '%sNext step:%s\n\n' "$BOLD" "$RESET"
printf '  %s%s setup%s   %s# guided first-run: pick a provider, paste a key%s\n\n' "$GREEN" "${BIN_NAME}" "$RESET" "$DIM" "$RESET"

printf 'Run: %s%s setup%s\n' "$BOLD" "${BIN_NAME}" "$RESET"
