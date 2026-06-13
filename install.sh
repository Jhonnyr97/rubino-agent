#!/usr/bin/env bash
#
# rubino installer (mise-based)
#
#   curl -fsSL https://raw.githubusercontent.com/Jhonnyr97/rubino-agent/main/install.sh | bash
#
# What it does (all in user space, no sudo):
#   1. Bootstraps mise (https://mise.jdx.dev) if it isn't already installed,
#      via `curl https://mise.run | sh`. We locate the installed binary and use
#      it directly rather than forcing edits to your shell rc.
#   2. Installs rubino through mise's `gem:` backend, which provisions a Ruby
#      (mise `ruby@3.3`, precompiled) if none is managed by mise, builds the
#      gem's native extensions (nio4r), and registers `rubino` as a mise tool so
#      its executable resolves via mise's shims/activation.
#   3. Installs at global scope by default (writes ~/.config/mise/config.toml),
#      or local/project scope (writes ./mise.toml) on request.
#
# Scope override (skip the prompt):
#   RUBINO_INSTALL_SCOPE=global   # default; user-wide
#   RUBINO_INSTALL_SCOPE=local    # this project/directory only
#
# Prerequisites: a C toolchain (cc/clang + make) is required because the gem
# builds native extensions. On Debian/Ubuntu: `apt-get install build-essential`.
#
# Security note: you are piping a script from the internet into a shell.
# Review it first:  curl -fsSL <url> -o install.sh && less install.sh && bash install.sh
#
# Re-running is safe: every step is idempotent (`mise use` just reaffirms it).

set -euo pipefail

# --- configuration ----------------------------------------------------------

REPO_OWNER="Jhonnyr97"
REPO_NAME="rubino-agent"

# The gem name on RubyGems (rubino-agent) vs. the executable it ships (rubino).
GEM_NAME="rubino-agent"
BIN_NAME="rubino"

# mise tool spec for the gem backend, and the Ruby to provision when mise has none.
GEM_TOOL="gem:${GEM_NAME}"
RUBY_TOOL="ruby@3.3"

# Optional: global | local. When unset and interactive, we prompt.
INSTALL_SCOPE="${RUBINO_INSTALL_SCOPE:-}"

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

# The gem backend compiles native extensions (nio4r), so a C toolchain must be
# present. Don't hard-fail purely on detection (some toolchains use cc/gcc/clang
# under different names), but warn loudly if we can't find any compiler + make.
check_toolchain() {
  local cc_found=0 make_found=0
  for c in cc gcc clang; do command -v "$c" >/dev/null 2>&1 && { cc_found=1; break; }; done
  command -v make >/dev/null 2>&1 && make_found=1
  if [ "$cc_found" -ne 1 ] || [ "$make_found" -ne 1 ]; then
    warn "No C toolchain detected (need a C compiler + make). The gem builds"
    warn "native extensions and will fail without one."
    case "$PLATFORM" in
      linux) warn "On Debian/Ubuntu: sudo apt-get install -y build-essential" ;;
      macos) warn "On macOS: xcode-select --install" ;;
    esac
  fi
}
check_toolchain

# --- bootstrap mise ---------------------------------------------------------

# mise's installer drops the binary in ~/.local/bin/mise (or $MISE_INSTALL_PATH).
# We pass through without forcing shell-rc edits and locate the binary ourselves,
# the same way the script used to locate rv.
locate_mise() {
  if command -v mise >/dev/null 2>&1; then command -v mise; return 0; fi
  for cand in "${MISE_INSTALL_PATH:-}" "$HOME/.local/bin/mise"; do
    [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

# NOTE: mise_bin is intentionally NOT local: the rest of the script uses it.
if mise_bin="$(locate_mise)"; then
  ok "mise already installed: ${mise_bin}"
else
  info "Installing mise (polyglot tool/version manager)..."
  curl -fsSL https://mise.run | sh
  mise_bin="$(locate_mise)" || die "mise install completed but the mise binary wasn't found at ~/.local/bin/mise or \$MISE_INSTALL_PATH."
  ok "Installed mise: ${mise_bin}"
fi

# `mise` may print activation hints to stderr; that's fine. Use the located
# binary for everything so we don't depend on the user's shell being activated.
mise() { "$mise_bin" "$@"; }

# Put the mise bindir on PATH for the rest of this process. The gem: backend
# installs a RubyGems plugin whose post-install hook shells out to a bare `mise`
# (mise reshim); on a freshly bootstrapped machine that binary isn't on PATH yet,
# so the gem install would error with "No such file or directory - mise". Adding
# its dir here makes the hook resolve. (No persistent shell-rc edit.)
case ":${PATH}:" in
  *":$(dirname "$mise_bin"):"*) ;;
  *) PATH="$(dirname "$mise_bin"):${PATH}"; export PATH ;;
esac

# --- persist experimental (the gem backend is experimental) -----------------

info "Enabling mise experimental features (required for the gem: backend)..."
mise settings experimental=true || die "failed to persist 'mise settings experimental=true'."

# --- ensure a Ruby for the gem backend --------------------------------------

