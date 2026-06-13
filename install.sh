#!/usr/bin/env bash
#
# rubino installer
#
#   curl -fsSL https://raw.githubusercontent.com/Jhonnyr97/rubino-agent/main/install.sh | bash
#
# What it does (all in user space, no sudo): provisions a Ruby toolchain and
# installs the `rubino-agent` gem under it. There are THREE install methods:
#
#   - Homebrew (macOS):  `brew install ruby`, then `gem install rubino-agent`.
#   - rv:                fetches a precompiled Ruby via rv
#                        (https://github.com/spinel-coop/rv), then installs the gem.
#   - mise:              uses mise (https://mise.jdx.dev) and its `gem:` backend,
#                        which provisions a Ruby (`ruby@3.3`, precompiled) and
#                        registers `rubino` as a mise tool. mise additionally
#                        supports a global (user-wide) or local (per-project) scope.
#
# Method selection:
#   - macOS (interactive): you're asked to pick 1) Homebrew  2) rv  3) mise.
#     Default is Homebrew when present, else rv.
#   - Linux (interactive): you're asked to pick 1) rv  2) mise (Homebrew offered
#     only if `brew` is on PATH). Default is rv.
#   - Non-interactive override: RUBINO_INSTALL_METHOD=brew|rv|mise.
#
# For the mise method only, choose the scope:
#   RUBINO_INSTALL_SCOPE=global   # default; user-wide  (~/.config/mise/config.toml)
#   RUBINO_INSTALL_SCOPE=local    # this project/directory only  (./mise.toml)
# (Or answer the follow-up prompt.)
#
# Other overrides:
#   RUBINO_RUBY_VERSION=3.3.3      # Ruby pinned for the rv method.
#
# If a published gem with the CLI isn't available yet (brew/rv methods), the
# script falls back to building from this repo.
#
# Prerequisites: a C toolchain (cc/clang + make) is required because the gem
# builds native extensions. On Debian/Ubuntu: `apt-get install build-essential`.
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

# mise tool spec for the gem backend, and the Ruby to provision when mise has none.
GEM_TOOL="gem:${GEM_NAME}"
RUBY_TOOL="ruby@3.3"

# Optional: brew | rv | mise. When unset on macOS (or Linux with brew present),
# we prompt. Linux without brew prompts between rv and mise.
INSTALL_METHOD="${RUBINO_INSTALL_METHOD:-}"

# Optional (mise method only): global | local. When unset and interactive, we prompt.
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

# --- shell-rc activation (persist PATH / mise activation) -------------------

# Marker comment we drop next to the line(s) we append, so re-runs are
# idempotent and users can find/remove what we added.
RC_MARKER="# added by rubino installer (https://github.com/${REPO_OWNER}/${REPO_NAME})"

# Opt out of any shell-rc modification with RUBINO_NO_MODIFY_RC=1.
RUBINO_NO_MODIFY_RC="${RUBINO_NO_MODIFY_RC:-0}"

# Set by persist_to_rc() to the rc file(s) it touched. Init for `set -u` safety.
PERSISTED_RC=""

# The rc file the user is most likely to open/read (shown in hints). Honor
# $SHELL; default to bash so a `curl | bash` run (where $SHELL may be empty
# under -u) still persists.
detect_shell_rc() {
  local shell_name
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    zsh)  printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) printf '%s\n' "$HOME/.bashrc" ;;
    *)    printf '%s\n' "$HOME/.profile" ;;
  esac
}

# The set of startup files to persist into. We cover BOTH the interactive rc
# (sourced when you open a terminal) AND the login-shell profile (sourced by
# `bash -l` / SSH logins) — on some distros the interactive rc early-returns for
# non-interactive shells, so the profile is what makes a login shell pick it up.
rc_targets() {
  local shell_name
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    zsh)
      printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc"
      printf '%s\n' "${ZDOTDIR:-$HOME}/.zprofile"
      ;;
    bash)
      printf '%s\n' "$HOME/.bashrc"
      # bash login shells read the first of .bash_profile/.bash_login/.profile;
      # prefer an existing one, else .profile (Debian/Ubuntu default sources .bashrc).
      if   [ -e "$HOME/.bash_profile" ]; then printf '%s\n' "$HOME/.bash_profile"
      elif [ -e "$HOME/.bash_login" ];   then printf '%s\n' "$HOME/.bash_login"
      else printf '%s\n' "$HOME/.profile"
      fi
      ;;
    *)
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

