#!/usr/bin/env bash
#
# rubino installer
#
#   curl -fsSL https://raw.githubusercontent.com/Jhonnyr97/rubino-agent/main/install.sh | bash
#
# What it does (all in user space, no sudo):
#   1. Provisions a Ruby toolchain:
#        - Linux: via `rv` (https://github.com/spinel-coop/rv), a fast Ruby
#          version manager that fetches a precompiled Ruby (no build step).
#        - macOS: if Homebrew is present you're asked whether to use Homebrew
#          (`brew install ruby`) or rv; if Homebrew is absent it uses rv directly.
#   2. Installs the `rubino-agent` gem under that Ruby. If a published gem with
#      the CLI isn't available yet, it falls back to building from this repo.
#   3. Prints the exact PATH line for the `rubino` executable.
#
# Non-interactive override: set RUBINO_INSTALL_METHOD=brew|rv to skip the prompt.
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
# (Homebrew installs its current `ruby` formula instead; the gem supports both.)
RUBY_VERSION="${RUBINO_RUBY_VERSION:-3.3.3}"

# The gem name on RubyGems (rubino-agent) vs. the executable it ships (rubino).
GEM_NAME="rubino-agent"
BIN_NAME="rubino"

# Optional: brew | rv. When unset on macOS with Homebrew present, we prompt.
INSTALL_METHOD="${RUBINO_INSTALL_METHOD:-}"

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
  Linux)  PLATFORM="linux"  ;;
  Darwin) PLATFORM="macos"  ;;
  *)      die "unsupported OS: ${OS}. rubino's installer supports Linux and macOS (x86_64/arm64)." ;;
esac

case "$ARCH" in
  x86_64|amd64)  ;;
  aarch64|arm64) ;;
  *) die "unsupported architecture: ${ARCH}. Supported: x86_64, arm64." ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1 (please install it and re-run)"; }
need curl
need uname

# --- choose install method (macOS may use Homebrew or rv) -------------------

# Decide how we get Ruby. Linux always uses rv. macOS: honor an explicit
# RUBINO_INSTALL_METHOD; else if Homebrew is present, ask (when a terminal is
# available); else fall back to rv. The prompt reads from /dev/tty so it works
# even under `curl ... | bash`, where stdin is the script itself.
choose_method() {
  if [ "$PLATFORM" = "linux" ]; then
    printf 'rv\n'; return 0
  fi

  case "$INSTALL_METHOD" in
    brew) printf 'brew\n'; return 0 ;;
    rv)   printf 'rv\n';   return 0 ;;
    "")   ;;
    *)    die "RUBINO_INSTALL_METHOD must be 'brew' or 'rv' (got '${INSTALL_METHOD}')." ;;
  esac

  if ! command -v brew >/dev/null 2>&1; then
    # No Homebrew → rv directly, as requested.
    printf 'rv\n'; return 0
  fi

  # Homebrew present. Ask, if we have a terminal to ask on.
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    {
      printf '\n%sHomebrew detected.%s How should Ruby be installed?\n' "$BOLD" "$RESET"
      printf '  %s1)%s Homebrew   %s(brew install ruby)%s\n'            "$BOLD" "$RESET" "$DIM" "$RESET"
      printf '  %s2)%s rv         %s(fast, self-contained, no Homebrew)%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
      printf 'Choose %s[1/2]%s (default 1): ' "$BOLD" "$RESET"
    } >/dev/tty
    local ans=""
    read -r ans </dev/tty || ans=""
    case "$ans" in
      2|rv|RV)   printf 'rv\n' ;;
      ""|1|brew) printf 'brew\n' ;;
      *)         printf 'brew\n' ;;
    esac
    return 0
  fi

  # Homebrew present but no terminal to prompt on → default to Homebrew
  # (the native macOS expectation). Override with RUBINO_INSTALL_METHOD=rv.
  warn "Homebrew detected but no interactive terminal; defaulting to Homebrew. Set RUBINO_INSTALL_METHOD=rv to use rv instead."
  printf 'brew\n'
}

METHOD="$(choose_method)"

# `rubyx <cmd...>` runs a command (gem/bundle/rake/ruby) under the Ruby we set
# up, regardless of method. Each setup_* defines it plus RUBY_LABEL.
rubyx() { die "internal: ruby toolchain not initialized"; }

# --- ruby toolchain: rv -----------------------------------------------------

setup_ruby_rv() {
  # rv's installer (cargo-dist) drops the binary in $CARGO_HOME/bin or
  # $HOME/.cargo/bin. We pass RV_NO_MODIFY_PATH=1 so it doesn't edit the user's
  # shell rc, and locate the binary ourselves.
  locate_rv() {
    if command -v rv >/dev/null 2>&1; then command -v rv; return 0; fi
    for d in "${CARGO_HOME:-}/bin" "$HOME/.cargo/bin" "$HOME/.local/bin"; do
      [ -n "$d" ] && [ -x "$d/rv" ] && { printf '%s\n' "$d/rv"; return 0; }
    done
    return 1
  }

  # NOTE: rv_bin is intentionally NOT local: rubyx() reads it after we return.
  if rv_bin="$(locate_rv)"; then
    ok "rv already installed: ${rv_bin}"
  else
    info "Installing rv (fast Ruby version manager)..."
    RV_NO_MODIFY_PATH=1 curl -fsSL https://rv.dev/install | sh
    rv_bin="$(locate_rv)" || die "rv install completed but the rv binary wasn't found on PATH or in ~/.cargo/bin."
    ok "Installed rv: ${rv_bin}"
  fi
  export PATH="$(dirname "$rv_bin"):${PATH}"

  info "Installing Ruby ${RUBY_VERSION} via rv (precompiled, no build step)..."
  "$rv_bin" ruby install "${RUBY_VERSION}"          # idempotent
  local ruby_bin
  ruby_bin="$("$rv_bin" ruby find "${RUBY_VERSION}")"
  [ -x "$ruby_bin" ] || die "rv reported Ruby ${RUBY_VERSION} installed but its ruby binary wasn't found."
  RUBY_BIN_DIR="$(dirname "$ruby_bin")"
  RUBY_LABEL="Ruby ${RUBY_VERSION} (rv)"

  rubyx() { "$rv_bin" run --ruby "${RUBY_VERSION}" "$@"; }
  ok "${RUBY_LABEL} ready: ${RUBY_BIN_DIR}"
}

