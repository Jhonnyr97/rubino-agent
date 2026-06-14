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
    fish) printf '%s\n' "${__fish_config_dir:-$HOME/.config/fish}/config.fish" ;;
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
    fish)
      # fish does NOT read ~/.profile (it isn't POSIX); its config lives in
      # config.fish, sourced for every fish session (login + interactive).
      printf '%s\n' "${__fish_config_dir:-$HOME/.config/fish}/config.fish"
      ;;
    *)
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

# The shell-correct line that prepends $1 (a directory) to PATH, persisted into
# an rc file. POSIX shells (bash/zsh/sh) get `export PATH="DIR:$PATH"`; fish does
# NOT understand that syntax (no `$PATH` colon list, no `export`) — it needs
# `fish_add_path DIR`. Writing the POSIX form into config.fish would be ignored
# (or error), leaving fish users with a broken PATH while we report success
# (INST-R3-1). Args: $1 = bindir.
path_persist_line() {
  local dir="$1" shell_name
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    fish) printf 'fish_add_path %s\n' "$dir" ;;
    *)    printf 'export PATH="%s:$PATH"\n' "$dir" ;;
  esac
}

# Acquire an exclusive per-rc lock, run a command, release. The lock makes the
# check-then-append in _append_line_to_rc atomic: without it two concurrent
# installs both pass the `grep -qF` (the line is in neither yet) and both append,
# producing DUPLICATE activation blocks (TOCTOU).
#
# We use `mkdir` as the mutex primitive, not `flock`: mkdir is atomic on every
# POSIX filesystem and present on macOS/busybox alike (flock ships with
# util-linux and is absent on stock macOS). Spin with a short sleep until the
# lock dir is ours, with a stale-lock timeout so a crashed installer can't wedge
# the next one forever. Falls back to running unlocked only if even mkdir is
# somehow unavailable. Args: $1 = lock dir, $2... = command to run while held.
with_rc_lock() {
  local lockdir="$1"; shift
  local waited=0
  # Try for up to ~5s (50 * 0.1s), then assume the holder died and proceed.
  while ! mkdir "$lockdir" 2>/dev/null; do
    if [ "$waited" -ge 50 ]; then
      rm -rf "$lockdir" 2>/dev/null || true
      mkdir "$lockdir" 2>/dev/null || break
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  # Ensure we drop the lock even if the command fails.
  "$@"
  local rc=$?
  rmdir "$lockdir" 2>/dev/null || true
  return "$rc"
}

# Append a single line, once, to one rc file. Idempotent via RC_MARKER + a grep
# for the exact line. MUST run under with_rc_lock so the grep-then-append can't
# race a concurrent install. Echoes "touched" if the line is present afterward.
_append_line_to_rc() {
  local line="$1" rc="$2"
  # Create the file if missing (login shells will source it). Ensure the parent
  # dir exists first — fish's config.fish lives under ~/.config/fish, which may
  # not exist yet on a fresh box (a bare `: >"$rc"` would then fail silently).
  [ -e "$rc" ] || mkdir -p "$(dirname "$rc")" 2>/dev/null || true
  [ -e "$rc" ] || : >"$rc" 2>/dev/null || return 0
  if grep -qF "$line" "$rc" 2>/dev/null; then
    printf 'touched'
    return 0
  fi
  if {
      printf '\n%s\n' "$RC_MARKER"
      printf '%s\n' "$line"
    } >>"$rc" 2>/dev/null; then
    printf 'touched'
  fi
}

# Append a single line, once, to each startup file from rc_targets(). Guarded by
# RC_MARKER + a grep for the exact line so re-runs don't duplicate, and by an
# exclusive per-rc lock so CONCURRENT installs don't duplicate either (TOCTOU).
# Sets PERSISTED_RC to the space-separated files it touched. Returns 0 if the
# line is present in at least one target afterward.
persist_to_rc() {
  local line="$1" rc any=1 touched="" res
  [ "$RUBINO_NO_MODIFY_RC" = "1" ] && return 1
  while IFS= read -r rc; do
    [ -n "$rc" ] || continue
    # The subshell scopes the "touched" capture; the lock serializes the
    # check-then-append against any other installer touching this same rc.
    res="$(with_rc_lock "${rc}.rubino.lock.d" _append_line_to_rc "$line" "$rc")"
    if [ "$res" = "touched" ]; then
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
    # fish: probe fish itself (a fresh login+interactive session sources
    # config.fish), NOT bash -lic — bash would find a POSIX export the user's
    # fish never reads, reporting a false success over a broken fish (INST-R3-1).
    # `type -q` is fish's `command -v`. If fish isn't installed to probe with,
    # fall through to a best-effort PATH check rather than claim success.
    fish)
      if command -v fish >/dev/null 2>&1; then
        fish -l -i -c "type -q ${BIN_NAME}" >/dev/null 2>&1 || found=0
      else
        command -v "${BIN_NAME}" >/dev/null 2>&1 || found=0
      fi
      ;;
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