# Append a single line, once, to each startup file from rc_targets(). Guarded by
# RC_MARKER + a grep for the exact line so re-runs don't duplicate. Sets
# PERSISTED_RC to the space-separated files it touched. Returns 0 if the line is
# present in at least one target afterward.
persist_to_rc() {
  local line="$1" rc any=1 touched=""
  [ "$RUBINO_NO_MODIFY_RC" = "1" ] && return 1
  while IFS= read -r rc; do
    [ -n "$rc" ] || continue
    # Create the file if missing (login shells will source it).
    [ -e "$rc" ] || : >"$rc" 2>/dev/null || continue
    if grep -qF "$line" "$rc" 2>/dev/null; then
      touched="${touched:+$touched }$rc"; any=0
      continue
    fi
    if {
        printf '\n%s\n' "$RC_MARKER"
        printf '%s\n' "$line"
      } >>"$rc" 2>/dev/null; then
      touched="${touched:+$touched }$rc"; any=0
    fi
  done <<EOF
$(rc_targets)
EOF
  PERSISTED_RC="$touched"
  return "$any"
}

# Post-install gate: confirm `$BIN_NAME` is reachable from a FRESH interactive/
# login shell (not just this process). If it isn't, fail loudly with the exact
# line to paste — never print a success banner over a broken install.
# Args: $1 = the activation/PATH line we tried to persist (for the error hint).
verify_fresh_shell() {
  local fix_line="$1" shell_name
  shell_name="$(basename "${SHELL:-bash}")"

  # Probe a fresh login+interactive shell — interactive so the rc body (which on
  # some distros is guarded by a non-interactive early-return) actually runs,
  # login so profile files are sourced too. This mirrors opening a new terminal.
  local found=1
  case "$shell_name" in
    zsh)  zsh  -i -c "command -v ${BIN_NAME} >/dev/null 2>&1" >/dev/null 2>&1 || found=0 ;;
    *)    bash -lic "command -v ${BIN_NAME} >/dev/null 2>&1" >/dev/null 2>&1 || found=0 ;;
  esac

  if [ "$found" -eq 1 ]; then
    ok "Verified: a fresh login shell finds '${BIN_NAME}'."
    return 0
  fi

  # Broken: tell the user exactly what to do, then exit non-zero.
  printf '\n'
  warn "${BIN_NAME} was installed but a fresh login shell can't find it yet."
  if [ "$RUBINO_NO_MODIFY_RC" = "1" ]; then
    warn "RUBINO_NO_MODIFY_RC=1 is set, so no shell rc was modified."
  fi
  printf '%sAdd this line to your shell profile%s (%s), then open a new shell:\n' \
    "$BOLD" "$RESET" "$(detect_shell_rc)" >&2
  printf '\n  %s\n\n' "$fix_line" >&2
  die "post-install check failed: '${BIN_NAME}' not on PATH in a fresh shell (see the line above)."
}

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

# The gem build (native extensions, e.g. nio4r) needs a C toolchain. Don't
# hard-fail purely on detection (toolchains use cc/gcc/clang under different
# names), but warn loudly if we can't find any compiler + make.
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

# --- choose install method (brew | rv | mise) -------------------------------

# Honor an explicit RUBINO_INSTALL_METHOD. Otherwise prompt on /dev/tty (so it
# works under `curl ... | bash`, where stdin is the script itself). The offered
# options differ by platform: macOS leads with Homebrew (when present); Linux
# offers rv + mise (and Homebrew only if `brew` happens to be on PATH).
#
# A /dev/tty node can exist (e.g. in a container) yet not be openable when
# there's no controlling terminal. Probe an actual open before prompting so we
# silently fall back to the default instead of erroring on the redirect.
tty_usable() { { : >/dev/tty; } 2>/dev/null && { : </dev/tty; } 2>/dev/null; }

