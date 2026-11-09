---
name: council
description: Run a task through a council of five free-or-nearly-free models that answer independently, grade each other blind, and hill-climb until every judge clears the bar. Use when the user says "ask the council", "council this", "put it past the council", "have the council grade/improve X", or asks for cheap multi-model agreement before committing to an answer.
---

# The council

Five models answer. Five models grade every answer without knowing who wrote
which. The harshest judge rewrites the leader from the collected criticisms, the
council re-grades incumbent vs challenger blind, and the loop repeats until
every judge scores the winner at or above the bar — or the run plateaus.

The point is **cheap redundancy**: the bench is discovered at runtime from models
that are free or effectively too cheap to meter, so a full run costs fractions
of a cent and you can afford to be paranoid.

## When to use it

Use it when a second, third and fourth opinion is worth more than one strong
model: prose and copy, plans and designs, reviews, tricky trade-off decisions,
"is this actually good?", and anything the user wants hardened before it ships.

Do **not** use it:

- when the task needs the repo, tools or a shell — members run in a scratch
  directory with no repo access and are told not to use tools. Do the work
  first, then council the *result*.
- as a substitute for a real review of code that will run.
- when the user asked for one specific model by name.

## Commands

```bash
council roster                    # who is on the bench, and what they cost
council roster --check            # canary each pick and drop dead ones
council run "<task>"              # the full loop (default: 4 rounds, happy at 9/10)
council run "<task>" --dry-run    # bench + budget, no calls
```

Useful flags:

| flag | meaning |
| --- | --- |
| `--rounds N` | round 1 is the cold answer; each extra round is a hill climb (default 4) |
| `--threshold N` | every judge must score the winner at least this (default 9) |
| `--stall N` | stop after N rounds with no improvement (default 2) |
| `--file PATH` | inline a file into the task (repeatable, 200 KB cap each) |
| `--models a,b,c` | override the discovered bench (skips the price ceiling) |
| `--max-cost USD` | estimated spend guard (default $0.50) |
| `--json` | machine-readable summary on stdout |
| `--quiet` | suppress per-round progress on stderr |

`council run` prints the final answer on stdout; progress, scores and the
artifact path go to stderr. Exit codes: **0** unanimous, **3** stopped without
unanimity (artifacts are still written), **1** error.

## What to tell the user

Report the result, not the machinery:

1. the final answer,
2. the score trajectory in one line — e.g. `7.4 → 8.1 → 8.6, worst judge 9/10`,
3. whether the council reached unanimity or plateaued, and the leader's model,
4. the estimated cost and the artifact path.

Do not paste the whole report unless asked; point at `report.md`.

## How the bench is chosen

`council roster` intersects what this container can actually call
(`opencode models`, which follows auth) with the advertised prices on
models.dev. It keeps models that are free or at/below `--ceiling` blended
$/Mtok, prefers free, and takes **one per family** so five judges are five
different opinions rather than five checkpoints of one model. The pick is cached
for 12 hours in `~/.config/council/roster.json`.

**Two fixed rules override the ranking:**

- **Always on the bench:** `opencode-go/glm-5.3-flash`,
  `opencode-go/deepseek-v4.1-flash` and `opencode-go/mimo-v2.6-flash`, whenever
  they are callable — even above the price ceiling.
- **Never on the bench:** any model whose id or family contains
  `contributor` (the free `*-contributor*` and `muse-spark-*-contributor`
  models). This exclusion is absolute.

Override the pinned trio with `COUNCIL_PINNED=provider/model,...` if it ever
needs to change.

Defaults: provider `opencode-go`, ceiling `$0.60` blended, five members.
Override with `--ceiling`, `--count`, `--free-only`, or
`COUNCIL_PROVIDERS=opencode-go,github-copilot`.

If the roster shrinks below three usable models the run refuses to start — a
one- or two-judge "council" is worse than no council. Run `council roster
--check` to find out which models are actually answering.

## Reading the result honestly

- These are cheap models. Their grades are **relative**, not absolute — a 9 from
  this bench does not mean a 9 from a frontier model. Use the council to find
  and fix weaknesses, not to certify quality.
- Unanimity at 9/10 is hard for a weak bench; a plateau at 8/10 with consistent
  criticism is often the honest answer. Say so rather than rounding up.
- The artifact directory keeps every round's answers, grades and scores, so a
  disputed call can be audited: `.council/<timestamp>-<slug>/round-N/`.
- Cost is an **estimate** computed from character counts and list prices, not a
  bill. It is there to prove the run was cheap, not to be exact.
