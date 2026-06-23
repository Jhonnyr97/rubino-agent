/*
 * rubino-landlock — a tiny unprivileged exec-wrapper that confines filesystem
 * WRITES to a set of allowed roots using the Linux Landlock LSM, then execs the
 * remaining argv (normally `bash -o pipefail -c <command>`).
 *
 * It is launched by Security::Sandbox as the argv prefix on the single
 * Process.spawn in shell_tool.rb:
 *
 *     rubino-landlock -- bash -o pipefail -c <command>
 *
 * The writable roots arrive as a single NUL-separated env var
 * RUBINO_SANDBOX_WRITABLE_ROOTS (paths are never interpolated into argv, so a
 * path containing spaces/quotes is safe).
 *
 * Design asymmetry (matches the macOS Seatbelt profile): we HANDLE only the
 * write-class access rights and grant them for the allowed roots; we never
 * handle the read rights, so reads stay completely unrestricted (#406).
 *
 * Fail-open contract: if Landlock is unavailable at runtime (old kernel,
 * disabled at boot) we do NOT block — we just exec the command unconfined. The
 * loud "sandbox unavailable" banner is the Ruby side's responsibility; this
 * helper degrades silently so a working shell is never bricked. (We only abort
 * on a genuine internal error AFTER a ruleset was successfully created, where
 * proceeding would be a silent confinement bypass.)
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/landlock.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef landlock_create_ruleset
static inline int landlock_create_ruleset(
    const struct landlock_ruleset_attr *attr, size_t size, __u32 flags) {
  return (int)syscall(__NR_landlock_create_ruleset, attr, size, flags);
}
#endif

#ifndef landlock_add_rule
static inline int landlock_add_rule(int ruleset_fd,
                                    enum landlock_rule_type rule_type,
                                    const void *rule_attr, __u32 flags) {
  return (int)syscall(__NR_landlock_add_rule, ruleset_fd, rule_type, rule_attr,
                      flags);
}
#endif

#ifndef landlock_restrict_self
static inline int landlock_restrict_self(int ruleset_fd, __u32 flags) {
  return (int)syscall(__NR_landlock_restrict_self, ruleset_fd, flags);
}
#endif

/* The full write-class access-rights mask we know about. We intersect this with
 * what the running kernel actually supports (the ABI) so an older kernel does
 * not EINVAL on a flag it doesn't define. Read rights are deliberately omitted
 * — reads stay broad. */
static uint64_t write_access_mask(int abi) {
  uint64_t m = 0;
#ifdef LANDLOCK_ACCESS_FS_WRITE_FILE
  m |= LANDLOCK_ACCESS_FS_WRITE_FILE;
#endif
#ifdef LANDLOCK_ACCESS_FS_MAKE_REG
  m |= LANDLOCK_ACCESS_FS_MAKE_REG;
#endif
#ifdef LANDLOCK_ACCESS_FS_MAKE_DIR
  m |= LANDLOCK_ACCESS_FS_MAKE_DIR;
#endif
#ifdef LANDLOCK_ACCESS_FS_REMOVE_FILE
  m |= LANDLOCK_ACCESS_FS_REMOVE_FILE;
#endif
#ifdef LANDLOCK_ACCESS_FS_REMOVE_DIR
  m |= LANDLOCK_ACCESS_FS_REMOVE_DIR;
#endif
#ifdef LANDLOCK_ACCESS_FS_MAKE_CHAR
  m |= LANDLOCK_ACCESS_FS_MAKE_CHAR;
#endif
#ifdef LANDLOCK_ACCESS_FS_MAKE_SOCK
  m |= LANDLOCK_ACCESS_FS_MAKE_SOCK;
#endif
#ifdef LANDLOCK_ACCESS_FS_MAKE_FIFO
  m |= LANDLOCK_ACCESS_FS_MAKE_FIFO;
#endif
#ifdef LANDLOCK_ACCESS_FS_MAKE_BLOCK
  m |= LANDLOCK_ACCESS_FS_MAKE_BLOCK;
#endif
#ifdef LANDLOCK_ACCESS_FS_MAKE_SYM
  m |= LANDLOCK_ACCESS_FS_MAKE_SYM;
#endif
  /* ABI 3+: truncate. */
#ifdef LANDLOCK_ACCESS_FS_TRUNCATE
  if (abi >= 3) m |= LANDLOCK_ACCESS_FS_TRUNCATE;
#endif
  /* ABI 2+: refer (rename/link across dirs). */
#ifdef LANDLOCK_ACCESS_FS_REFER
  if (abi >= 2) m |= LANDLOCK_ACCESS_FS_REFER;
#endif
  /* ABI 5+: device ioctl. */
#ifdef LANDLOCK_ACCESS_FS_IOCTL_DEV
  if (abi >= 5) m |= LANDLOCK_ACCESS_FS_IOCTL_DEV;
#endif
  return m;
}

