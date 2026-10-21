# CodeContainer

A single-container, headless **code factory for AI agents**: Ubuntu 26.04 with
[T3 Code](https://t3.codes) driving [OpenCode](https://opencode.ai), plus a
kitchen-sink toolchain, running on hardware you own and reached over Tailscale.

The point is that agents keep working when your laptop is closed, and that they
can *show you things* even though there is no `localhost` you can see.

```
Laptop / phone
      │  Tailscale
      ▼
┌──────────────────────────── host (UnRaid) ────────────────────────────┐
│  iptables: container → tcp/22 is REJECTED (LAN + host)                │
│                                                                       │
│  ┌───────────────────────── codecontainer ─────────────────────────┐  │
│  │  T3 Code UI (:3773) ──drives──▶ OpenCode CLI                    │  │
│  │                                       └─▶ opencode serve (:4096) │  │
│  │      agents run with cwd = a project under /root/Projects           │  │
│  │                                                                 │  │
│  │  /root/Projects ◀─ bind ── /mnt/user/Projects        (rw, durable)  │  │
│  │  /tmp       ◀─ bind ── /mnt/cache/scratch/…      (wiped)        │  │
│  │  ports 30000-30099 ◀── published ──▶ dev-server previews        │  │
│  └─────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────┘
```

---

## Contents

- [What it is](#what-it-is)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Security model](#security-model)
- [Configuration](#configuration)
- [Operating it](#operating-it)
- [Releasing a container](#releasing-a-container)
- [Pairing a device](#pairing-a-device)
- [VS Code over SSH](#vs-code-over-ssh)
- [What's inside](#whats-inside)
- [Building the image](#building-the-image)
- [Repository layout](#repository-layout)
- [Gotchas](#gotchas)

---

## What it is

Two things worth understanding before deploying:

**T3 Code is not an agent.** It is a *control surface* — a web/desktop/mobile UI
that orchestrates provider CLIs (Codex, Claude, Cursor, Grok, OpenCode). It ships
none of them. Here it drives **OpenCode**, which is the actual agent.

**There is no `localhost` you can see.** The container runs on a remote box, so
"open it in a browser" is meaningless. Agents show you work by binding a port in
**30000-30099**, which are published to the host. Ports are mapped directly (no
reverse proxy), so HMR and websockets behave normally. You reach them at
`http://<PREVIEW_HOST>:<port>` — the host that has the port range open, not the
public T3 hostname.

## Quick start

On the host (this is a Linux/Docker host; UnRaid is the reference environment):

```bash
git clone https://github.com/ShadyHippo/CodeContainer.git /mnt/user/appdata/codecontainer
cd /mnt/user/appdata/codecontainer

cp compose.example.yaml compose.yaml     # compose.yaml is gitignored - see below
$EDITOR compose.yaml                     # set PROJECTS_DIR, scratch path,
                                         # BIND_IP, PUBLIC_HOST, GH_TOKEN

mkdir -p /mnt/cache/scratch/codecontainer   # create BEFORE first up (see Gotchas)
make preflight                              # must pass - checks paths, ports, bind IP
make up                                     # first build takes 15-40 min

make egress-apply                           # block SSH egress (run as root)
docker compose exec code opencode auth login   # first run, once
```

Then pair your devices — see [Pairing a device](#pairing-a-device).

If `make` isn't installed: run `./scripts/preflight.sh`,
`docker compose up -d --build`, and `./scripts/no-ssh-egress.sh apply` directly.

**First boot installs OpenCode 2** (`@opencode/cli`) with npm into the
`~/.local` bind mount — the location T3 Code expects a provider CLI to live in,
and the only kind of install it can update itself. It is deliberately *not*
baked into the image, so there is exactly one copy. After first boot, "Update
now" in T3 Code's **Settings → Providers** is the update path: it runs
`npm install -g --prefix ~/.local`, which survives rebuilds. Override the
first-boot version with `OPENCODE_CHANNEL`.

OpenCode is **not** managed by mise. T3 reports version-manager installs as
"Update available" but cannot update them (mise pins versions in its config,
and `mise install` never bumps a `latest` pin), which leaves a permanent nag
with no button. `rust`/`go` stay on mise because T3 never touches them.

## How it works

**Ports**

| Port(s)       | What                          | Notes                          |
| ------------- | ----------------------------- | ------------------------------ |
| `30000-30099` | app previews                  | the only place dev servers go  |
| `3773`        | T3 Code UI                    | pairing token = password       |
| `4096`        | OpenCode HTTP API             | bonus; T3 uses the CLI         |

Everything else published is bound to `BIND_IP` — **set it to your Tailscale IP**
or nothing is reachable from off-host. It defaults to `127.0.0.1`.

**Storage**

| Container path        | Kind     | Purpose                                    |
| --------------------- | -------- | ------------------------------------------ |
| `/root/Projects`          | bind, rw | your projects — the **only** host path      |
| `/tmp`                | bind     | big disk scratch, wiped between sessions   |
| `/secrets`            | bind, ro | credential files you drop in               |
| `/root/.config`       | volume or bind mount | opencode config, `gh`, global git config |
| `/root/.local`        | volume or bind mount | agent-installed tooling (survives rebuild) |
| `/root/.t3code`       | volume or bind mount | T3 Code state                              |
| `/root/go`, caches    | volume   | go / npm / cargo / pip caches              |

**The "where am I" trick.** Agents have no idea they're in a remote container
with no localhost, no Docker, and a port range. `config/AGENTS.md` is baked into
the image and seeded on startup into every harness's global rules file
(`~/.config/opencode/AGENTS.md`, `~/.codex/AGENTS.md`, `~/.claude/CLAUDE.md`),
so every session starts knowing the terrain. It is seeded only if missing, so
your edits survive.

## Security model

The container is given as little as possible, because the same host holds
irreplaceable data.

- **One host path for your code, read/write:** `/root/Projects`. State and
  cache bind mounts are operational (config, t3code, local, caches, scratch) and
  do not expose any other host data.
- **No Docker socket, no DinD.** The container cannot create, start, stop or
  even see other containers. It *can* build and push images with `buildah`,
  which needs no daemon — so you get image building without handing over
  control of your host's containers (and without the socket, which would be
  equivalent to root on the host).
- **Inbound SSH is key-only, and off until you provide a key.** `openssh-server`
  is installed so VS Code Remote-SSH and T3's SSH environments can reach the
  container. The entrypoint starts sshd only when a public key exists in
  `/secrets/authorized_keys` (or `SSH_AUTHORIZED_KEYS`); passwords and
  keyboard-interactive auth are disabled and root is `prohibit-password`.
  Dropbear stays pinned out.
- **SSH egress blocked at the host.** `scripts/no-ssh-egress.sh` REJECTs
  container → tcp/22 and tcp/2222 in both `DOCKER-USER` (*other* LAN machines)
  and `INPUT` (*the host itself*). Compose cannot express this — egress
  filtering is not a Docker feature. This filters *routed* traffic: an
  ipvlan/macvlan container bypasses it entirely (see [Gotchas](#gotchas)).
- **No inbound except the published range + SSH.** `no-new-privileges: true`.
- **Git over HTTPS only**, authenticated by `GH_TOKEN` via git's credential
  helper.

**What this does not protect against:** the agents hold your GitHub token and
your OpenCode subscription, and they can read and write everything under
`/root/Projects`. Being root inside the container is by design (the host is
root-only), and container escape is bounded by the kernel, not by anything here.

### The apt pin is best-effort, not a guarantee

An agent is root inside the container: it can delete a pin file, install another
SSH server, or `curl` a static `ssh` binary. Blocking egress at the host
(`make egress-apply`) is the part that actually holds. That rule does not survive
an UnRaid reboot unless you add it to `/boot/config/go`, and it must be
re-applied after a `docker compose down/up` because the bridge subnet can
change. It also only sees routed traffic — an ipvlan/macvlan container leaves
through the NIC and skips netfilter, so if you give the container its own LAN IP
you must filter inside the container instead.

## Configuration

**There is no `.env`.** Everything lives in `compose.yaml`, edited in place.

`compose.yaml` is **gitignored on purpose**, because it holds your PAT in
plaintext and your real host paths. The committed template is
`compose.example.yaml`:

```bash
cp compose.example.yaml compose.yaml   # or: make init
```

> **This repository is public. Never commit `compose.yaml`.** `make init` refuses
> to overwrite an existing `compose.yaml`, so pulling a newer template can't
> clobber your token.

Key settings:

| Setting                | Meaning                                              |
| ---------------------- | ---------------------------------------------------- |
| `PROJECTS_DIR`         | the one rw host path (`/root/Projects`)                  |
| scratch bind           | big disk scratch, kept off Docker storage            |
| `BIND_IP`              | interface to publish on — your Tailscale IP          |
| `PUBLIC_HOST`          | host part of pairing links (T3 Code UI, port 3773)   |
| `PREVIEW_HOST`         | host part of demo links, default `un.raid` — must be a name that reaches the host directly, because a public T3 hostname usually proxies only the app port |
| `GH_TOKEN`             | GitHub PAT for `gh` and git push over HTTPS          |
| `SCRATCH_WIPE_ON_START`| wipe `/tmp` on start (default `1`)                   |
| `T3_CHANNEL`           | runtime T3 Code channel override: empty (baked build), `latest` (stable), `nightly`, or a pinned version (e.g. `0.1.0`). Switches without an image rebuild |
| `T3_VERSION`           | build arg for the T3 Code version baked into the image (default `latest` = stable). Set to `nightly` for nightly builds |
| `SHM_SIZE`             | shared memory for headless browsers (default `4gb`)  |
| `ENABLE_SSH`           | start the key-only sshd for Remote-SSH (default `1`; off until a key is present) |
| `SSH_AUTHORIZED_KEYS_FILE` | public keys for sshd, default `/secrets/authorized_keys` |

## Durable installs (agents and you)

The image ships a large toolchain (see [What's inside](#whats-inside)), but anything
an agent adds at runtime has to land in a **bind-mounted, persistent location**
or it vanishes on the next rebuild. The rules:

| Kind of tool | Durable location | How |
| ------------ | ---------------- | --- |
| Node / JS    | `/root/.local` (bind mount) | `npm install -g <pkg>` — `NPM_CONFIG_PREFIX=/root/.local` is set, and `~/.local/bin` is first on `PATH` |
| Python       | project venv or `/root/.local` | `uv venv && uv pip install ...` inside the project (preferred), or `pip install --user` |
| Rust / Go / Java / .NET | `/mise` (bind mount) | `mise use rust@stable`, `mise use java@21`, etc. — pinned per project via `mise.toml` |
| Other binaries (static builds, HandBrake, …) | `/root/.local/bin` or the project dir | download/extract there; it is already on `PATH` |
| apt packages (`apt-get install`) | **not durable** | lands in the container layer; fine for "right now", lost on rebuild. Add to the Dockerfile if you want it permanent |

**So yes — an agent can install HandBrake** (`apt-get install handbrake-cli` for
immediate use, or a static build dropped into `~/.local/bin` to survive rebuilds),
and `ffmpeg` is already in the image. That makes workflows like "watch a folder,
transcode with HandBrake/ffmpeg, rename into a Jellyfin-friendly layout" entirely
feasible: T3 Code orchestrates the agent, the agent drives the CLI tools against
files under `/root/Projects`, and results land on your durable share. Nothing
Jellyfin-specific is preinstalled, but the agent can pull whatever client/API
tooling it needs using the rules above.

Agents are root inside the container, so `apt-get` works directly — but prefer
the durable routes above unless the tool is genuinely a system package.

## Operating it

```bash
make preflight       # validate paths, ports, bind IP before deploying
make up / down       # start / stop
make logs            # follow logs
make shell           # shell into the container
make preview         # list live dev servers as host-reachable URLs
make notes           # print the agent house rules
make egress-apply    # block SSH egress (run as root)
make egress-status   # verify the block
make scratch-sweep   # clear scratch (only when the container is stopped)
```

**Scratch** is cleared two ways: on every container start (so a crashed build's
leftovers never linger), and by `scripts/scratch-sweep.sh`, which only runs while
the container is **stopped** — schedule it with UnRaid's User Scripts plugin.
Wipe-on-stop is deliberately *not* used: the entrypoint `exec`s T3 Code, so traps
never fire, and there is no cleanup on `SIGKILL`/OOM anyway.

The scratch wipe refuses to run unless it is pointed at a real mountpoint, and
refuses `/`, `/root` and `/root/Projects` by name — so a misconfigured path
cannot delete your
projects.

## Releasing a container

The agent container has **no Docker socket**, by design: anything with the
socket can become root on the host, and the agent is the least trustworthy
process on the box — it reads untrusted code, web pages and issue text. A prompt
injected into it must not be one `docker run --privileged` away from your files.

Releases are handed to a sidecar instead: **[DockerDeploy](https://github.com/ShadyHippo/DockerDeploy)**.
It owns the socket, listens only on an internal Docker network, and will run
nothing except the scripts you wrote and dropped in its `scripts/` directory.

```bash
curl -s http://docker-deploy:9000/scripts              # what is callable
curl -s -XPOST http://docker-deploy:9000/run/easyedit  # run one
```

### Why a sidecar instead of a socket

- the socket is root-equivalent; a script allowlist bounds the *capability* to
  "pull and recreate this named stack", which is all a release needs
- nothing new is published: the endpoint is reachable by container name only, so
  it is not exposed to the LAN, the tailnet or the internet
- adding a service is one audited file, not a new permission for the agent
- the agent cannot add or edit scripts — `scripts/` is mounted read-only and the
  server checks ownership, mode and symlinks on every request

### Setup

1. Clone and start DockerDeploy on the host — its README has the commands.
2. Put this container on its network (below).
3. Write `scripts/<name>.sh` for each stack, `chmod 755`, done. No restart.
4. Release with `curl -XPOST http://docker-deploy:9000/run/<name>`.

```yaml
services:
  code:
    networks:
      default: {}
      deploy-net: {}

networks:
  deploy-net:
    external: true
```

A run with no new image is a no-op, because compose compares image IDs and only
recreates what changed. `codecontainer` recreates this container, so it ends the
session that asked for it — call it last.

## Pairing a device

**The container prints a ready-to-use link on every start.** It's in the logs:

```bash
docker compose logs code | sed -n '/PAIRING LINK/,/====$/p'
```

You'll get a `http://<PUBLIC_HOST>:3773/pair#token=...` link **and a QR code**.
Open the link on your laptop, or scan the QR with your phone. No commands.

The token is minted fresh on every boot and is not time-limited — T3 has no
"never" TTL, so it is issued for 10 years. Unused links minted by earlier boots
are revoked automatically, so exactly one valid link exists at a time. Paired
devices are unaffected.

Knobs (all optional): `AUTO_PAIR=0` to disable, `PAIR_TTL=30d` to change the
lifetime, `PAIR_LABEL=name` to change the label.

Mint one on demand instead:

```bash
docker compose exec -T code pair 30d phone      # TTL, label
```

**Do not use the pairing URL that T3 Code prints at startup.** It contains the
container's *internal* address (`http://172.17.0.2:3773`), which nothing on your
network can reach, and its token expires after 5 minutes. The automatic link
above is bound to `PUBLIC_HOST` instead, so both the link and its QR work.

The link is a credential: whoever holds it can operate the agents. Treat it
like a password, and use a short TTL for anything you don't control.

Manage issued tokens from inside the container:

```bash
docker compose exec code t3 auth pairing list
docker compose exec code t3 auth pairing revoke <id>
```

### Phones and HTTPS

The hosted client at `app.t3.codes` is served over HTTPS, and browsers refuse to
let an HTTPS page talk to a plain-HTTP backend. Two options:

- Browse straight to `http://<tailscale-ip>:3773` over the tailnet — works today.
- Terminate TLS on the host, e.g.
  `tailscale serve --bg --https=443 http://<tailscale-ip>:3773`, then use the
  resulting MagicDNS HTTPS URL.

`t3 serve --tailscale-serve` will **not** work here: there is deliberately no
Tailscale inside the container.

### Pairings survive restarts

Pairing state lives in `/root/.t3code` (named volume or bind mount depending on
your compose), so paired devices survive restarts, container recreation and image
rebuilds.

**Never run `docker compose down -v`.** That deletes the volumes and every
pairing with them. Plain `down`, `up`, `restart` and `make up` are all safe.

## VS Code over SSH

"Open in VS Code" in T3 Code builds
`vscode://vscode-remote/ssh-remote+<host><path>` — no port, no path translation.
It works only when the environment itself is SSH-reachable under the host T3
knows, because the path it sends is the container path (`/root/Projects/...`).

**Container side.** Put your public key in `<secrets>/authorized_keys`, start the
container, and the entrypoint starts a key-only sshd on 22. Host keys live in
`/root/.config/ssh`, so rebuilds keep the same fingerprint. Turn it off with
`ENABLE_SSH=0`.

**Reaching it.** Publish `2222:22` (as `compose.example.yaml` does), or give the
container its own LAN IP with ipvlan and use 22 directly. Either way the *name*
must resolve to the container — not to the NAS host, which also has an sshd.

**Laptop.** The alias is what hides the port from T3, because the URI carries
none:

```sshconfig
Host code.un.raid
  HostName code.un.raid     # or the container's LAN IP
  User root
  Port 2222                 # omit with a dedicated ipvlan address
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

Check it before involving T3:

```bash
ssh code.un.raid 'hostname; opencode --version'
```

**T3.** Settings → Connections → Add environment → SSH, host `code.un.raid`.
T3 opens the port forward and the editor handoff then uses that same host.

To keep your existing paired environment instead, add this name as a *route*
(**Add route**): pairing the same machine over another address adds a route
rather than a second machine.

Watch the first connect. T3 "starts or reuses a server" over SSH; this container
already runs one as PID 1, which its docs say is left alone. If you instead end
up with a second environment whose threads are empty, that's the cause, and the
route approach above is the fallback.

VS Code's remote server lives in `~/.vscode-server`, symlinked here to
`/root/.local/vscode-server` so a rebuild doesn't re-download it.

## What's inside

Ubuntu 26.04 LTS. Roughly 5.9 GB unpacked.

| Area        | Included                                                              |
| ----------- | --------------------------------------------------------------------- |
| Agents      | T3 Code (stable by default); **OpenCode 2 installs on first boot** (see below); Playwright (Chromium + Firefox) |
| Remote edit | `openssh-server` for VS Code Remote-SSH and T3 SSH environments — key-only, and it does not start until a public key is present |
| Languages   | Node 24 (pnpm/yarn/bun/deno), TypeScript, Python 3.14, Ruby, PHP 8.5, Elixir/Erlang, Lua, C/C++ (gcc 15, clang 21) |
| Via mise    | **Rust and Go** out of the box; any project can pin its own (`mise use java@21`, `.tool-versions`, …) |
| Build tools | make, CMake, Ninja, Meson, autotools, protobuf                        |
| Databases   | PostgreSQL 18, MariaDB 11, Redis 8, SQLite (run as processes)         |
| Docs/media  | Pandoc, Typst, TeX Live, ImageMagick, ffmpeg, Graphviz                |
| GPU video   | ffmpeg with vaapi/qsv/nvenc + PSNR/SSIM; `mediainfo`, `mkvtoolnix`, `vainfo`. Pass `/dev/dri` for hardware transcode. |
| Build/push  | `buildah` — daemonless image builds and pushes. **No docker socket, ever.** Needs `security_opt: seccomp=unconfined`. |
| LSPs        | rust-analyzer, gopls, typescript-language-server, pyright, clangd, bash/yaml/json/html/css/tailwind/dockerfile |
| CLI         | git + delta, gh, ripgrep, fd, fzf, bat, jq, tmux, lazygit-adjacent tooling, shellcheck, shfmt |

Python is locked to venvs (`PIP_REQUIRE_VIRTUALENV=1`) — a bare `pip install`
fails on purpose. Use `uv venv` or `python3 -m venv`.

## Building the image

```bash
make build                        # locally, on the host (recommended)
docker compose build --build-arg NODE_MAJOR=24
```

Or push to `main`/`master` and let GitHub Actions publish to GHCR.

**Prefer building on the host.** The image is ~7.9 GB unpacked and GitHub's
Actions cache limit is 10 GB per repository, so CI caching for an image this size
is ineffective and the runner can run short on disk. The workflow is there, but
local builds are more reliable.

If you pull from GHCR instead of building, the package is private by default —
`docker login ghcr.io` with a `read:packages` PAT, or make it public.

## Repository layout

```
Dockerfile                 the image (one cleaned apt layer + per-runtime layers)
entrypoint.sh              clears scratch, seeds agent rules, starts the services
compose.example.yaml       committed template  (copy to compose.yaml)
compose.yaml               YOUR config - gitignored, never committed
compose.host.yaml          optional host-networking override
Makefile                   thin wrappers over docker compose + scripts
config/AGENTS.md           the "where you are" rules seeded into every agent
config/gitconfig           system git defaults (identity, HTTPS cred helper)
config/{bashrc,zshrc}      shell setup
bin/preview                list live dev servers as reachable URLs
bin/freeport               pick a free port in the preview range
bin/agent-notes            print the agent rules
scripts/preflight.sh       host checks before deploying
scripts/no-ssh-egress.sh   block container -> tcp/22 (LAN + host)
scripts/scratch-sweep.sh   clear scratch while the container is stopped
.github/workflows/build.yml  build + push to GHCR
```

## Gotchas

- **Missing bind sources are created on the root filesystem.** On UnRaid `/` is a
  **RAM disk**. If the scratch dir doesn't exist, Docker creates it in RAM and a
  40 GB build eats memory instead of disk. `make preflight` fails hard on this —
  run it first.
- **Put scratch on a pool, not the array.** Array writes touch parity on every
  write.
- **`BIND_IP` must exist before the container starts**, or binding fails with
  `cannot assign requested address`. Tailscale coming up after Docker is a real
  risk at boot.
- **Agents install into `~/.local`,** so `npm ls -g` won't show the image's
  globally installed tools. Intentional: image tooling is in `/usr/local`,
  agent-installed tooling persists in `~/.local`. OpenCode itself lives there
  (`~/.local/bin/opencode`) because that is the install shape T3 Code can
  update; `~/.local/bin` is ahead of `/mise/shims` on PATH so a stale shim can
  never shadow it.
- **`AGENTS.md` is seeded only if missing.** A rebuilt image won't refresh it
  once the volume exists — `docker compose exec code rm /root/.config/opencode/AGENTS.md`
  and restart to re-seed.
- **`t3 update` inside the container is temporary.** T3 self-updates with npm
  into `/usr/local`, which is the image layer — the newer build is live until
  the next rebuild and then silently reverts. Prefer rebuilding, or set
  `T3_CHANNEL=latest` (the entrypoint runs `npx -y t3@latest`, slower to boot
  but no rebuild). The same applies to a "Server update available" prompt in
  T3: it works, it just doesn't survive a rebuild.
- **`yq` is the Python/jq wrapper**, not mikefarah's Go build: `yq '.key' file`
  works, `yq e '.'` does not.
- **Ports 30000-30099 must be free** on the host and not inside the Linux
  ephemeral range (32768-60999) — hence the choice.

## License

MIT — see [LICENSE](LICENSE).