# --- preflight: build prerequisites (#242) ----------------------------------
#
# The gem builds native extensions (e.g. nio4r), so a C toolchain is always
# needed; the rv/mise methods additionally fetch + unpack precompiled tarballs
# (xz) and may clone the repo (git). Rather than let `gem install` blow up deep
# in a native build, check the prerequisites the CHOSEN method needs up front:
# install them automatically when we're privileged (root + a known pkg manager),
# otherwise fail with a single actionable command the user can copy-paste.

# True when we can install OS packages non-interactively (root, or sudo present).
can_install_pkgs() {
  [ "$(id -u 2>/dev/null || echo 1000)" = "0" ] || command -v sudo >/dev/null 2>&1
}

# Run a privileged command (direct as root, else via sudo).
as_root() {
  if [ "$(id -u 2>/dev/null || echo 1000)" = "0" ]; then "$@"; else sudo "$@"; fi
}

# Detect a C compiler (any of cc/gcc/clang) — toolchains name it differently.
have_cc() { for c in cc gcc clang; do command -v "$c" >/dev/null 2>&1 && return 0; done; return 1; }

# Map an abstract prerequisite to the package providing it, install via the
# host's package manager. Returns non-zero if we couldn't install it.
install_pkg_for() {
  local want="$1"  # one of: toolchain xz git curl
  if command -v apt-get >/dev/null 2>&1; then
    local pkg
    case "$want" in
      toolchain) pkg="build-essential" ;;
      xz)        pkg="xz-utils" ;;
      git)       pkg="git" ;;
      curl)      pkg="curl" ;;
    esac
    as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    case "$want" in
      toolchain) as_root dnf install -y -q gcc make >/dev/null 2>&1 ;;
      xz)        as_root dnf install -y -q xz >/dev/null 2>&1 ;;
      git)       as_root dnf install -y -q git >/dev/null 2>&1 ;;
      curl)      as_root dnf install -y -q curl >/dev/null 2>&1 ;;
    esac
  elif command -v apk >/dev/null 2>&1; then
    case "$want" in
      toolchain) as_root apk add --no-cache build-base >/dev/null 2>&1 ;;
      xz)        as_root apk add --no-cache xz >/dev/null 2>&1 ;;
      git)       as_root apk add --no-cache git >/dev/null 2>&1 ;;
      curl)      as_root apk add --no-cache curl >/dev/null 2>&1 ;;
    esac
  else
    return 1
  fi
}

# The copy-paste install command we suggest when we can't install ourselves.
pkg_hint() {
  case "$PLATFORM" in
    macos) printf 'xcode-select --install   # C toolchain (Homebrew also provides git/curl)' ;;
    linux)
      if   command -v apt-get >/dev/null 2>&1; then printf 'sudo apt-get install -y build-essential xz-utils git curl'
      elif command -v dnf     >/dev/null 2>&1; then printf 'sudo dnf install -y gcc make xz git curl'
      elif command -v apk     >/dev/null 2>&1; then printf 'sudo apk add build-base xz git curl'
      else printf 'install a C toolchain (gcc/clang + make), xz, git and curl with your package manager'
      fi
      ;;
  esac
}

