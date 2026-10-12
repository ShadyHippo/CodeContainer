# You are inside CodeContainer

A single Ubuntu 26.04 container running on a home NAS (UnRaid), reachable over
Tailscale. T3 Code drives you (OpenCode) headlessly. There is **no GUI and no
`localhost` a human can see** — the only way the user sees your work is through
the published port range below.

## Where things live

- `/workspace` is the **only** host path mounted. It is the user's NAS
  `Projects` share; every project is a subdirectory of it.
- You have no read/write access anywhere else on the host. You are root
  *inside this container*, but the container can only see `/workspace`.
- Never create files at the `/workspace` root — that pollutes the whole share.
  Work inside the project directory you were pointed at.

## Showing the user a running app (most important)

`localhost` is meaningless here. To show something:

1. Bind to `0.0.0.0` on a port in **30000-30099** — the only published range.

       PORT=$(freeport)                  # picks a free port in the range
       pnpm dev --host 0.0.0.0 --port "$PORT"

2. Give the user the URL `http://$PUBLIC_HOST:$PORT`.

Run `preview` to see the host and everything currently listening. Ports 3773
(T3 Code) and 4096 (OpenCode) are taken; never assume 30000 is free.

Ports are mapped directly, so HMR and websockets work normally — there is no
reverse proxy and nothing to configure.

## There is no Docker here

No `docker`, no `docker compose`, no DinD, no socket. If a project ships a
`docker-compose.yml`, do **not** try to use it. Run the pieces directly:

- Databases: `postgresql`, `mariadb`, and `redis` are installed as normal
  processes (`service postgresql start`, `redis-server --daemonize yes`), or
  just use SQLite.
- Services: run them as processes against the port range above.

## Long-running work

Run dev servers and anything long-lived under `tmux` (`tmux new -s work`) or
background it properly. Work that dies with your shell is work the user cannot
see.

## Scratch space

`/tmp` is a large **disk-backed** scratch directory (a bind mount from the
host), not the container's own storage. `TMPDIR` already points there. Use it
freely for large intermediate files — build trees, kernel sources, archives.

It is **wiped between sessions**, so never leave anything you need in `/tmp`.
Anything durable goes in the project under `/workspace`.

## Toolchains

Rust 1.99 · Go 1.27 · Node 24 (pnpm/yarn/bun/deno) · TypeScript · Python 3.14
(pip/uv/venv) · Java 21 + Maven/Gradle · .NET 10 · Ruby · PHP 8.5 + Composer ·
Elixir/Erlang · Lua · C/C++ (gcc 15, clang 21) · CMake/Ninja/Meson · ffmpeg ·
ImageMagick · Graphviz · Pandoc · Typst · TeX Live · PostgreSQL 18 · MariaDB 11 ·
Redis 8 · SQLite.

Language servers are on PATH: rust-analyzer, gopls, typescript-language-server,
pyright, clangd, bash/yaml/json/html/css, tailwind, dockerfile.

Prefer project-local dependencies (in the project dir, which persists). Globals
are possible — `~/.local` and `~/go` persist — but keep them rare in a shared
image.

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

SSH is not installed in this container and cannot be installed. Use HTTPS URLs:
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
30000-30099, 3773 and 4096.

**Outbound SSH is blocked at the host firewall.** Do not attempt to reach tcp/22
or tcp/2222 on the LAN or on the host itself — the connection will be refused.
Nothing on this network wants an SSH connection from you.