choose_method() {
  case "$INSTALL_METHOD" in
    brew) printf 'brew\n'; return 0 ;;
    rv)   printf 'rv\n';   return 0 ;;
    mise) printf 'mise\n'; return 0 ;;
    "")   ;;
    *)    die "RUBINO_INSTALL_METHOD must be 'brew', 'rv', or 'mise' (got '${INSTALL_METHOD}')." ;;
  esac

  local have_brew=0
  command -v brew >/dev/null 2>&1 && have_brew=1

  # Defaults preserve prior behavior: macOS → brew if present else rv; Linux → rv.
  local default_method
  if [ "$PLATFORM" = "macos" ] && [ "$have_brew" -eq 1 ]; then
    default_method="brew"
  else
    default_method="rv"
  fi

  if ! tty_usable; then
    # Non-interactive, no override → platform default.
    if [ "$default_method" = "brew" ]; then
      warn "Homebrew detected but no interactive terminal; defaulting to Homebrew. Set RUBINO_INSTALL_METHOD=rv or =mise to choose another method."
    fi
    printf '%s\n' "$default_method"; return 0
  fi

  # Interactive: build a numbered menu. macOS leads with Homebrew (when present).
  local ans=""
  if [ "$PLATFORM" = "macos" ] && [ "$have_brew" -eq 1 ]; then
    {
      printf '\n%sHow should rubino be installed?%s\n' "$BOLD" "$RESET"
      printf '  %s1)%s Homebrew   %s(brew install ruby)%s\n'                  "$BOLD" "$RESET" "$DIM" "$RESET"
      printf '  %s2)%s rv         %s(fast, self-contained, no Homebrew)%s\n'  "$BOLD" "$RESET" "$DIM" "$RESET"
      printf '  %s3)%s mise       %s(polyglot tool manager, global or local scope)%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
      printf 'Choose %s[1/2/3]%s (default 1, Homebrew): ' "$BOLD" "$RESET"
    } >/dev/tty
    read -r ans </dev/tty || ans=""
    case "$ans" in
      2|rv|RV)        printf 'rv\n' ;;
      3|mise|MISE)    printf 'mise\n' ;;
      ""|1|brew|BREW) printf 'brew\n' ;;
      *)              printf 'brew\n' ;;
    esac
    return 0
  fi

  if [ "$have_brew" -eq 1 ]; then
    # Linux with brew present: offer all three, default rv.
    {
      printf '\n%sHow should rubino be installed?%s\n' "$BOLD" "$RESET"
      printf '  %s1)%s rv         %s(fast, self-contained; recommended)%s\n'  "$BOLD" "$RESET" "$DIM" "$RESET"
      printf '  %s2)%s mise       %s(polyglot tool manager, global or local scope)%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
      printf '  %s3)%s Homebrew   %s(brew install ruby)%s\n'                  "$BOLD" "$RESET" "$DIM" "$RESET"
      printf 'Choose %s[1/2/3]%s (default 1, rv): ' "$BOLD" "$RESET"
    } >/dev/tty
    read -r ans </dev/tty || ans=""
    case "$ans" in
      2|mise|MISE)    printf 'mise\n' ;;
      3|brew|BREW)    printf 'brew\n' ;;
      ""|1|rv|RV)     printf 'rv\n' ;;
      *)              printf 'rv\n' ;;
    esac
    return 0
  fi

  # Linux without brew: rv vs mise, default rv.
  {
    printf '\n%sHow should rubino be installed?%s\n' "$BOLD" "$RESET"
    printf '  %s1)%s rv         %s(fast, self-contained; recommended)%s\n'  "$BOLD" "$RESET" "$DIM" "$RESET"
    printf '  %s2)%s mise       %s(polyglot tool manager, global or local scope)%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
    printf 'Choose %s[1/2]%s (default 1, rv): ' "$BOLD" "$RESET"
  } >/dev/tty
  read -r ans </dev/tty || ans=""
  case "$ans" in
    2|mise|MISE) printf 'mise\n' ;;
    ""|1|rv|RV)  printf 'rv\n' ;;
    *)           printf 'rv\n' ;;
  esac
}

METHOD="$(choose_method)"

# `rubyx <cmd...>` runs a command (gem/bundle/rake/ruby) under the Ruby we set
# up, for the brew/rv methods. Each setup_* defines it plus RUBY_LABEL.
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

# --- ruby toolchain + gem install: mise -------------------------------------

