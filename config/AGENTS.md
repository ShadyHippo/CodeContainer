# You are inside CodeContainer

A single Ubuntu 26.04 container running on a home NAS (UnRaid), reachable over
Tailscale. T3 Code drives you (OpenCode) headlessly. There is **no GUI and no
`localhost` a human can see** — the only way the user sees your work is through
the published port range below.

## Where things live

- `~/Projects` (`/root/Projects`) is the projects share: the **only** place
  for code and repos. Every project is a subdirectory of it.
- The container may also have other host paths bind-mounted for state and
  caches (e.g. `~/.config`, `~/.local`, `~/.t3code`, `/mise`, `/tmp`).
  Those persist in this setup, but they are for tooling/state — **never**
  put a repo or project there.
- Never create files at the `Projects` root — that pollutes the whole share.
  Work inside the project directory you were pointed at.
- **Clone or init only inside `~/Projects`.** A repo cloned anywhere under
  `$HOME` outside `~/Projects` is in the wrong place (and may be ephemeral
  depending on the mount setup). When unsure, `cd ~/Projects` first.
- **Never run recursive operations against `$HOME`** — `rm -rf ~/*`,
  `git clean -xdff ~`, `find ~ -delete`. The projects share is mounted under it.

## Citing files to the user

Cite files as **absolute paths under the projects root**, for example:

    /root/Projects/<repo>/src/x.ts:42

T3 Code turns inline code into a link, but only for paths it recognises:
absolute paths (under known roots such as `/root/`), `~`/`./`/`../` paths,
relative paths containing a slash, and bare `file.ext:line`. Absolute paths are
the robust choice because they do not depend on the session's working
directory.

## Showing the user a running app (most important)

`localhost` is meaningless here. To show something:

1. Bind to `0.0.0.0` — never `127.0.0.1`. Use `PORT=$(freeport)` and pass it in:

       pnpm dev --host 0.0.0.0 --port "$PORT"

   Prefer **30000-30099**: it is the convention, and it is the only range that
   works when this container is reached through published ports. On its own LAN
   address, any port works.

2. Give the user `http://<PREVIEW_HOST>:<PORT>`. Run `preview` — it prints the
   exact URL for every listener and flags anything bound to loopback, which
   looks fine in here and 404s for the user.

   Do not build demo links from the T3 Code hostname: it is fronted by a proxy
   that forwards only the app port.

Ports 3773 (T3 Code) and 4096 (OpenCode) are taken; never assume 30000 is free.
Ports are direct — no reverse proxy — so HMR and websockets behave normally.

## There is no Docker here

No `docker`, no `docker compose`, no DinD, no socket. If a project ships a
`docker-compose.yml`, do **not** try to use it. Run the pieces directly:

- Databases: `postgresql`, `mariadb`, and `redis` are installed as normal
  processes (`service postgresql start`, `redis-server --daemonize yes`), or
  just use SQLite.
- Services: run them as processes against the port range above.

## Releasing services (docker-deploy)

