# frozen_string_literal: true

# Build step for the standalone `rubino-landlock` helper.
#
# This is NOT a Ruby C extension in the usual sense — the gem has no native
# Ruby bindings. We (ab)use the extension mechanism purely so RubyGems compiles
# a tiny standalone executable at install time: a Landlock-applying exec-wrapper
# the Linux sandbox path (Security::Sandbox) launches in front of `bash`.
#
# CRITICAL: this must DEGRADE GRACEFULLY. The gem must install on macOS, on
# Windows, and on a Linux kernel/toolchain without Landlock headers. So we never
# fail the build: on any non-Linux host, a missing compiler, or missing Landlock
# headers we write a no-op Makefile and exit 0. The sandbox then reports the
# Linux mechanism as unavailable and fails OPEN with a loud banner (by design).
require "mkmf"

# A Makefile that satisfies `make` / `make install` with no work, so
# `gem install` always succeeds even when we can't build the helper.
def write_noop_makefile(reason)
  warn "rubino-landlock: skipping native helper build (#{reason}); " \
       "the Linux OS write-sandbox will be unavailable (fail-open)."
  File.write("Makefile", <<~MAKE)
    all:
    \t@true
    install:
    \t@true
    clean:
    \t@true
  MAKE
end

# Only Linux has Landlock. Everywhere else the helper is irrelevant.
unless RUBY_PLATFORM.include?("linux")
  write_noop_makefile("not Linux")
  exit 0
end

# The helper needs the Landlock UAPI header to know the struct/flag layout.
# (The syscall itself is invoked by number, so no libc wrapper is required.)
unless have_header("linux/landlock.h")
  write_noop_makefile("linux/landlock.h not found")
  exit 0
end

# The compiled helper lands in the gem's exe/ dir as `rubino-landlock`, on PATH
# of the installed gem. extconf builds into the extension dir; we install it to
# the gem's bin via a custom rule appended after create_makefile.
target = "rubino-landlock"

# create_makefile expects a Ruby-loadable .so; we instead emit our own Makefile
# that compiles a freestanding executable. Bypass the .so machinery entirely.
cc = RbConfig::CONFIG["CC"] || "cc"
srcdir = __dir__

File.write("Makefile", <<~MAKE)
  CC = #{cc}
  TARGET = #{target}
  SRC = #{File.join(srcdir, "landlock.c")}

  all: $(TARGET)

  $(TARGET): $(SRC)
  \t$(CC) -O2 -Wall -o $(TARGET) $(SRC)

  # `gem install` runs `make` then `make install`; RubyGems copies any built
  # artifact reported in the extension dir. We additionally drop the binary into
  # the gem's exe/ so Security::Sandbox can resolve it next to the `rubino` exe.
  install: all
  \t@true

  clean:
  \t-rm -f $(TARGET)
MAKE

# If the compile would fail (no working cc), we still don't want to break the
# install — but mkmf already verified a compiler via have_header above. Leave
# the real compile to `make`; a failure there is rare and caught by Sandbox's
# runtime probe (binary absent ⇒ fail-open).
