---
name: full-send
description: Ship a change end to end in one pass — verify it, commit and push, build and push the container image, deploy it through DockerDeploy, verify the deploy, and settle the thread. Use when the user says "full send", "ship it", "release", "deploy this", or asks for verify-commit-build-deploy without wanting to babysit it.
---

# Full send

The happy path is silent: the user should not have to think about any of it.
Do not narrate each step, do not ask for confirmation between steps, and do not
stop to summarise until the end. If something is genuinely wrong, stop at that
step and report it — a half-shipped change is worse than an unshipped one.

Do not use this skill unless the user asked for a release. "Commit this" means
commit; it does not mean build and deploy.

This skill ships **CodeContainer itself** — the `ship` script builds
`ghcr.io/shadyhippo/codecontainer` and asks DockerDeploy for the
`codecontainer` stack. It is seeded for every agent in every project, so if you
are in some other repo, it does not apply: that project has its own deploy
script, or none. Say so instead of running `ship` there.

## 0. Preconditions

- You are in the project repo, not a scratch directory.
- The change is finished. If you would not defend it in review, stop here.
- `gh auth status` works and `git remote -v` points at the repo you expect.

## 1. Verify the change — do not skip this

Re-read what you are about to ship. Not the summary you wrote earlier: the
actual diff.

```bash
git status --short          # every path accounted for
git diff                    # unstaged
git diff --staged           # staged
git log --oneline -10       # match the message style
```

Check specifically:

- **Secrets.** No tokens, `.env` files, private keys, or `GH_TOKEN` values.
  This container has a live GitHub token in its environment; grep for it.
- **Debug leftovers.** `console.log`, `print(`, `set -x`, commented-out code,
  `TODO`/`FIXME` you added, temporary file paths.
- **Scope.** Nothing unrelated to the request. No drive-by reformatting.
- **Deletions.** Every removed line was meant to go.
- **The claim.** Does the code actually do what the user asked? Re-read the
  requirement, not just the code.

Then run the project's own checks. For shell and image work in this repo:

```bash
bash -n entrypoint.sh bin/* scripts/*.sh
shellcheck entrypoint.sh bin/* scripts/*.sh
```

For a Dockerfile change: the new layer is ordered so it does not invalidate the
expensive layers above it, and nothing secret is baked in.

For a behaviour change: exercise it. Run the function, hit the endpoint, load
the page. Reading the code is not the same as running it.

If you cannot verify it, say so and **do not ship**. "I think this is right" is
a failure report, not a green light.

## 2. Commit and push

One commit, imperative subject, body only if the *why* is not obvious from the
diff.

```bash
git add -A
git commit -m "<what changed and why>"
git push origin HEAD
```

Confirm the push actually landed:

```bash
git rev-parse HEAD
git ls-remote origin "refs/heads/$(git rev-parse --abbrev-ref HEAD)"
```

The two must match. Never `--force`, never `--no-verify`, never push to a
branch you did not intend.

## 3. Build, push and deploy

```bash
ship
```

`ship` refuses to run unless the worktree is clean and HEAD is already on
origin, so step 2 is a real precondition, not a formality. It then:

1. builds `ghcr.io/shadyhippo/codecontainer:<sha>` and `:latest` with
   `buildah`, baking the commit in as `GIT_SHA`;
2. pushes both;
3. writes a pending-deploy marker and schedules
   `POST /run/codecontainer` after 120s.

The delay exists because DockerDeploy recreates **this** container, which kills
the session. Your turn must be over before that happens.

Useful variants: `ship --no-deploy` (build and push only), `ship --dry-run`
(show the plan), `ship --delay N`.

## 4. Verify the deploy

You cannot watch the new container from inside the old one — it is gone. The
verification is deferred by design:

- The marker `~/.config/codecontainer/pending-deploy` records the commit you
  shipped.
- On the next boot the entrypoint compares it with the commit baked into the
  running image and appends `verified sha=…` or `MISMATCH expected=… running=…`
  to `~/.config/codecontainer/deploy.log`.
- `ship --status` prints the last deploy block and exits non-zero on a
  mismatch.

So "success" at this point means: the image was built and pushed, the deploy
request was accepted and scheduled, and the marker is in place. Say exactly
that. Do not claim the new container is running when you cannot see it.

`ship --status` right after shipping will report `deploy pending` — that is the
expected state, not a failure. It only becomes a verdict after the restart.

If the user is still around, `ship --status` after the restart is the follow-up.
If they are not, the log is the record.

## 5. Settle

Only when steps 1–4 all succeeded:

```
t3_thread_organize({ action: "settle" })
```

Settling applies at turn end. If that tool is not available (you are not running
under T3 Code), just end the turn — do not invent a workaround. Then reply with
one or two lines: what shipped, the commit, and that the deploy is scheduled.
No questions, no "let me know if you want anything else".

## When something fails

Stop at the failing step. Do not continue to the next one, and do not retry a
deploy that may already be in flight.

Report:

1. **Which step failed** (verify / commit / push / build / deploy).
2. **The exact command and its error**, trimmed to the useful lines.
3. **What state you left it in** — committed? pushed? image built? deploy
   scheduled or not?
4. **What you would do next**, if it is obvious.

Never report success for a step you did not observe succeeding.