You cannot deploy containers yourself — no socket. A separate container,
`docker-deploy` ([repo](https://github.com/ShadyHippo/DockerDeploy)), owns that
and exposes one audited script per stack:

    curl -s http://docker-deploy:9000/scripts              # what is callable
    curl -s -XPOST http://docker-deploy:9000/run/easyedit  # run one

- The **name is the only input**. No arguments, no paths, no shell.
- Each script pulls (or builds) and recreates only what changed, so a run with no
  new image is a no-op.
- `codecontainer` recreates **this** container and therefore kills the session
  that called it. Only call it when the user asked and the work is finished.
- You cannot add or edit scripts. They live on the host, are written and audited
  by the user, and are read on every request.
- A `404` means the name is not in the allowlist; the response carries the list.
  `rejected` in `GET /scripts` names scripts that exist but failed their
  permission checks (owner, mode, symlink).
- Reachable only on the internal Docker network, by that name. There is no
  public URL and no port published to the LAN.

## Long-running work

Run dev servers and anything long-lived under `tmux` (`tmux new -s work`) or
background it properly. Work that dies with your shell is work the user cannot
see.

## Building container images

You can **build and push** images, but you have **no Docker daemon and no
socket**, and you cannot start, stop or inspect any container — not the host's,
not your own. Use `buildah`, which builds daemonlessly:

    buildah bud -t myapp:latest .              # run in the project directory
    buildah push myapp:latest ghcr.io/you/myapp:latest

- Storage driver is `vfs` and isolation is `chroot`; both are preconfigured, so
  plain `buildah bud` works. Do not pass `--storage-driver` or `--isolation`
  unless you have a reason.
- `docker`, `docker compose` and `podman` are **not** available. If a project
  ships a `docker-compose.yml`, you cannot use it — build an image instead, or
  run the services as processes.
- Registry credentials persist: `buildah login ghcr.io -u <user>` writes to
  `~/.config/containers/auth.json`, which is on a bind mount.

## Scratch space

`/tmp` is a large **disk-backed** scratch directory (a bind mount from the
host), not the container's own storage. `TMPDIR` already points there. Use it
freely for large intermediate files — build trees, kernel sources, archives.

It is **wiped between sessions**, so never leave anything you need in `/tmp`.
Anything durable goes in the project under `~/Projects`.

## Toolchains

**Per-project runtimes come from mise.** `rust` and `go` are installed at boot
from mise; pin a version per project with a `mise.toml` at the project root:

    mise use go@1.24        # writes/updates mise.toml
    mise use rust@stable
    mise install            # installs whatever mise.toml pins

**Commit `mise.toml` / `.tool-versions`.** Pinning the toolchain alongside the
code is the point — don't gitignore them.

**From the image, not mise:** Node 24 (pnpm/yarn/bun/deno), TypeScript, Python
3.14 (pip/uv/venv), Ruby, PHP 8.5 + Composer, Elixir/Erlang, Lua, C/C++ (gcc 15,
clang 21), CMake/Ninja/Meson, ffmpeg, ImageMagick, Graphviz, Pandoc, Typst,
TeX Live, PostgreSQL 18, MariaDB 11, Redis 8, SQLite. (HandBrake is NOT
preinstalled; install it per the durable rules above if a task needs it.)

**Not installed at all** — add per project when needed:
`mise use java@21`, `mise use gradle@8`, `mise use maven@3`, `mise use dotnet`.

Language servers are on PATH: rust-analyzer, gopls, typescript-language-server,
pyright, clangd, lua-language-server, bash/yaml/json/html/css, tailwind,
dockerfile.

Prefer project-local dependencies (in the project dir, which persists). Globals
are possible — `~/.local` and `~/go` persist — but keep them rare in a shared
image.

## Durable installs (for you, the agent)

The image ships a large toolchain (see below), but anything you add at runtime
must land in a **persistent** location or it vanishes on rebuild. Prefer:

- **Node/JS:** `npm install -g <pkg>` — installs into `~/.local` (bind-mounted),
  already on `PATH`. Project-local deps go in the project dir.
- **Python:** a venv inside the project (`uv venv && uv pip install ...`).
  System pip is locked; do not fight it.
- **Rust/Go/Java/.NET:** `mise use ...` — pins into `/mise` (bind-mounted).
- **Other binaries:** download/extract into `~/.local/bin` or the project dir
  (both on `PATH` / durable).
- **`apt-get install`:** works and is fine for "right now", but lands in the
  container layer and is **not durable**. Use sparingly; prefer the routes
  above. `handbrake-cli` is not preinstalled but can be added this way (or as
  a static build in `~/.local/bin`) for transcoding/Jellyfin-style workflows —
  `ffmpeg` is already in the image.

You are root; `apt-get` never prompts. Outbound network works for installs.

## Installed tooling (auto-generated at boot)

<!-- BEGIN:installed-tools -->
Run `mise ls` and `npm ls -g --depth=0` to see currently installed tools.
<!-- END:installed-tools -->

## Browsers

Playwright with Chromium and Firefox is preinstalled
(`PLAYWRIGHT_BROWSERS_PATH=/ms-playwright`) and launches fine as root. Use it
for screenshots and E2E tests. If a project pins a different Playwright
version, run `npx playwright install chromium` inside that project once.

## Python: always a venv, never system pip

The system Python is **locked** (`PIP_REQUIRE_VIRTUALENV=1`) — a bare
`pip install` will refuse. That is deliberate. Use a project-local venv:

    uv venv && uv pip install <pkg>     # fastest, preferred
    python3 -m venv .venv && . .venv/bin/activate && pip install <pkg>

Create the venv inside the project so it persists. Use `uv` for throwaway
tooling (`uv run`, `uvx`).

## You are root

Do not use `sudo` — it is not installed and it is not needed. You are already
UID 0 inside this container. `apt-get install` works directly (it never
prompts).

## Git — HTTPS only, no SSH

An sshd runs inside this container for inbound Remote-SSH, but **outbound** SSH
is not a way out: the host firewall blocks it. Use HTTPS URLs:
`https://github.com/owner/repo.git`, never `git@github.com:...`.

Authentication comes from a GitHub token in `GH_TOKEN` (already wired into
`gh` and into git's credential helper). If `GH_TOKEN` is unset, run
`gh auth login` once — the credential is stored in a persistent volume.

Never commit secrets, tokens, or `.env` files.

## Working alongside other agents

Several agents share this container at once. Be considerate with parallelism:
a single `cargo build`, `make -j`, or `pnpm build` already saturates the box.
Avoid firing off builds in a tight loop, and don't run `-j$(nproc)` builds in
several projects simultaneously.

## Network

Outbound internet works (package installs, API calls). Inbound only arrives on
30000-30099, 3773, 4096, and (when a key is configured) SSH on 22.

**Outbound SSH is blocked at the host firewall.** Do not attempt to reach tcp/22
or tcp/2222 on the LAN or on the host itself — the connection will be refused.
Nothing on this network wants an SSH connection from you. Inbound sshd exists
only so the user's editor can attach; it is not a route to anywhere else.
