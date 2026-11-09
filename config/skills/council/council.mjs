#!/usr/bin/env node
// council — a self-grading model council that hill-climbs toward unanimity.
//
// Deliberately cheap by construction: every member and judge is a model whose
// advertised price is free or under a blended $/Mtok ceiling, so a full run
// costs fractions of a cent. Members answer independently, grade each other's
// answers (anonymised, self-scores excluded), and the harshest critic rewrites
// the incumbent until every judge clears the bar or the run plateaus.
//
//   council roster [--json] [--refresh] [--check] [--count N] [--ceiling USD]
//   council run "<task>" [--file f]... [--rounds N] [--threshold N]
//                        [--models a,b,c] [--out DIR] [--max-cost USD]
//
// No dependencies. Every model call is `opencode run --format json`.

import { spawn } from "node:child_process";
import * as fs from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

const PRICING_URL = "https://models.dev/api.json";
const MAX_FILE_BYTES = 200 * 1024;

const num = (v, d) => {
  const n = Number(v);
  return Number.isFinite(n) ? n : d;
};
const nowSec = () => Math.floor(Date.now() / 1000);
const log = (...a) => process.stderr.write(a.join(" ") + "\n");

const CONFIG = {
  providers: (process.env.COUNCIL_PROVIDERS || "opencode-go")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
  ceiling: num(process.env.COUNCIL_CEILING, 0.6),
  count: num(process.env.COUNCIL_COUNT, 5),
  threshold: num(process.env.COUNCIL_THRESHOLD, 9),
  rounds: num(process.env.COUNCIL_ROUNDS, 4),
  stall: num(process.env.COUNCIL_STALL, 2),
  timeout: num(process.env.COUNCIL_TIMEOUT, 180),
  parallel: num(process.env.COUNCIL_PARALLEL, 5),
  maxCost: num(process.env.COUNCIL_MAX_COST, 0.5),
  rosterTtl: num(process.env.COUNCIL_ROSTER_TTL, 12 * 3600),
  stateDir: path.join(homedir(), ".config", "council"),
};

// The bench the user always wants, and the one exclusion that is absolute.
// Pinned models are included whenever they are callable, even above the
// ceiling; contributor models are never selected.
const PINNED = (
  process.env.COUNCIL_PINNED ||
  "opencode-go/glm-5.3-flash,opencode-go/deepseek-v4.1-flash,opencode-go/mimo-v2.6-flash"
)
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
const BANNED = /contributor/i;
const ROSTER_VERSION = 2;

// ---------------------------------------------------------------------------
// argv
// ---------------------------------------------------------------------------

const BOOL = new Set(["json", "refresh", "check", "quiet", "no-answer", "stdin", "dry-run", "free-only", "help"]);

function parseArgs(argv) {
  const flags = {};
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "-h") {
      flags.help = true;
      continue;
    }
    if (a === "-f") {
      const v = argv[++i];
      if (v === undefined) throw new Error("-f needs a path");
      (flags.file ??= []).push(v);
      continue;
    }
    if (!a.startsWith("--")) {
      rest.push(a);
      continue;
    }
    const [rawKey, inline] = a.slice(2).split("=", 2);
    if (BOOL.has(rawKey)) {
      flags[rawKey] = inline === undefined ? true : inline !== "false";
      continue;
    }
    if (inline !== undefined) {
      (flags[rawKey] ??= []).push(inline);
      continue;
    }
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) {
      (flags[rawKey] ??= []).push(true);
    } else {
      (flags[rawKey] ??= []).push(next);
      i++;
    }
  }
  return { flags, rest };
}

const one = (v) => (Array.isArray(v) ? v[v.length - 1] : v);
const many = (v) => (v === undefined ? [] : Array.isArray(v) ? v : [v]);

// ---------------------------------------------------------------------------
// model calls
// ---------------------------------------------------------------------------

class Meter {
  constructor(limit) {
    this.limit = limit;
    this.usd = 0;
    this.calls = 0;
  }
  add(price, promptChars, answerChars) {
    const tokens = (promptChars + answerChars) / 4;
    this.usd += (((price.input || 0) + (price.output || 0)) / 2 / 1e6) * tokens;
    this.calls++;
  }
  over() {
    return this.usd > this.limit;
  }
}

