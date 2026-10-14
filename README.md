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
│  │      agents run with cwd = a project under /workspace           │  │
│  │                                                                 │  │
│  │  /workspace ◀─ bind ── /mnt/user/Projects        (rw, durable)  │  │
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
- [Pairing a device](#pairing-a-device)
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
reverse proxy), so HMR and websockets behave normally.

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

**First boot installs OpenCode 2** (`@opencode/cli`) into the `~/.local` bind
mount. It is deliberately *not* baked into the image, so there is exactly one
copy and it can never go stale behind the mount. That needs network on first
boot only; after that it is skipped instantly. Override with `OPENCODE_CHANNEL`.

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
| `/workspace`          | bind, rw | your projects — the **only** host path      |
| `/tmp`                | bind     | big disk scratch, wiped between sessions   |
| `/secrets`            | bind, ro | credential files you drop in               |
| `/root/.config`       | volume   | opencode config, `gh`, global git config   |
| `/root/.local`        | volume   | agent-installed tooling (survives rebuild) |
| `/root/.t3code`       | volume   | T3 Code state                              |
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

- **One host path, read/write:** `/workspace`. Nothing else on the host is
  visible to the agents.
- **No Docker socket, no DinD.** The container cannot create or reach other
  containers. Agents run processes instead.
- **No SSH.** No client, no server, nothing listening on 22, and
  `/etc/apt/preferences.d/99-no-ssh` pins the openssh/dropbear packages to
  priority `-1` so `apt-get install openssh-client` fails.
- **SSH egress blocked at the host.** `scripts/no-ssh-egress.sh` REJECTs
  container → tcp/22 and tcp/2222 in both `DOCKER-USER` (*other* LAN machines)
  and `INPUT` (*the host itself*). Compose cannot express this — egress
  filtering is not a Docker feature.
- **No inbound except the published range.** `no-new-privileges: true`.
- **Git over HTTPS only**, authenticated by `GH_TOKEN` via git's credential
  helper.

**What this does not protect against:** the agents hold your GitHub token and
your OpenCode subscription, and they can read and write everything under
`/workspace`. Being root inside the container is by design (the host is
root-only), and container escape is bounded by the kernel, not by anything here.

### The apt pin is best-effort, not a guarantee

An agent is root inside the container: it can delete the pin file, or `curl` a
static `ssh` binary. Blocking egress at the host (`make egress-apply`) is the
part that actually holds. That rule does not survive an UnRaid reboot unless you
add it to `/boot/config/go`, and it must be re-applied after a
`docker compose down/up` because the bridge subnet can change.

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
| `PROJECTS_DIR`         | the one rw host path (`/workspace`)                  |
| scratch bind           | big disk scratch, kept off Docker storage            |
| `BIND_IP`              | interface to publish on — your Tailscale IP          |
| `PUBLIC_HOST`          | host part of the URLs `preview` prints               |
| `GH_TOKEN`             | GitHub PAT for `gh` and git push over HTTPS          |
| `SCRATCH_WIPE_ON_START`| wipe `/tmp` on start (default `1`)                   |
| `SHM_SIZE`             | shared memory for headless browsers (default `4gb`)  |

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
refuses `/` and `/workspace` by name — so a misconfigured path cannot delete your
projects.

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

Pairing state lives in the `t3-data` volume (`state.sqlite` plus a persistent
server signing key), so paired devices survive restarts, container recreation
and image rebuilds.

**Never run `docker compose down -v`.** That deletes the volumes and every
pairing with them. Plain `down`, `up`, `restart` and `make up` are all safe.

## What's inside

Ubuntu 26.04 LTS. Roughly 5.9 GB unpacked.

| Area        | Included                                                              |
| ----------- | --------------------------------------------------------------------- |
| Agents      | T3 Code; **OpenCode 2 installs on first boot** (see below); Playwright (Chromium + Firefox) |
| Languages   | Node 24 (pnpm/yarn/bun/deno), TypeScript, Python 3.14, Ruby, PHP 8.5, Elixir/Erlang, Lua, C/C++ (gcc 15, clang 21) |
| Via mise    | **Rust and Go** out of the box; any project can pin its own (`mise use java@21`, `.tool-versions`, …) |
| Build tools | make, CMake, Ninja, Meson, autotools, protobuf                        |
| Databases   | PostgreSQL 18, MariaDB 11, Redis 8, SQLite (run as processes)         |
| Docs/media  | Pandoc, Typst, TeX Live, ImageMagick, ffmpeg, Graphviz                |
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
  agent-installed tooling persists in `~/.local`.
- **`AGENTS.md` is seeded only if missing.** A rebuilt image won't refresh it
  once the volume exists — `docker compose exec code rm /root/.config/opencode/AGENTS.md`
  and restart to re-seed.
- **`yq` is the Python/jq wrapper**, not mikefarah's Go build: `yq '.key' file`
  works, `yq e '.'` does not.
- **Ports 30000-30099 must be free** on the host and not inside the Linux
  ephemeral range (32768-60999) — hence the choice.

## License

MIT — see [LICENSE](LICENSE).