# mise is special: it both provisions Ruby and installs the gem (via its `gem:`
# backend), and supports global/local scope. So setup_mise() runs the full
# install and then exits the script, rather than returning into the shared
# gem-install path used by brew/rv.
setup_mise() {
  # mise's installer drops the binary in ~/.local/bin/mise (or $MISE_INSTALL_PATH).
  # We pass through without forcing shell-rc edits and locate the binary ourselves.
  locate_mise() {
    if command -v mise >/dev/null 2>&1; then command -v mise; return 0; fi
    for cand in "${MISE_INSTALL_PATH:-}" "$HOME/.local/bin/mise"; do
      [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    done
    return 1
  }

  local mise_bin
  if mise_bin="$(locate_mise)"; then
    ok "mise already installed: ${mise_bin}"
  else
    info "Installing mise (polyglot tool/version manager)..."
    curl -fsSL https://mise.run | sh
    mise_bin="$(locate_mise)" || die "mise install completed but the mise binary wasn't found at ~/.local/bin/mise or \$MISE_INSTALL_PATH."
    ok "Installed mise: ${mise_bin}"
  fi

  # Use the located binary for everything so we don't depend on the user's shell
  # being activated. (`mise` may print activation hints to stderr; that's fine.)
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

  # The gem backend is experimental; persist the setting.
  info "Enabling mise experimental features (required for the gem: backend)..."
  mise settings experimental=true || die "failed to persist 'mise settings experimental=true'."

  # The gem backend needs a Ruby to install under and to build native exts with.
  # If mise can't resolve a ruby, provision a precompiled one globally.
  if mise which ruby >/dev/null 2>&1; then
    ok "mise already manages a Ruby: $(mise which ruby 2>/dev/null || echo '?')"
  else
    info "No mise-managed Ruby found; installing ${RUBY_TOOL} (precompiled)..."
    mise use -g "${RUBY_TOOL}" || die "mise use -g ${RUBY_TOOL} failed."
    ok "Ruby ready via mise (${RUBY_TOOL})."
  fi

  # Choose scope (global default, or local/project).
  local scope=""
  case "$INSTALL_SCOPE" in
    global|local) scope="$INSTALL_SCOPE" ;;
    "")           ;;
    *)            die "RUBINO_INSTALL_SCOPE must be 'global' or 'local' (got '${INSTALL_SCOPE}')." ;;
  esac

  if [ -z "$scope" ]; then
    if tty_usable; then
      {
        printf '\n%sInstall rubino globally or for this project?%s\n' "$BOLD" "$RESET"
        printf '  %sglobal%s  %s(user-wide → ~/.config/mise/config.toml)%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
        printf '  %slocal%s   %s(this directory only → ./mise.toml)%s\n'      "$BOLD" "$RESET" "$DIM" "$RESET"
        printf 'Choose %s[global/local]%s (default global): ' "$BOLD" "$RESET"
      } >/dev/tty
      local ans=""
      read -r ans </dev/tty || ans=""
      case "$ans" in
        local|l|2)     scope="local" ;;
        ""|global|g|1) scope="global" ;;
        *)             scope="global" ;;
      esac
    else
      scope="global"
    fi
  fi

  info "Detected ${OS} ${ARCH}. Installing rubino via mise (${scope} scope)."

  # Resolve the latest PUBLISHED gem version and pin it explicitly. By default
  # mise applies `minimum_release_age`, which hides a freshly published release
  # (you'd see "... hidden by minimum_release_age" and get a stale version). We
  # both pin the exact version AND disable the release-age gate for this install
  # so the just-published gem is taken. (#258)
  local gem_tool="${GEM_TOOL}" want_ver
  want_ver="$(curl -fsSL "https://rubygems.org/api/v1/gems/${GEM_NAME}.json" 2>/dev/null \
    | grep -oE '"version":"[0-9]+\.[0-9]+\.[0-9]+[^"]*"' | head -n1 \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^"]*')"
  if [ -n "$want_ver" ]; then
    gem_tool="${GEM_TOOL}@${want_ver}"
    info "Latest published ${GEM_NAME} is ${want_ver}; pinning ${gem_tool}."
  else
    warn "Could not resolve the latest ${GEM_NAME} version from RubyGems; letting mise pick."
  fi
  # MISE_MINIMUM_RELEASE_AGE=0 ensures a just-published version isn't filtered.
  export MISE_MINIMUM_RELEASE_AGE=0

  case "$scope" in
    global)
      info "Installing ${gem_tool} globally (mise use -g)..."
      mise use -g "${gem_tool}" || die "mise use -g ${gem_tool} failed (native build needs a C toolchain — see prerequisites above)."
      ;;
    local)
      info "Installing ${gem_tool} for this directory (mise use)..."
      mise use "${gem_tool}" || die "mise use ${gem_tool} failed (native build needs a C toolchain — see prerequisites above)."
      ;;
  esac

  # Verify.
  local rubino_path ver
  rubino_path="$(mise which "${BIN_NAME}" 2>/dev/null || true)"
  [ -n "$rubino_path" ] || die "mise installed ${GEM_TOOL} but 'mise which ${BIN_NAME}' resolved nothing."

  ver="$(mise exec -- "${BIN_NAME}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  [ -n "$ver" ] || die "installed ${GEM_TOOL} but '${BIN_NAME} --version' did not report a version."

  printf '\n'
  ok "rubino v${ver} installed via mise (${scope} scope)."
  ok "executable: ${rubino_path}"
  printf '\n'

  # Activation: rubino resolves through mise's shims/activation. If mise isn't
  # activated in the user's shell, `rubino` won't be found in a plain shell even
  # though it's installed. Persist the activation line to the user's rc so a
  # fresh login shell works — printing a hint alone left fresh shells broken (#257).
  local shell_name act_sh act_line
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    zsh)  act_sh="zsh"  ;;
    bash) act_sh="bash" ;;
    *)    act_sh="$shell_name" ;;
  esac
  # Use a bare `mise` in the persisted line so it stays valid if the binary moves.
  act_line="eval \"\$($mise_bin activate ${act_sh:-bash})\""

  if command -v "${BIN_NAME}" >/dev/null 2>&1; then
    ok "${BIN_NAME} is already on your PATH (mise is activated)."
  elif persist_to_rc "$act_line"; then
    ok "Added mise activation to ${PERSISTED_RC} (open a new shell to pick it up)."
    printf 'Until then you can run it with:\n'
    printf '\n  %smise exec -- %s%s\n\n' "$DIM" "${BIN_NAME}" "$RESET"
  else
    # Opt-out or couldn't write: keep the manual hint.
    printf '%sActivate mise in your shell%s so %s%s%s is on your PATH. Add to %s:\n' \
      "$BOLD" "$RESET" "$BOLD" "${BIN_NAME}" "$RESET" "$(detect_shell_rc)"
    printf '\n  %s%s%s\n\n' "$DIM" "$act_line" "$RESET"
    printf 'Then open a new shell. Until then you can run it with:\n'
    printf '\n  %smise exec -- %s%s\n\n' "$DIM" "${BIN_NAME}" "$RESET"
  fi

  # Post-install gate: fail loudly if a fresh shell still can't find rubino.
  verify_fresh_shell "$act_line"

  printf '%sNext step:%s\n\n' "$BOLD" "$RESET"
  printf '  %s%s setup%s   %s# guided first-run: pick a provider, paste a key%s\n\n' "$GREEN" "${BIN_NAME}" "$RESET" "$DIM" "$RESET"
  printf 'Run: %s%s setup%s\n' "$BOLD" "${BIN_NAME}" "$RESET"

  exit 0
}