const meter = new Meter(CONFIG.maxCost);

// Every model call runs here, not in the user's project: the council is text
// only, so a member that ignores "do not use tools" still cannot touch a repo.
let WORKDIR = process.cwd();

function runOpencode(model, prompt, { timeout = CONFIG.timeout } = {}) {
  return new Promise((resolve) => {
    const started = Date.now();
    const child = spawn("opencode", ["run", "--model", model, "--format", "json", prompt], {
      cwd: WORKDIR,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, OPENCODE_DISABLE_TELEMETRY: "1" },
    });
    let out = "";
    let err = "";
    let killed = false;
    const timer = setTimeout(() => {
      killed = true;
      child.kill("SIGKILL");
    }, timeout * 1000);

    child.stdout.on("data", (b) => (out += b.toString()));
    child.stderr.on("data", (b) => (err += b.toString()));
    child.on("error", (e) => {
      clearTimeout(timer);
      resolve({ ok: false, text: "", ms: Date.now() - started, error: String(e) });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      const parts = [];
      for (const line of out.split("\n")) {
        const s = line.trim();
        if (!s.startsWith("{")) continue;
        try {
          const ev = JSON.parse(s);
          if (ev.type === "text" && ev.part?.type === "text" && ev.part.text) parts.push(ev.part.text);
        } catch {
          /* partial line from a killed process */
        }
      }
      const text = parts.join("").trim();
      const ok = code === 0 && text.length > 0;
      resolve({
        ok,
        text,
        ms: Date.now() - started,
        error: ok
          ? null
          : killed
            ? `timed out after ${timeout}s`
            : `exit ${code}${err ? ": " + err.trim().split("\n").slice(-2).join(" ") : ""}`,
      });
    });
  });
}

async function call(model, prompt, price, opts = {}) {
  if (meter.over()) throw new Error(`cost guard: ~$${meter.usd.toFixed(4)} spent, over --max-cost $${meter.limit}`);
  let last = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    last = await runOpencode(model, prompt, opts);
    if (last.ok) break;
    if (attempt === 0) await new Promise((r) => setTimeout(r, 2000));
  }
  if (last.ok) meter.add(price, prompt.length, last.text.length);
  return last;
}

async function pool(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i], i);
    }
  });
  await Promise.all(workers);
  return results;
}

// ---------------------------------------------------------------------------
// roster: availability ∩ models.dev pricing
// ---------------------------------------------------------------------------