# Check (and, when privileged, install) the prerequisites the chosen method
# needs. Args: $1 = method (brew|rv|mise). Fails loudly if a hard requirement is
# missing and we can't provide it.
preflight_prereqs() {
  local method="$1"
  # Every method ends up building native extensions → needs a C toolchain.
  # rv/mise fetch and unpack xz tarballs → need xz. The git fallback needs git.
  # (curl is already required at the top of the script.)
  local needs="toolchain"
  case "$method" in
    rv|mise) needs="toolchain xz git" ;;
    brew)    needs="toolchain git" ;;
  esac

  local want missing="" installed=""
  for want in $needs; do
    local present=0
    case "$want" in
      toolchain) have_cc && command -v make >/dev/null 2>&1 && present=1 ;;
      *)         command -v "$want" >/dev/null 2>&1 && present=1 ;;
    esac
    [ "$present" -eq 1 ] && continue

    # macOS: don't try to install the toolchain ourselves (xcode-select is
    # interactive); just record it as missing for the actionable error.
    if [ "$PLATFORM" = "macos" ] || ! can_install_pkgs; then
      missing="${missing:+$missing }$want"
      continue
    fi

    info "Missing build prerequisite '${want}'; installing it..."
    if install_pkg_for "$want"; then
      # Re-check so we don't claim success on a no-op package manager.
      local ok_now=0
      case "$want" in
        toolchain) have_cc && command -v make >/dev/null 2>&1 && ok_now=1 ;;
        *)         command -v "$want" >/dev/null 2>&1 && ok_now=1 ;;
      esac
      if [ "$ok_now" -eq 1 ]; then installed="${installed:+$installed }$want"
      else missing="${missing:+$missing }$want"; fi
    else
      missing="${missing:+$missing }$want"
    fi
  done

  [ -n "$installed" ] && ok "Installed build prerequisites: ${installed}."

  if [ -n "$missing" ]; then
    warn "Missing build prerequisite(s): ${missing}."
    warn "rubino's gem builds native extensions and the ${method} method needs these to proceed."
    printf '%sInstall them, then re-run this installer:%s\n' "$BOLD" "$RESET" >&2
    printf '\n  %s\n\n' "$(pkg_hint)" >&2
    die "missing build prerequisites: ${missing} (see the command above)."
  fi
}

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

# Now that we know the method, check (and auto-install when privileged) the
# build prerequisites it needs, with a clear actionable error otherwise (#242).
preflight_prereqs "$METHOD"

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
  # On systems whose glibc rv considers "too old" (e.g. Debian 12 / glibc 2.36)
  # rv installs a musl-static build and then provisions a musl Ruby that this
  # glibc system can't execute. `rv ruby install` may even print "Installed",
  # but `rv ruby find` then reports NoMatchingRuby — a silent, broken install
  # (#241). We don't `die` here: rv on such a system simply can't provide a
  # working Ruby, but the mise path (precompiled, glibc-correct) can. So we
  # steer the user over to mise instead of leaving them with a broken rubino.
  #
  # Detection is post-hoc on `rv ruby find`: it's the exact failure the user
  # hits, regardless of the underlying cause, and it doesn't regress the working
  # ubuntu/rv path (where `find` succeeds and we proceed as before).
  if ! "$rv_bin" ruby install "${RUBY_VERSION}" >/dev/null 2>&1; then
    warn "rv could not install Ruby ${RUBY_VERSION} on this system."
    fallback_to_mise_from_rv
    return 0   # not reached: fallback_to_mise_from_rv exits the script.
  fi
  local ruby_bin
  if ! ruby_bin="$("$rv_bin" ruby find "${RUBY_VERSION}" 2>/dev/null)" || [ -z "$ruby_bin" ] || [ ! -x "$ruby_bin" ]; then
    warn "rv installed Ruby ${RUBY_VERSION} but can't locate a usable binary for it"
    warn "(common on Debian 12 / older glibc, where rv falls back to a musl build"
    warn "that this system can't execute)."
    fallback_to_mise_from_rv
    return 0   # not reached.
  fi
  RUBY_BIN_DIR="$(dirname "$ruby_bin")"
  RUBY_LABEL="Ruby ${RUBY_VERSION} (rv)"

  rubyx() { "$rv_bin" run --ruby "${RUBY_VERSION}" "$@"; }
  ok "${RUBY_LABEL} ready: ${RUBY_BIN_DIR}"
}