info "Detected ${OS} ${ARCH}. Installing rubino via ${METHOD}."

case "$METHOD" in
  rv)   setup_ruby_rv ;;
  brew) setup_ruby_brew ;;
  mise) setup_mise ;;   # runs the full mise install and exits.
  *)    die "internal: unknown method '${METHOD}'." ;;
esac

# Where gem-installed executables land for the chosen Ruby. Ask RubyGems
# directly (Gem.bindir); fall back to the ruby bin dir. The dir may not exist
# yet on a fresh machine — `gem install` creates it — so don't require it.
GEM_BIN_DIR="$(rubyx ruby -e 'print Gem.bindir' 2>/dev/null)" || GEM_BIN_DIR=""
[ -n "${GEM_BIN_DIR:-}" ] || GEM_BIN_DIR="$RUBY_BIN_DIR"

# --- install the rubino gem (brew / rv methods) -----------------------------

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

PATH_LINE="export PATH=\"${GEM_BIN_DIR}:\$PATH\""

if [ "$PATH_OK" -ne 1 ]; then
  # Persist the PATH line to the user's rc so a fresh login shell finds rubino —
  # printing the hint alone left fresh shells broken (#257).
  if persist_to_rc "$PATH_LINE"; then
    ok "Added ${BIN_NAME} to your PATH in ${PERSISTED_RC} (open a new shell to pick it up)."
  else
    printf '%sAdd this line to your shell profile%s (%s):\n' "$BOLD" "$RESET" "$(detect_shell_rc)"
    printf '\n  %s%s%s\n\n' "$DIM" "$PATH_LINE" "$RESET"
    printf 'Then open a new shell (or run the export above) so %s%s%s is on your PATH.\n\n' "$BOLD" "${BIN_NAME}" "$RESET"
  fi
fi

# Post-install gate: confirm a fresh login shell finds rubino, or fail loudly.
verify_fresh_shell "$PATH_LINE"

printf '%sNext step:%s\n\n' "$BOLD" "$RESET"
printf '  %s%s setup%s   %s# guided first-run: pick a provider, paste a key%s\n\n' "$GREEN" "${BIN_NAME}" "$RESET" "$DIM" "$RESET"

printf 'Run: %s%s setup%s\n' "$BOLD" "${BIN_NAME}" "$RESET"
