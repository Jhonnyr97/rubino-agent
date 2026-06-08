# rubino system image

This directory documents the system image shipped by rubino. The image is
produced by a CI workflow on every `v*.*.*` tag push and on demand.

## How the image is built

The workflow runs on `ubuntu-latest` and:

1. Bootstraps an Ubuntu `noble` rootfs with `mmdebstrap` (variant `minbase`,
   components `main,universe`).
2. Installs the base packages listed below straight into the rootfs.
3. Rsyncs the checked-out source tree into `/opt/rubino/src` (excluding
   `.git`, `node_modules`, `coverage`, `log`, and `spec/fixtures/large/*`).
4. Chroots into the rootfs, runs `bundle install`, then
   `gem build rubino-agent.gemspec` and `gem install rubino-*.gem` so the
   `rubino` executable is on `PATH`.
5. Drops the systemd unit, the config template, the cloud-init datasource
   pinning, and the placeholder `.env`.
6. Packs the result as a unified system image (`image.tar.xz` +
   `rootfs.squashfs`) under `dist/image/`, alongside `SHA256SUMS` and
   `IMPORT.md`.
7. Uploads the artifacts and, on tag pushes (or when `publish_release` is
   true on a manual run), attaches them to a GitHub Release.

The workflow refuses to build if `image_name` contains a product brand; the
image must stay product-neutral.

## What is preinstalled

System packages (apt, from `noble`):

- `systemd-sysv`, `dbus`, `udev`, `cloud-init`
- `ca-certificates`, `curl`, `git`, `jq`, `openssh-client`, `locales`
- `build-essential`
- `ruby-full` (Ruby 3.3+ on `noble`), `libsqlite3-dev`
- `ripgrep`
- `gh` (GitHub CLI)

rubino itself is installed from the source tree as a built gem, so the
`rubino` binary lives at `/usr/local/bin/rubino`.

## Launching an instance

Import the unified image into your container/VM manager and launch an instance
named `ra-1` from it (the exact commands depend on your runtime).

The image targets system containers and VMs; cloud-init is pinned to
`NoCloud, LXD, None` via `/etc/cloud/cloud.cfg.d/90-datasource.cfg` so
the seed bundled by the runtime is picked up cleanly.

## Provisioning the env

The image ships `/etc/rubino/.env` with placeholders and mode `0600`:

```
RUBINO_API_KEY=CHANGE_ME_AT_PROVISIONING
RUBINO_ENCRYPTION_KEY=CHANGE_ME_AT_PROVISIONING
RUBINO_HOME=/var/lib/rubino
OPENAI_API_KEY=CHANGE_ME
ANTHROPIC_API_KEY=CHANGE_ME
SEARXNG_URL=
```

Replace the `CHANGE_ME*` values at provisioning time (cloud-init user-data,
your secrets manager, or by exec'ing into the instance). `SEARXNG_URL` is
optional and may stay empty. The minimal runtime config lives at
`/etc/rubino/config.yml`.

After updating the env file, restart the service inside the instance:

```bash
systemctl restart rubino.service
```

## systemd unit

The service is `rubino.service`. It runs as `root` for v0.1 (a dedicated
hardened user is post-v0.1 work), loads `/etc/rubino/.env`, and execs:

```
/usr/local/bin/rubino server --host 0.0.0.0 --port 3500
```

`Restart=always` with `RestartSec=5` keeps the agent up across crashes.
