# You are inside CodeContainer

A single Ubuntu 26.04 container on a home NAS (UnRaid), reached over Tailscale.
T3 Code drives you (OpenCode) headlessly. There is **no GUI and no `localhost`
a human can see** — you show work by binding a port and handing the user a link.

## A question is a question, not a work order

When the user asks a question — "is there a way to…", "what happens if…",
"should we…", "how does X work", "what do you think about…" — **answer it**.
Do not edit files, install anything, or start building the thing under
discussion. A design conversation ends with a recommendation and the open
questions, not a diff.

Only implement when the user asks for it ("do it", "go ahead", "implement
this", "fix it"), or when the message is an unambiguous change request rather
than a question. If it could be either, ask first. "Don't implement yet" means
stop at the answer — it does not mean "implement it quietly and call it a
proposal".

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

`localhost` is meaningless here. This container has its own LAN address, so
**any** free port is reachable — there is no port range to stay inside.

1. Bind `0.0.0.0` — never `127.0.0.1`, which is this container's own loopback
   and 404s for the user — and pick any free port. Most dev servers will pick
   one themselves when asked for port `0`, and print the port they really bound:

       pnpm dev --host 0.0.0.0 --port 0     # then read the port from its output

   If the server insists on a number, take a free one. Empty output here means
   nothing is holding it:

       ss -Hltn 'sport = :5199'

   Don't take 3773 (T3 Code) or 4096 (the optional OpenCode API).

2. Run `preview`. It prints a URL for every listener using `PREVIEW_HOST`
   (this container's own address or name) and flags anything bound to loopback,
   which looks fine in here and 404s for the user.

   Ports are direct — no reverse proxy — so HMR and websockets behave normally.
   Do not build demo links from the T3 Code hostname: it forwards only the app
   port.

## There is no Docker here

No `docker`, no `docker compose`, no DinD, no socket. If a project ships a
`docker-compose.yml`, do **not** try to use it. Run the pieces directly:

- Databases: `postgresql`, `mariadb`, and `redis` are installed as normal
  processes (`service postgresql start`, `redis-server --daemonize yes`), or
  just use SQLite.
- Services: run them as processes, like the databases.

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
  public URL.

Shipping a change to **this** container end to end — verify, commit, push,
build the image, push it, deploy, verify — is the `full-send` skill. The
mechanical half is `ship`; `ship --status` reports whether the last deploy
actually landed. Do not reach for it unless the user asked for a release.

## Starting a new project

A new project gets an icon before its first commit — even a placeholder. The
user finds it by its browser tab and its T3 Code thread, and a missing icon
means every tab looks the same.

- **Browser tab:** put a favicon where the framework expects it —
  `public/favicon.svg` (Vite, Next, SvelteKit), `static/favicon.png`,
  `app/favicon.ico`, or whatever the project already uses — and wire it into
  the head if the framework does not do it for you:
  `<link rel="icon" href="/favicon.svg" type="image/svg+xml">`.
- **T3 thread:** set `iconPath` in the project's `t3.json` to the same asset,
  workspace-relative (e.g. `"iconPath": "public/favicon.svg"`). T3 checks that
  before its built-in icon locations.
- An SVG with a letter or a simple shape in two colours is enough. Do not spend
  time on it, do not fetch anything from the network, and do not block on a
  designer.

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

- Storage is `vfs` (baked into `/etc/containers/storage.conf`, not a choice), so
  plain `buildah bud` works. If a `RUN` step fails on namespaces, retry with
  `--isolation chroot`.
- `docker`, `docker compose` and `podman` are **not** available. Build an image
  instead of using a project's `docker-compose.yml`, or run the services as
  processes.
- Registry credentials persist: `buildah login ghcr.io -u <user>` writes to
  `~/.config/containers/auth.json`, which is on a bind mount.

## Scratch space

`/tmp` is a large **disk-backed** scratch directory (a bind mount from the
host), not the container's own storage. `TMPDIR` already points there. Use it
freely for large intermediate files — build trees, kernel sources, archives.

It is **wiped between sessions**, so never leave anything you need in `/tmp`.
Anything durable goes in the project under `~/Projects`.

## Toolchains

**The generated block at the end of this file is the source of truth** for what
is installed here, at what version, and what is absent. It is rewritten from the
live container whenever the environment changes — so do not probe for tools
yourself, and do not trust an older copy of it.

**Per-project runtimes come from mise.** Pin a version per project with a
`mise.toml` at the project root:

    mise use go@1.24        # writes/updates mise.toml
    mise use rust@stable
    mise install            # installs whatever mise.toml pins

**Commit `mise.toml` / `.tool-versions`.** Pinning the toolchain alongside the
code is the point — don't gitignore them. Anything the block lists as absent
arrives that way, or through the durable rules below.

Prefer project-local dependencies (in the project dir, which persists). Globals
are possible — `~/.local` and `~/go` persist — but keep them rare in a shared
image.

## Durable installs (for you, the agent)

Anything you add at runtime must land in a **persistent** location or it vanishes
on rebuild:

- **Node/JS:** `npm install -g <pkg>` — `NPM_CONFIG_PREFIX` is `~/.local`
  (bind-mounted, already on `PATH`). Project-local deps go in the project dir.
- **Python:** a venv inside the project (`uv venv && uv pip install ...`).
  System pip is **locked** (`PIP_REQUIRE_VIRTUALENV=1`) and refuses bare
  installs — that is deliberate. Use `uv run` / `uvx` for throwaway tooling.
- **Rust/Go/Java/.NET:** `mise use ...` — pins into `/mise` (bind-mounted).
- **Other binaries:** download/extract into `~/.local/bin` or the project dir
  (both durable and on `PATH`).
- **`apt-get install`:** works and is fine for "right now", but lands in the
  container layer and is **not durable**. Prefer the routes above.

You are root: `sudo` is not installed and not needed, and `apt-get` never
prompts.

## Installing packages (supply chain)

`npm install` runs whatever code a package ships in `preinstall` / `install` /
`postinstall` — transitively, as **root**, with `GH_TOKEN` in the environment.
That is the most likely way this container gets compromised; it is far more
likely than a browser CVE and no toolchain version saves you from it.

Lifecycle scripts are **denied by default** here (`ignore-scripts=true` in
`~/.npmrc`). Do not "fix" a missing native binary by turning that off globally.
Escalate narrowly instead:

- One package: `npm rebuild <pkg> --ignore-scripts=false`
- A project that genuinely needs builds: commit `.npmrc` in the project with
  `ignore-scripts=false`, and say why in its README. Project config beats the
  user config, so the blast radius stays in that repo.
- A global CLI: `npm install -g --ignore-scripts=false --allow-scripts=<pkg> <tool>`

`pnpm` (only-built dependencies) and `bun` (`trustedDependencies`) already
refuse dependency scripts unless named — prefer them for new projects. `deno`
never runs them. `yarn` (classic) does not protect you at all.

Prefer `npm ci` against a committed lockfile over `npm install`; `npx <pkg>` and
`pnpm dlx <pkg>` fetch and execute code with no lockfile at all, so use them
only for packages already in the project. Before adding an unfamiliar
dependency, look at how old it is — `npm view <pkg> time.modified`, `npm view
<pkg> time.created` — because a release published hours ago is the classic
account-hijack window. New packages are cheap to add and expensive to remove.

## Installed tooling (generated from live state)

Agents never query this: the block is rendered by `tooling` at boot, and again
within seconds of anything being installed, into every agent rules file.

<!-- BEGIN:installed-tools -->
<!-- END:installed-tools -->

## Browsers

Playwright with Chromium and Firefox is preinstalled
(`PLAYWRIGHT_BROWSERS_PATH=/ms-playwright`). Drive Chromium through the
`chromium` wrapper on `PATH`, not the binary in `/ms-playwright` directly: the
wrapper runs it as the unprivileged `browser` user, which keeps the renderer
sandbox on and means a browser compromise cannot read `GH_TOKEN`, `~/Projects`
or `~/.t3code`. The tradeoff is that it cannot write where root can, so point
screenshots at `/tmp` and copy them into place:

    chromium --headless --screenshot=/tmp/shot.png https://example.com

`CHROMIUM_NO_SANDBOX=1` falls back to `--no-sandbox` when the namespace sandbox
is unavailable. Playwright launched from Node still runs as root — for a page
you do not trust, use the wrapper instead of a Playwright script.

If a project pins a different Playwright version, run
`npx playwright install chromium` inside that project once.

## Git — HTTPS only, no SSH

An sshd runs inside this container for inbound Remote-SSH, but **outbound** SSH
is not a way out: the host firewall blocks it, so tcp/22 and tcp/2222 on the LAN
or on the host will refuse. Use HTTPS URLs:
`https://github.com/owner/repo.git`, never `git@github.com:...`.

Authentication comes from a GitHub token in `GH_TOKEN`, an **environment
variable supplied by compose**. It is not read from a file, from `/secrets`, or
from anywhere else — do not look for one. If `GH_TOKEN` is unset, run
`gh auth login` once — the credential is stored in `~/.config`, which persists.

Never commit secrets, tokens, or `.env` files.

`/secrets` holds **public keys only** (sshd's `authorized_keys`). It is mounted
read-only, and the entrypoint reports anything else it finds there on boot — a
token on a host share is readable by everything that can see the share.

## Working alongside other agents

Several agents share this container at once. Be considerate with parallelism:
a single `cargo build`, `make -j`, or `pnpm build` already saturates the box.
Avoid firing off builds in a tight loop, and don't run `-j$(nproc)` builds in
several projects simultaneously.

## Network

Inbound reaches this container on every port it binds, on the LAN and over
Tailscale; SSH on 22 when a key is configured. Outbound internet works for
installs and APIs. Outbound SSH is blocked — nothing on this network wants an
SSH connection from you, and inbound sshd exists only so the user's editor can
attach.