# Hand off from a broken rv install to the mise method, which provisions a
# precompiled glibc-correct Ruby that works where rv's musl build doesn't (#241).
# setup_mise() runs the full install and exits, so this never returns.
fallback_to_mise_from_rv() {
  warn "Falling back to the mise install method (works on this system)."
  METHOD="mise"
  # mise needs the same build prerequisites; re-run preflight for its method now
  # that we've switched (the earlier preflight ran for 'rv').
  preflight_prereqs "mise"
  setup_mise
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
  # The activation snippet differs by shell: POSIX shells eval the command
  # substitution; fish pipes it to `source` (fish has no `eval "$(...)"`). Using
  # the POSIX form in config.fish would error and leave fish broken (INST-R3-1).
  if [ "$shell_name" = "fish" ]; then
    act_line="$mise_bin activate fish | source"
  else
    act_line="eval \"\$($mise_bin activate ${act_sh:-bash})\""
  fi

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

# Set by install_published() when the gem install ran but failed for a reason
# OTHER than "not published / no CLI" — i.e. a real error (network, native build,
# permissions) we must surface instead of the misleading git-fallback message.
GEM_INSTALL_LOG=""

install_published() {
  info "Trying published gem: gem install ${GEM_NAME}..."
  # Capture output instead of discarding it: on a genuine failure we want to show
  # the real cause, not hide it behind ">/dev/null" and a misleading message (#242).
  local out rc
  out="$(rubyx gem install "${GEM_NAME}" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    if gem_bin_present; then
      ok "Installed ${GEM_NAME} from RubyGems."
      return 0
    fi
    # Installed cleanly but ships no CLI → legitimately fall through to the git
    # build (this is the real "not the CLI gem yet" case).
    warn "A '${GEM_NAME}' gem was installed but it doesn't provide the '${BIN_NAME}' CLI; building from source instead."
    rubyx gem uninstall "${GEM_NAME}" -aIx >/dev/null 2>&1 || true
    return 1
  fi

  # gem install actually errored. If RubyGems says the gem can't be found, the
  # CLI simply isn't published yet → the git build is the right fallback (quietly).
  if printf '%s' "$out" | grep -qiE "could not find a valid gem|Unable to download|find .*${GEM_NAME}.* in any"; then
    return 1
  fi

  # Any other failure (native build, network, permissions): stash it so the
  # caller surfaces the real error rather than "isn't on RubyGems yet".
  GEM_INSTALL_LOG="$out"
  return 2
}

install_from_git() {
  warn "Building ${GEM_NAME} from ${REPO_URL} (the CLI gem isn't on RubyGems yet)."
  need git
  local work
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  # Run a build step, capturing output; on failure surface the real error (#242)
  # instead of a bare "X failed" with the cause swallowed by >/dev/null.
  run_step() {
    local label="$1"; shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
      warn "${label} failed. The actual error was:"
      printf '%s\n' "$out" >&2
      die "${label} failed (real error shown above)."
    fi
  }
  run_step "git clone of ${REPO_URL}" git clone --depth 1 "$REPO_URL" "$work/${REPO_NAME}"
  (
    cd "$work/${REPO_NAME}"
    info "Resolving dependencies (bundle install)..."
    run_step "bundle install" rubyx bundle install
    info "Building the gem (rake build)..."
    run_step "rake build" rubyx rake build
    local pkg
    pkg="$(ls -1 pkg/${GEM_NAME}-*.gem 2>/dev/null | head -n1)"
    [ -n "$pkg" ] || die "rake build produced no gem in pkg/."
    info "Installing ${pkg}..."
    run_step "gem install of the built package" rubyx gem install "$pkg"
  )
  gem_bin_present || die "built and installed ${GEM_NAME} but the '${BIN_NAME}' executable is missing."
  ok "Installed ${GEM_NAME} from source."
}

if gem_bin_present; then
  CURRENT_VER="$("${GEM_BIN_DIR}/${BIN_NAME}" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  ok "${BIN_NAME} ${CURRENT_VER:+v$CURRENT_VER }is already installed (re-run safe)."
else
  # `|| gem_rc=$?` keeps the non-zero returns (1=not-published, 2=real-error)
  # from tripping `set -e`; default 0 on success.
  gem_rc=0
  install_published || gem_rc=$?
  case "$gem_rc" in
    0) : ;;                # installed the published gem
    1) install_from_git ;; # not published / no CLI yet → build from source
    *)                     # real error: surface the actual gem output (#242)
      warn "gem install ${GEM_NAME} failed. The actual error was:"
      printf '%s\n' "${GEM_INSTALL_LOG}" >&2
      die "gem install ${GEM_NAME} failed (real error shown above)."
      ;;
  esac
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

# Shell-correct PATH-persist line (fish needs `fish_add_path`, not POSIX export).
PATH_LINE="$(path_persist_line "${GEM_BIN_DIR}")"

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