# --- ruby toolchain: Homebrew ----------------------------------------------

setup_ruby_brew() {
  need brew
  if brew list --formula ruby >/dev/null 2>&1; then
    ok "Homebrew Ruby already installed."
  else
    info "Installing Ruby via Homebrew (brew install ruby)..."
    brew install ruby || die "brew install ruby failed."
  fi
  local prefix
  prefix="$(brew --prefix ruby 2>/dev/null)" || die "could not resolve 'brew --prefix ruby'."
  RUBY_BIN_DIR="${prefix}/bin"
  [ -x "${RUBY_BIN_DIR}/ruby" ] || die "Homebrew ruby not found at ${RUBY_BIN_DIR}."
  local ver
  ver="$("${RUBY_BIN_DIR}/ruby" -e 'print RUBY_VERSION' 2>/dev/null || echo '?')"
  RUBY_LABEL="Ruby ${ver} (Homebrew)"

  # Run gem/bundle/rake from Homebrew's keg-only ruby bin without relinking.
  rubyx() { PATH="${RUBY_BIN_DIR}:${PATH}" "$@"; }
  ok "${RUBY_LABEL} ready: ${RUBY_BIN_DIR}"
}

info "Detected ${OS} ${ARCH}. Installing rubino via ${METHOD}."

case "$METHOD" in
  rv)   setup_ruby_rv ;;
  brew) setup_ruby_brew ;;
  *)    die "internal: unknown method '${METHOD}'." ;;
esac

# Where gem-installed executables land for the chosen Ruby. Ask RubyGems
# directly (Gem.bindir); fall back to the ruby bin dir. The dir may not exist
# yet on a fresh machine — `gem install` creates it — so don't require it.
GEM_BIN_DIR="$(rubyx ruby -e 'print Gem.bindir' 2>/dev/null)" || GEM_BIN_DIR=""
[ -n "${GEM_BIN_DIR:-}" ] || GEM_BIN_DIR="$RUBY_BIN_DIR"

# --- install the rubino gem -------------------------------------------------

gem_bin_present() { [ -x "${GEM_BIN_DIR}/${BIN_NAME}" ]; }

install_published() {
  info "Trying published gem: gem install ${GEM_NAME}..."
  if rubyx gem install "${GEM_NAME}" >/dev/null 2>&1; then
    if gem_bin_present; then
      ok "Installed ${GEM_NAME} from RubyGems."
      return 0
    fi
    warn "A '${GEM_NAME}' gem was installed but it doesn't provide the '${BIN_NAME}' CLI; building from source instead."
    rubyx gem uninstall "${GEM_NAME}" -aIx >/dev/null 2>&1 || true
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
    rubyx bundle install >/dev/null 2>&1 || die "bundle install failed."
    info "Building the gem (rake build)..."
    rubyx rake build >/dev/null 2>&1 || die "rake build failed."
    local pkg
    pkg="$(ls -1 pkg/${GEM_NAME}-*.gem 2>/dev/null | head -n1)"
    [ -n "$pkg" ] || die "rake build produced no gem in pkg/."
    info "Installing ${pkg}..."
    rubyx gem install "$pkg" >/dev/null 2>&1 || die "gem install of the built package failed."
  )
  gem_bin_present || die "built and installed ${GEM_NAME} but the '${BIN_NAME}' executable is missing."
  ok "Installed ${GEM_NAME} from source."
}

if gem_bin_present; then
  CURRENT_VER="$("${GEM_BIN_DIR}/${BIN_NAME}" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  ok "${BIN_NAME} ${CURRENT_VER:+v$CURRENT_VER }is already installed (re-run safe)."
elif ! install_published; then
  install_from_git
fi

# --- PATH guidance + success ------------------------------------------------

printf '\n'
ok "rubino installed (${RUBY_LABEL})."
printf '\n'

if command -v "${BIN_NAME}" >/dev/null 2>&1 && [ "$(command -v "${BIN_NAME}")" = "${GEM_BIN_DIR}/${BIN_NAME}" ]; then
  PATH_OK=1
else
  PATH_OK=0
fi

if [ "$PATH_OK" -ne 1 ]; then
  printf '%sAdd this line to your shell profile%s (~/.bashrc, ~/.zshrc, ~/.profile):\n' "$BOLD" "$RESET"
  printf '\n  %sexport PATH="%s:$PATH"%s\n\n' "$DIM" "${GEM_BIN_DIR}" "$RESET"
  printf 'Then open a new shell (or run the export above) so %s%s%s is on your PATH.\n\n' "$BOLD" "${BIN_NAME}" "$RESET"
fi

printf '%sNext step:%s\n\n' "$BOLD" "$RESET"
printf '  %s%s setup%s   %s# guided first-run: pick a provider, paste a key%s\n\n' "$GREEN" "${BIN_NAME}" "$RESET" "$DIM" "$RESET"

printf 'Run: %s%s setup%s\n' "$BOLD" "${BIN_NAME}" "$RESET"