/* Grant the handled write rights on one path (a directory or a file like
 * /dev/null). A non-existent path is skipped silently. Returns 0 on success or
 * skip, -1 on a hard error after the path was opened. */
static int grant_path(int ruleset_fd, const char *path, uint64_t allowed) {
  struct landlock_path_beneath_attr pb = {0};
  int fd = open(path, O_PATH | O_CLOEXEC);
  if (fd < 0) {
    /* Missing root (e.g. no $TMPDIR) — nothing to grant, not fatal. */
    return 0;
  }
  pb.parent_fd = fd;
  pb.allowed_access = allowed;
  int rc = landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &pb, 0);
  close(fd);
  if (rc) {
    fprintf(stderr, "rubino-landlock: cannot grant write to %s: %s\n", path,
            strerror(errno));
    return -1;
  }
  return 0;
}

/* exec the post-`--` argv unconfined. Used on the fail-open paths. */
static int exec_rest(char **argv) {
  execvp(argv[0], argv);
  fprintf(stderr, "rubino-landlock: exec %s failed: %s\n", argv[0],
          strerror(errno));
  return 127;
}

int main(int argc, char **argv) {
  /* Find the `--` separator; everything after it is the command to run. */
  char **rest = NULL;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--") == 0) {
      rest = &argv[i + 1];
      break;
    }
  }
  if (!rest || !rest[0]) {
    fprintf(stderr, "usage: rubino-landlock -- CMD [ARGS...]\n");
    return 2;
  }

  /* Probe the runtime ABI. <1 means Landlock is not available on this kernel:
   * fail OPEN (exec unconfined) — never brick the shell. */
  int abi = landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
  if (abi < 1) {
    return exec_rest(rest);
  }

  uint64_t allowed = write_access_mask(abi);
  struct landlock_ruleset_attr attr = {.handled_access_fs = allowed};

  int ruleset_fd = landlock_create_ruleset(&attr, sizeof(attr), 0);
  if (ruleset_fd < 0) {
    /* Kernel claims an ABI but won't create the ruleset — fail open. */
    return exec_rest(rest);
  }

  /* Always allow /dev/null + the controlling tty so interactive shells, pipes
   * and `> /dev/null` keep working regardless of the configured roots. */
  grant_path(ruleset_fd, "/dev/null", allowed);
  grant_path(ruleset_fd, "/dev/tty", allowed);
  grant_path(ruleset_fd, "/dev/ptmx", allowed);

  /* Grant the configured writable roots. They arrive NEWLINE-separated, not
   * NUL-separated: getenv() returns a C string that terminates at the first
   * NUL, so an env var literally cannot carry embedded NULs. The Ruby side
   * (Security::Sandbox#extra_env) joins the roots with '\n' for this reason; a
   * path containing a newline is rejected there before we ever see it. */
  const char *roots = getenv("RUBINO_SANDBOX_WRITABLE_ROOTS");
  if (roots && *roots) {
    char *buf = strdup(roots);
    if (!buf) {
      close(ruleset_fd);
      return exec_rest(rest); /* OOM before confinement — fail open. */
    }
    char *p = buf;
    char *line;
    while ((line = strsep(&p, "\n")) != NULL) {
      if (*line == '\0') continue;
      if (grant_path(ruleset_fd, line, allowed) != 0) {
        /* A real add-rule failure AFTER ruleset creation would mean a root is
         * silently NOT writable — confinement is tighter than intended, which
         * is safe; continue rather than fail open. */
      }
    }
    free(buf);
  }

  /* Required before restrict_self for an unprivileged process. */
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) {
    fprintf(stderr, "rubino-landlock: prctl(NO_NEW_PRIVS): %s\n",
            strerror(errno));
    close(ruleset_fd);
    /* No confinement was applied yet → safe to fail open. */
    return exec_rest(rest);
  }

  if (landlock_restrict_self(ruleset_fd, 0)) {
    fprintf(stderr, "rubino-landlock: restrict_self: %s\n", strerror(errno));
    close(ruleset_fd);
    /* restrict_self failed → no confinement applied → fail open. */
    return exec_rest(rest);
  }
  close(ruleset_fd);

  /* Confinement is now irreversibly active for this thread and all children.
   * exec the command — a write outside the granted roots will EACCES/EPERM. */
  execvp(rest[0], rest);
  fprintf(stderr, "rubino-landlock: exec %s failed: %s\n", rest[0],
          strerror(errno));
  return 127;
}