# The gem backend needs a Ruby to install under and to build native exts with.
# If mise can't resolve a ruby, provision a precompiled one globally.
if mise which ruby >/dev/null 2>&1; then
  ok "mise already manages a Ruby: $(mise which ruby 2>/dev/null || echo '?')"
else
  info "No mise-managed Ruby found; installing ${RUBY_TOOL} (precompiled)..."
  mise use -g "${RUBY_TOOL}" || die "mise use -g ${RUBY_TOOL} failed."
  ok "Ruby ready via mise (${RUBY_TOOL})."
fi

# --- choose scope (global default, or local/project) ------------------------

choose_scope() {
  case "$INSTALL_SCOPE" in
    global|local) printf '%s\n' "$INSTALL_SCOPE"; return 0 ;;
    "")           ;;
    *)            die "RUBINO_INSTALL_SCOPE must be 'global' or 'local' (got '${INSTALL_SCOPE}')." ;;
  esac

  # A /dev/tty node can exist (e.g. in a container) yet not be openable when
  # there's no controlling terminal. Probe an actual open before prompting so we
  # silently fall back to the default instead of erroring on the redirect.
  if { : >/dev/tty; } 2>/dev/null && { : </dev/tty; } 2>/dev/null; then
    {
      printf '\n%sInstall rubino globally or for this project?%s\n' "$BOLD" "$RESET"
      printf '  %sglobal%s  %s(user-wide → ~/.config/mise/config.toml)%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
      printf '  %slocal%s   %s(this directory only → ./mise.toml)%s\n'      "$BOLD" "$RESET" "$DIM" "$RESET"
      printf 'Choose %s[global/local]%s (default global): ' "$BOLD" "$RESET"
    } >/dev/tty
    local ans=""
    read -r ans </dev/tty || ans=""
    case "$ans" in
      local|l|2)        printf 'local\n' ;;
      ""|global|g|1)    printf 'global\n' ;;
      *)                printf 'global\n' ;;
    esac
    return 0
  fi

  # Non-interactive, no override → default global.
  printf 'global\n'
}

SCOPE="$(choose_scope)"

info "Detected ${OS} ${ARCH}. Installing rubino via mise (${SCOPE} scope)."

# --- install the rubino gem via the mise gem: backend -----------------------

case "$SCOPE" in
  global)
    info "Installing ${GEM_TOOL} globally (mise use -g)..."
    mise use -g "${GEM_TOOL}" || die "mise use -g ${GEM_TOOL} failed (native build needs a C toolchain — see prerequisites above)."
    ;;
  local)
    info "Installing ${GEM_TOOL} for this directory (mise use)..."
    mise use "${GEM_TOOL}" || die "mise use ${GEM_TOOL} failed (native build needs a C toolchain — see prerequisites above)."
    ;;
esac

# --- verify -----------------------------------------------------------------

RUBINO_PATH="$(mise which "${BIN_NAME}" 2>/dev/null || true)"
[ -n "$RUBINO_PATH" ] || die "mise installed ${GEM_TOOL} but 'mise which ${BIN_NAME}' resolved nothing."

VER="$(mise exec -- "${BIN_NAME}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
[ -n "$VER" ] || die "installed ${GEM_TOOL} but '${BIN_NAME} --version' did not report a version."

printf '\n'
ok "rubino v${VER} installed via mise (${SCOPE} scope)."
ok "executable: ${RUBINO_PATH}"
printf '\n'

# --- activation guidance + next step ----------------------------------------

# rubino resolves through mise's shims/activation. If mise isn't activated in the
# user's shell, `rubino` won't be found in a plain shell even though it's
# installed. Tell them how to activate.
SHELL_NAME="$(basename "${SHELL:-}")"
case "$SHELL_NAME" in
  zsh)  ACT_RC="~/.zshrc";   ACT_SH="zsh"  ;;
  bash) ACT_RC="~/.bashrc";  ACT_SH="bash" ;;
  *)    ACT_RC="your shell rc"; ACT_SH="$SHELL_NAME" ;;
esac

if command -v "${BIN_NAME}" >/dev/null 2>&1; then
  ok "${BIN_NAME} is already on your PATH (mise is activated)."
else
  printf '%sActivate mise in your shell%s so %s%s%s is on your PATH. Add to %s:\n' \
    "$BOLD" "$RESET" "$BOLD" "${BIN_NAME}" "$RESET" "$ACT_RC"
  printf '\n  %seval "$(%s activate %s)"%s\n\n' "$DIM" "$mise_bin" "${ACT_SH:-zsh}" "$RESET"
  printf 'Then open a new shell. Until then you can run it with:\n'
  printf '\n  %smise exec -- %s%s\n\n' "$DIM" "${BIN_NAME}" "$RESET"
fi

printf '%sNext step:%s\n\n' "$BOLD" "$RESET"
printf '  %s%s setup%s   %s# guided first-run: pick a provider, paste a key%s\n\n' "$GREEN" "${BIN_NAME}" "$RESET" "$DIM" "$RESET"

printf 'Run: %s%s setup%s\n' "$BOLD" "${BIN_NAME}" "$RESET"