async function listAvailable() {
  return new Promise((resolve, reject) => {
    const child = spawn("opencode", ["models"], { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    child.stdout.on("data", (b) => (out += b.toString()));
    child.stderr.on("data", (b) => (err += b.toString()));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) return reject(new Error(`opencode models failed: ${err.trim()}`));
      const ids = out
        .split("\n")
        .map((l) => l.trim())
        .filter((l) => /^[A-Za-z0-9._-]+\/[A-Za-z0-9._#:-]+$/.test(l));
      resolve([...new Set(ids)]);
    });
  });
}

async function pricing({ refresh = false } = {}) {
  const file = path.join(CONFIG.stateDir, "pricing.json");
  let stale = null;
  try {
    const st = await fs.stat(file);
    stale = JSON.parse(await fs.readFile(file, "utf8"));
    if (!refresh && nowSec() - st.mtimeMs / 1000 < 24 * 3600) return stale;
  } catch {
    /* no cache */
  }
  try {
    const res = await fetch(PRICING_URL, { signal: AbortSignal.timeout(30000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    await fs.mkdir(CONFIG.stateDir, { recursive: true });
    await fs.writeFile(file, JSON.stringify(data));
    return data;
  } catch (e) {
    if (stale) {
      log(`council: pricing refresh failed (${e.message}); using the cached copy`);
      return stale;
    }
    throw new Error(`cannot read model pricing from ${PRICING_URL}: ${e.message}`);
  }
}

const catalogueEntry = (data, id) => {
  const i = id.indexOf("/");
  return data?.[id.slice(0, i)]?.models?.[id.slice(i + 1)] || null;
};

function describe(id, entry) {
  const c = entry?.cost || {};
  const input = Number(c.input ?? 0);
  const output = Number(c.output ?? 0);
  return {
    id,
    name: entry?.name || id,
    family: entry?.family || id.split("/")[1].split(/[-.]/)[0],
    provider: id.split("/")[0],
    input,
    output,
    blended: (input + output) / 2,
    context: entry?.limit?.context || 0,
    released: entry?.release_date || "",
    toolCall: entry?.tool_call !== false,
    free: input === 0 && output === 0,
    status: entry?.status || "active",
  };
}

function rank(a, b) {
  if (a.free !== b.free) return a.free ? -1 : 1;
  if (a.blended !== b.blended) return a.blended - b.blended;
  if (a.context !== b.context) return b.context - a.context;
  if (a.released !== b.released) return a.released < b.released ? 1 : -1;
  return a.id.localeCompare(b.id);
}

function pick(models, count) {
  const chosen = [];
  const seen = new Set();
  for (const m of models) {
    if (chosen.length >= count) break;
    if (seen.has(m.family)) continue;
    chosen.push(m);
    seen.add(m.family);
  }
  for (const m of models) {
    if (chosen.length >= count) break;
    if (!chosen.includes(m)) chosen.push(m);
  }
  return chosen;
}

function extractJson(text) {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    return JSON.parse(text.slice(start, end + 1));
  } catch {
    return null;
  }
}

async function canary(m) {
  const r = await call(m.id, 'Reply with exactly this JSON and nothing else: {"ok":true}', {
    input: m.input,
    output: m.output,
  }, { timeout: 60 });
  return r.ok && extractJson(r.text)?.ok === true;
}

async function buildRoster({ refresh = false, ceiling = CONFIG.ceiling, count = CONFIG.count, providers = CONFIG.providers, check = false, freeOnly = false } = {}) {
  const available = await listAvailable();
  const data = await pricing({ refresh });
  const known = new Map();
  const unpriced = [];
  for (const id of available) {
    const entry = catalogueEntry(data, id);
    if (!entry) {
      unpriced.push(id);
      continue;
    }
    const m = describe(id, entry);
    if (!m.toolCall || m.status === "deprecated") continue;
    known.set(id, m);
  }

  // Absolute exclusion: contributor models never join the bench.
  const usable = [...known.values()].filter((m) => !BANNED.test(m.id) && !BANNED.test(m.family));

  // Pinned models are always on the bench when this install can call them,
  // regardless of provider filter, family diversity or the price ceiling.
  const pinned = PINNED.map((id) => known.get(id)).filter(Boolean);
  for (const m of pinned) m.pinned = true;
  const missing = PINNED.filter((id) => !known.has(id));
  if (missing.length) log(`council: pinned model(s) not callable here: ${missing.join(", ")}`);
  for (const m of pinned) {
    if (m.blended > ceiling) log(`council: ${m.id} is pinned but costs more than the $${ceiling}/Mtok ceiling`);
  }

  const scoped = providers.length ? usable.filter((m) => providers.includes(m.provider)) : usable;
  const fill = (scoped.length >= count ? scoped : usable)
    .filter((m) => !pinned.includes(m))
    .filter((m) => (freeOnly ? m.free : m.free || m.blended <= ceiling))
    .sort(rank);

  const selected = [...pinned, ...pick(fill, Math.max(0, count - pinned.length))];

  if (check) {
    const alive = [];
    const ordered = [...selected, ...fill.filter((x) => !selected.includes(x))];
    for (const m of ordered) {
      if (alive.length >= count) break;
      if (await canary(m)) alive.push(m);
      else log(`council: ${m.id} failed its canary${m.pinned ? " (pinned)" : ""}, promoting the next candidate`);
    }
    selected.length = 0;
    selected.push(...alive);
  }

  if (selected.length < 2) {
    throw new Error(
      `only ${selected.length} callable model(s) at or under $${ceiling}/Mtok. Check \`opencode auth list\`, or raise --ceiling.`,
    );
  }
  if (unpriced.length) {
    log(`council: ${unpriced.length} callable model(s) have no pricing entry and were skipped (${unpriced.slice(0, 4).join(", ")}${unpriced.length > 4 ? ", …" : ""})`);
  }
  return selected;
}

async function loadRoster({ refresh = false, count = CONFIG.count, ceiling = CONFIG.ceiling } = {}) {
  const file = path.join(CONFIG.stateDir, "roster.json");
  if (!refresh) {
    try {
      const cached = JSON.parse(await fs.readFile(file, "utf8"));
      if (nowSec() - cached.builtAt < CONFIG.rosterTtl && cached.v === ROSTER_VERSION && cached.models?.length >= 2 && cached.ceiling === ceiling && cached.count === count) {
        return cached.models;
      }
    } catch {
      /* rebuild */
    }
  }
  const models = await buildRoster({ refresh, count, ceiling });
  await fs.mkdir(CONFIG.stateDir, { recursive: true });
  await fs.writeFile(file, JSON.stringify({ builtAt: nowSec(), v: ROSTER_VERSION, pinned: PINNED, ceiling, count, models }, null, 2));
  return models;
}

function printRoster(models) {
  const rows = [
    ["MODEL", "FAMILY", "$IN", "$OUT", "CTX", "WHY"],
    ...models.map((m) => [
      m.id,
      m.family,
      m.free ? "free" : m.input.toFixed(2),
      m.free ? "free" : m.output.toFixed(2),
      m.context ? `${Math.round(m.context / 1000)}k` : "?",
      m.pinned ? "pinned" : m.free ? "currently free" : "under ceiling",
    ]),
  ];
  const width = rows[0].map((_, i) => Math.max(...rows.map((r) => String(r[i] ?? "").length)));
  process.stdout.write(
    rows.map((r) => r.map((c, i) => (i === r.length - 1 ? c : String(c ?? "").padEnd(width[i]))).join("  ")).join("\n") + "\n",
  );
}

// ---------------------------------------------------------------------------
// prompts
// ---------------------------------------------------------------------------

function solverPrompt(task) {
  return `You are one of several independent members of a council.

TASK:
${task}

Answer the task itself, completely and concretely, in markdown. Do not describe what you would do. Do not use tools. Do not ask questions. No preamble, no sign-off.`;
}

function judgePrompt(task, labelled) {
  return `You are a strict, fair judge on a council of independent models.

TASK GIVEN TO THE COUNCIL:
${task}

CANDIDATE ANSWERS (anonymised):
${labelled}

Grade each candidate from 0 to 10 on correctness, completeness and usefulness. 10 means you could ship it with no changes; 6 means useful but clearly incomplete or flawed; 0 means wrong or useless. Be discriminating: do not give everyone the same score.

Return ONLY a JSON object, no prose and no code fence:
{"scores":{"C1":0},"notes":{"C1":"one or two sentences on what would raise this score"}}

Use exactly the labels above. Do not use tools.`;
}

function revisePrompt(task, incumbent, notes) {
  return `You are revising a council answer so that it scores higher.

TASK:
${task}

CURRENT BEST ANSWER:
${incumbent}

CRITICISM FROM THE COUNCIL:
${notes}

Rewrite the answer so that it addresses every point above, keeps what already works, and is complete and self-contained. Return only the revised answer. Do not use tools.`;
}

// ---------------------------------------------------------------------------
// grading
// ---------------------------------------------------------------------------

function shuffle(list) {
  const a = [...list];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

async function collect(prompt, model, price) {
  const first = await call(model, prompt, price);
  let parsed = first.ok ? extractJson(first.text) : null;
  if (!parsed && first.ok) {
    const retry = await call(model, `${prompt}\n\nReturn only the JSON object. No prose.`, price);
    parsed = retry.ok ? extractJson(retry.text) : null;
  }
  if (!parsed || typeof parsed.scores !== "object" || parsed.scores === null) {
    return { model, ok: false, error: first.error || "unparseable grades", scores: {}, notes: {} };
  }
  const scores = {};
  const notes = {};
  for (const [label, raw] of Object.entries(parsed.scores)) {
    const n = Number(raw);
    if (Number.isFinite(n)) scores[label] = Math.max(0, Math.min(10, n));
  }
  for (const [label, note] of Object.entries(parsed.notes || {})) notes[label] = String(note);
  return { model, ok: true, scores, notes, error: null };
}

function aggregate(candidates, judges, threshold) {
  const rows = candidates.map((c) => {
    const byJudge = {};
    for (const j of judges) {
      if (!j.ok || j.model === c.model) continue;
      const s = j.scores[c.label];
      if (Number.isFinite(s)) byJudge[j.model] = s;
    }
    const values = Object.values(byJudge);
    return {
      label: c.label,
      model: c.model,
      text: c.text,
      mean: values.length ? values.reduce((a, b) => a + b, 0) / values.length : 0,
      min: values.length ? Math.min(...values) : 0,
      judges: values.length,
      byJudge,
      happy: values.length >= 2 && Math.min(...values) >= threshold,
    };
  });
  rows.sort((a, b) => b.mean - a.mean || b.min - a.min);
  return rows;
}

async function gradeCandidates(task, candidates, members, threshold, priceOf) {
  const labelled = candidates.map((c) => `### ${c.label}\n${c.text}`).join("\n\n");
  const prompt = judgePrompt(task, labelled);
  const judges = await pool(members, CONFIG.parallel, (m) => collect(prompt, m.id, priceOf(m)));
  return { judges, rows: aggregate(candidates, judges, threshold) };
}

// ---------------------------------------------------------------------------
// commands
// ---------------------------------------------------------------------------

async function cmdRoster(flags) {
  const ceiling = num(one(flags.ceiling), CONFIG.ceiling);
  const count = num(one(flags.count), CONFIG.count);
  const models =
    flags.refresh || flags.check
      ? await buildRoster({ refresh: Boolean(flags.refresh), ceiling, count, check: Boolean(flags.check), freeOnly: Boolean(flags["free-only"]) })
      : await loadRoster({ count, ceiling });
  if (flags.json) {
    process.stdout.write(JSON.stringify(models, null, 2) + "\n");
    return 0;
  }
  printRoster(models);
  log(`\ncouncil: ${models.length} member(s) · ${models.filter((m) => m.pinned).length} pinned · ceiling $${ceiling}/Mtok blended · free first · one per family`);
  return 0;
}

async function cmdRun(rest, flags) {
  let task = rest.join(" ").trim();
  if (!task && (flags.stdin || flags.file)) task = "";
  if (task === "-" || (!task && flags.stdin)) task = (await readStdin()).trim();
  for (const f of many(flags.file)) {
    task += `\n\n--- file: ${f} ---\n${await readFileCapped(f)}`;
  }
  if (!task.trim()) throw new Error("no task: pass it as an argument, pipe it on stdin, or use --file");

  const ceiling = num(one(flags.ceiling), CONFIG.ceiling);
  const count = num(one(flags.count), CONFIG.count);
  const rounds = Math.max(1, Math.floor(num(one(flags.rounds), CONFIG.rounds)));
  const threshold = num(one(flags.threshold), CONFIG.threshold);
  const stallLimit = num(one(flags.stall), CONFIG.stall);
  const maxCost = num(one(flags["max-cost"]), CONFIG.maxCost);
  const timeout = num(one(flags.timeout), CONFIG.timeout);
  meter.limit = maxCost;
  CONFIG.timeout = timeout;

  let members;
  const explicit = one(flags.models);
  if (explicit) {
    const data = await pricing({});
    const wanted = String(explicit)
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    const blocked = wanted.filter((id) => BANNED.test(id));
    if (blocked.length) log(`council: ignoring contributor model(s): ${blocked.join(", ")}`);
    members = wanted
      .filter((id) => !BANNED.test(id))
      .map((id) => describe(id, catalogueEntry(data, id)));
    if (members.length < 2) throw new Error("the council needs at least two non-contributor models");
    log("council: explicit roster — ceiling checks skipped");
  } else {
    members = await loadRoster({ count, ceiling });
  }
  const priceOf = (m) => ({ input: m.input, output: m.output });

  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "").replace("T", "-");
  const slug =
    task.replace(/\s+/g, " ").trim().slice(0, 40).replace(/[^A-Za-z0-9._ -]/g, "").trim().replace(/\s+/g, "-") || "task";

  if (flags["dry-run"]) {
    process.stdout.write(
      `council dry run\n\nbench:\n${members.map((m) => `  - ${m.id}${m.free ? " (free)" : ` ($${m.input}/${m.output} per Mtok)`}`).join("\n")}\n\n` +
        `would run up to ${rounds} round(s), happy at >=${threshold}, budget $${maxCost}\n`,
    );
    return 0;
  }

  const outDir = path.resolve(one(flags.out) || path.join(".council", `${stamp}-${slug}`));
  await fs.mkdir(outDir, { recursive: true });
  WORKDIR = path.join(outDir, "work");
  await fs.mkdir(WORKDIR, { recursive: true });
  await fs.writeFile(path.join(outDir, "task.md"), task + "\n");
  await fs.writeFile(path.join(outDir, "roster.json"), JSON.stringify(members, null, 2));

  log(`council: ${members.length} members · threshold ${threshold}/10 · up to ${rounds} rounds · ceiling $${ceiling}/Mtok`);

  let entries = (
    await pool(members, CONFIG.parallel, async (m, i) => {
      const r = await call(m.id, solverPrompt(task), priceOf(m));
      return { label: `C${i + 1}`, model: m.id, ...r };
    })
  ).filter((c) => c.ok);
  if (entries.length < 2) throw new Error(`only ${entries.length} member(s) answered; try \`council roster --check\``);
  if (entries.length < members.length) log(`council: ${members.length - entries.length} member(s) failed and sit out this run`);

  const history = [];
  let incumbent = null;
  let stalled = 0;
  const started = Date.now();

  for (let round = 1; round <= rounds; round++) {
    const candidates = incumbent ? [incumbent] : entries;
    const { judges, rows } = await gradeCandidates(task, candidates, members, threshold, priceOf);
    const best = rows[0];
    const winner = candidates.find((c) => c.label === best.label);

    history.push({
      round,
      candidates: rows,
      winner: { label: best.label, model: best.model, mean: best.mean, min: best.min, happy: best.happy, byJudge: best.byJudge },
      judges: judges.map((j) => ({ model: j.model, ok: j.ok, error: j.error })),
    });
    await writeRound(outDir, round, candidates, judges, rows);

    if (!flags.quiet) {
      log("");
      log(`round ${round}:`);
      for (const r of rows) log(`  ${r.label}  ${r.model.padEnd(34)} mean ${r.mean.toFixed(1)}  min ${r.min.toFixed(1)}  (${r.judges} judges)`);
      log(`  => ${best.model} — ${best.happy ? "unanimous" : "not unanimous"}`);
    }

    incumbent = { label: "C1", model: best.model, text: winner.text, mean: best.mean, min: best.min, byJudge: best.byJudge, happy: best.happy };
    if (best.happy) break;
    if (round === rounds) break;

    const critic = Object.entries(best.byJudge).sort((a, b) => a[1] - b[1])[0]?.[0] || members.find((m) => m.id !== best.model)?.id;
    const criticMember = members.find((m) => m.id === critic) || members[0];
    const notes = Object.entries(best.byJudge)
      .sort((a, b) => a[1] - b[1])
      .map(([judge, score]) => `- (${score}/10, ${judge}) ${judges.find((j) => j.model === judge)?.notes?.[best.label] || "no note given"}`)
      .join("\n");

    const revised = await call(critic, revisePrompt(task, winner.text, notes), priceOf(criticMember));
    if (!revised.ok) {
      log(`  revision by ${critic} failed (${revised.error})`);
      stalled++;
      if (stalled >= stallLimit) break;
      continue;
    }

    const pair = shuffle([
      { role: "incumbent", ...incumbent },
      { role: "challenger", model: critic, text: revised.text },
    ]).map((c, i) => ({ ...c, label: `C${i + 1}` }));
    const { rows: duelRows, judges: duelJudges } = await gradeCandidates(task, pair, members, threshold, priceOf);
    const role = Object.fromEntries(pair.map((p) => [p.label, p.role]));
    const challengerRow = duelRows.find((r) => role[r.label] === "challenger");
    const incumbentRow = duelRows.find((r) => role[r.label] === "incumbent");

    await fs.writeFile(
      path.join(outDir, `round-${round}-duel.json`),
      JSON.stringify({ critic, notes, pair: duelRows, accepted: null }, null, 2),
    );

    const accepted =
      Boolean(challengerRow && incumbentRow) &&
      (challengerRow.mean > incumbentRow.mean + 0.05 || (challengerRow.mean >= incumbentRow.mean && challengerRow.min > incumbentRow.min));

    if (accepted) {
      log(`  challenger ${critic}: ${challengerRow.mean.toFixed(1)} (min ${challengerRow.min.toFixed(1)}) vs incumbent ${incumbentRow.mean.toFixed(1)} (min ${incumbentRow.min.toFixed(1)}) — accepted`);
      incumbent = { label: "C1", model: critic, text: revised.text, mean: challengerRow.mean, min: challengerRow.min, byJudge: challengerRow.byJudge, happy: challengerRow.happy };
      stalled = 0;
      if (challengerRow.happy) {
        history.push({
          round: round + 1,
          candidates: duelRows,
          winner: { label: "C1", model: critic, mean: challengerRow.mean, min: challengerRow.min, happy: true, byJudge: challengerRow.byJudge },
          judges: duelJudges.map((j) => ({ model: j.model, ok: j.ok, error: j.error })),
        });
        break;
      }
    } else {
      log(`  challenger ${challengerRow ? challengerRow.mean.toFixed(1) : "?"} vs incumbent ${incumbentRow ? incumbentRow.mean.toFixed(1) : "?"} — kept incumbent`);
      stalled++;
      if (stalled >= stallLimit) break;
    }
  }

  const final = history[history.length - 1]?.winner || {};
  await fs.writeFile(path.join(outDir, "final.md"), (incumbent?.text || "") + "\n");
  await fs.writeFile(
    path.join(outDir, "run.json"),
    JSON.stringify(
      {
        task,
        members,
        threshold,
        rounds: history,
        final: incumbent ? { model: incumbent.model, mean: incumbent.mean, min: incumbent.min, happy: Boolean(incumbent.happy) } : null,
        calls: meter.calls,
        estimatedUsd: Number(meter.usd.toFixed(5)),
        ms: Date.now() - started,
      },
      null,
      2,
    ),
  );
  await writeReport(outDir, task, members, history, incumbent, meter, Date.now() - started);

  log("");
  log(`council: ${final.happy ? "unanimous" : "stopped before unanimity"} · ${meter.calls} calls · ~$${meter.usd.toFixed(4)} (estimate) · ${((Date.now() - started) / 1000).toFixed(0)}s`);
  log(`council: ${outDir}`);

  if (flags.json) {
    process.stdout.write(
      JSON.stringify(
        {
          dir: outDir,
          final: incumbent ? { model: incumbent.model, mean: incumbent.mean, min: incumbent.min, happy: Boolean(incumbent.happy) } : null,
          rounds: history.length,
          calls: meter.calls,
          estimatedUsd: Number(meter.usd.toFixed(5)),
        },
        null,
        2,
      ) + "\n",
    );
  } else if (!flags["no-answer"] && incumbent) {
    process.stdout.write(incumbent.text.trimEnd() + "\n");
  }
  return final.happy ? 0 : 3;
}

async function readStdin() {
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  return Buffer.concat(chunks).toString("utf8");
}

async function readFileCapped(file) {
  if (typeof file !== "string") throw new Error("--file needs a path");
  const buf = await fs.readFile(file);
  if (buf.length > MAX_FILE_BYTES) {
    return buf.subarray(0, MAX_FILE_BYTES).toString("utf8") + `\n\n[… truncated at ${MAX_FILE_BYTES} bytes …]`;
  }
  return buf.toString("utf8");
}

// ---------------------------------------------------------------------------
// artifacts
// ---------------------------------------------------------------------------

async function writeRound(dir, round, candidates, judges, rows) {
  const rdir = path.join(dir, `round-${round}`);
  await fs.mkdir(path.join(rdir, "answers"), { recursive: true });
  for (const c of candidates) {
    await fs.writeFile(path.join(rdir, "answers", `${c.model.replace(/\//g, "__")}.md`), c.text + "\n");
  }
  await fs.writeFile(path.join(rdir, "grades.json"), JSON.stringify(judges, null, 2));
  await fs.writeFile(path.join(rdir, "scores.json"), JSON.stringify(rows, null, 2));
}

async function writeReport(dir, task, members, history, incumbent, meter, ms) {
  const lines = [
    "# Council report",
    "",
    `- members: ${members.map((m) => m.id).join(", ")}`,
    `- calls: ${meter.calls} · estimated cost: ~$${meter.usd.toFixed(4)}`,
    `- wall clock: ${(ms / 1000).toFixed(0)}s`,
    `- verdict: **${incumbent?.happy ? "unanimous" : "stopped before unanimity"}**`,
    "",
    "## Task",
    "",
    task,
    "",
    "## Scores",
    "",
    "| round | candidate | model | mean | min | judges |",
    "| --- | --- | --- | --- | --- | --- |",
  ];
  for (const h of history) {
    for (const r of h.candidates) {
      lines.push(`| ${h.round} | ${r.label} | ${r.model} | ${r.mean.toFixed(1)} | ${r.min.toFixed(1)} | ${r.judges} |`);
    }
  }
  lines.push("", "## Final answer", "", incumbent?.text || "", "");
  lines.push("## Final judge scores", "");
  for (const [judge, score] of Object.entries(history[history.length - 1]?.winner?.byJudge || {})) {
    lines.push(`- ${judge}: ${score}/10`);
  }
  await fs.writeFile(path.join(dir, "report.md"), lines.join("\n") + "\n");
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

const HELP = `council — five too-cheap-to-meter models that grade and hill-climb a task

usage:
  council roster [--json] [--refresh] [--check] [--count N] [--ceiling USD] [--free-only]
  council run "<task>" [--file f]... [--rounds N] [--threshold N] [--models a,b,c]
                       [--out DIR] [--max-cost USD] [--stall N] [--quiet] [--json] [--dry-run]

roster
  Intersects the models this install can call (\`opencode models\`) with models.dev
  pricing, keeps the ones that are free or at/below the blended $/Mtok ceiling,
  prefers free, takes one per family, and caches the pick for 12h in
  ~/.config/council/roster.json. The three pinned models (GLM 5.3 Flash,
  DeepSeek V4.1 Flash, MiMo v2.6 Flash) are always included when callable;
  contributor models are never selected.

run
  Round 1: every member answers independently.
  Every round: every member grades every answer (self-scores excluded).
  Not unanimous? The harshest critic rewrites the best answer, and the council
  grades incumbent vs challenger blind, keeping the improvement.
  Stops on unanimity, a plateau, the round limit or the cost guard.
  Artifacts land in .council/<timestamp>-<slug>/ (task, roster, every round's
  answers + grades + scores, final.md, report.md, run.json).

env
  COUNCIL_PROVIDERS   comma list, default "opencode-go"
  COUNCIL_PINNED      comma list; default GLM 5.3 Flash, DeepSeek V4.1 Flash, MiMo v2.6 Flash
  COUNCIL_CEILING     blended $/Mtok ceiling, default 0.6
  COUNCIL_THRESHOLD   unanimity score, default 9
  COUNCIL_ROUNDS      default 4
  COUNCIL_TIMEOUT     seconds per model call, default 180
  COUNCIL_MAX_COST    estimated dollar guard, default 0.5

exit: 0 unanimous · 3 stopped (artifacts still written) · 1 error`;

async function main() {
  const argv = process.argv.slice(2);
  const cmd = argv[0] && !argv[0].startsWith("-") ? argv.shift() : "help";
  const { flags, rest } = parseArgs(argv);

  if (cmd === "help" || flags.help) {
    process.stdout.write(HELP + "\n");
    return 0;
  }
  if (cmd === "roster") return cmdRoster(flags);
  if (cmd === "run") return cmdRun(rest, flags);
  log(`council: unknown command "${cmd}"\n\n${HELP}`);
  return 1;
}

main()
  .then((code) => process.exit(code))
  .catch((e) => {
    log(`council: ${e.message}`);
    process.exit(1);
  });
