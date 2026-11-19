---
name: organize-rips
description: Turn raw disc rips (DVD, Blu-ray, 4K UHD) into a Jellyfin library that is smaller and visually lossless — diagnose whatever the source did to its video, fix interlace/frame-rate/geometry/banding problems, transcode to AV1, verify every output against its source, then name and place it. Use when the user says "organize rips", "process these discs", "encode my library", "sort this series", "make these smaller", or points at rip folders and says "figure it out".
---

# Organize rips

The user hands over raw disc rips — anything from pixelated 1980s TV to 4K UHD —
and expects finished, correctly named library entries. Rips are raw: the layout,
the frame rate, the field structure and the container can all be wrong or bizarre.
Working out what was done to a recording is your job, not theirs.

## The quality contract

This is the user's standing definition of "good". Do not re-litigate it per
batch, and do not ask what quality means.

- **The output is AV1.** Not x265, not x264, not "AV1 if the GPU is free".
  If a source cannot be AV1 (rare: exotic pix_fmt), stop and say so rather
  than silently substituting another codec.
- **Output must be smaller than the source.** That is the point of the exercise.
- **Visually lossless or better.** If the source is bad, the output may be
  *better* (denoised, deinterlaced) — but never worse.
- **No banding, blocking, ringing, or smeared grain.** Banding is the one the
  user hates most.
- **No interlace artifacts, ever.** Combing, residual fields, half-rate motion,
  judder from a wrong cadence — all failures.
- **Clean up analogue noise and static** (TV/VHS-era sources) where it is noise
  and not texture. Keep film grain that carries detail.
- **Spend the time.** There is no deadline and no CPU/GPU budget worth
  protecting. Quality is the constraint; size is minimized subject to it.
- **Preserve every audio and subtitle track** — see the standing rule in
  AGENTS.md. Never prune languages, commentary, or bitmap subtitles.
- **Name for Jellyfin and place it where the user's library reads.** See §7.

If two instructions ever conflict, quality wins, then scope (do only what was
asked), then size.

## Scope

- Work on the series/films the user names. If they give a path, use it. If not,
  find it under the rip mount (`$RIPS_IN`) and say which path you picked.
- Never wander into other series "while you're there".
- Large batch and no explicit instruction to just go? Say what you found, how
  many titles, and start. The user wants progress, not a planning meeting.
- Ask (§9) only when a decision would destroy data or when two plausible
  interpretations exist and both are expensive.

## 0. Invariants

- **Input is read-only.** Never write, move, rename or delete under it.
- **Never delete sources**, even after a successful encode.
- Encode into `$DISCFORGE_WORK` (fast pool). Only finished, audited files move
  to the handoff/library (`$LIB_TV`, `$LIB_MOVIES`). No intermediates, `.part`
  files, sidecars or reports on the array — it is parity-protected and small.
- **Atomic output**: encode to a work file, audit it, then move.
- **Resumable**: every output has a `.job.json` sidecar with the source
  fingerprint, filters, encoder and quality. Skip titles whose sidecar shows a
  passing audit.
- Long runs under `tmux`, under `nice -n 10 ionice -c3`. Other agents share the
  box.
- Check the mounts before writing anything:

```bash
echo "${RIPS_IN:?set RIPS_IN}" "${LIB_TV:?}" "${LIB_MOVIES:?}" "${DISCFORGE_WORK:?}"
findmnt -T "$LIB_TV" -no SOURCE,TARGET,FSTYPE,OPTIONS | head -1
```

## 1. Find out what you were given

Nobody guarantees a layout. Rips arrive as per-disc folders, merged seasons,
single files, or a tree of ARM output with its own idea of structure.

```bash
find "$RIPS_IN" -iname '*.mkv' -printf '%s\t%p\n' | sort -k2 | head -50
```

Then probe everything into one table — duration, codec, resolution, declared
fps, field order, tracks:

```bash
for f in ...; do discforge probe "$f" --json; done | jq -s '.' > /tmp/dump.json
```

Interpretation that saves time:

- **Duration is the strongest signal.** ~22 or ~45 min = episode; 80–150 min =
  film; <5 min = extra; ≈2 h with chapters ≈ sum of a disc's episodes = a
  "play all" duplicate.
- A disc's `extras/` (or any oddly named subfolder) is **not** evidence of what
  is inside. Rip tools routinely stash the real episodes there.
- Duplicated content across a disc is common: play-alls, alternate cuts,
  duplicated title sets.
- If a season looks like it is missing episodes, they are probably inside a
  play-all — check chapter counts before assuming loss.

## 2. Diagnose the source

Work through this list per title. Every item is a thing that goes wrong on real
discs; most cost a minute to check and prevent a ruined encode.

**Frame rate and cadence**

- Compare *declared* `avg_frame_rate` with the rate the decoder actually
  produces (`frames / seconds` over a sample). They disagree more often than
  not on DVD-era sources.
- 23.976 frames declared as 29.97 = soft telecine. Normalise the output rate or
  the metadata lies forever.
- 29.97 with ~20% duplicate frames = hard telecine or a 24→30 conversion.
- 25 fps film = PAL speedup (runs ~4% fast) or 25p stored as 25i.
- Variable frame rate (VFR) shows as wildly different frame durations in
  `ffprobe -show_frames`; normalise to CFR at the dominant rate.
- 50i/60i = true interlaced video (sport, news, concerts, some TV).

**Field structure and duplicated frames**

- `discforge classify` → progressive / telecined / interlaced-video / mixed.
- Cross-check with an exact duplicate-frame ratio (`framemd5` over a sample):
  ~20% duplicates means pulldown remains; 0% with high combing means true
  interlacing.
- Hybrid titles exist: film with inserted video, animation with live-action.
  Treat per title, not per series.

**Geometry**

- Anamorphic DVD: keep the pixels and the SAR, never stretch or upscale.
- Letterboxed 4:3 content, pillarboxed 16:9 content: leave the bars, do not
  crop unless asked.
- Odd dimensions or non-standard SAR: fix with `setsar`, not by rescaling.
- Never upscale. The output resolution is the source resolution (minus a crop
  only if the user asked).

**Colour**

- Limited vs full range mismatch causes crushed blacks; check with
  `signalstats` and keep the source's range.
- HDR/HLG/Dolby Vision: keep HDR if the library's clients support it; otherwise
  tone-map with `zscale`/`tonemap`/`libplacebo`. Never silently feed HDR into
  an 8-bit SDR encode.
- 10-bit output is the default for anything with gradients; banding lives in
  8-bit rounding.

**Audio and subtitles**

- Note codecs, channel layouts, languages, commentary tracks, forced flags.
- Keep everything (AGENTS.md). Bitmap subtitles (PGS, VobSub) are preserved by
  copying into MKV.

**Content character** (drives denoise and quality targets)

- Analogue TV noise, static, VHS-era chroma bleed → denoise is wanted.
- Film grain, animation line art, 4:3 sitcoms → protect detail; light touch.
- Already-blocky sources (heavily compressed DVD) → deband/deblock, and do not
  chase "transparency" to a source whose own artifacts you are removing.

## 3. Decide the treatment

Match the diagnosis to an action. These are the only correct pairings; anything
else is guesswork.

| diagnosis | treatment |
|---|---|
| progressive, clean | no video filter; encode as-is |
| 29.97 declaring 23.98 (soft telecine) | pass through at 23.976, `-r 24000/1001 -fps_mode cfr` |
| hard telecine (duplicates present) | `fieldmatch` + `decimate` (IVTC) |
| true interlaced video | `bwdif=deint=all` (flags lie; process every frame) |
| hybrid film/video | `fieldmatch`, then `yadif=deint=interlaced`, then `decimate` |
| PAL 25i film | deinterlace/weave; **never IVTC** — it deletes real frames |
| VFR | normalise to CFR at the dominant rate before encoding |
| anamorphic | keep pixels + SAR; no scaling |
| noisy analogue TV | light denoise (`hqdn3d` or `nlmeans`) before encode, then deband |
| banding-prone gradients | 10-bit output + `deband` |
| already efficient source | compare remux vs encode at the quality bar; remux if the encode cannot win |

Rules that outrank the table:

- **Never IVTC 25 fps**, never deinterlace telecined film, never trust field
  flags, never upscale.
- **Denoise is content-specific.** Remove analogue noise/static; do not turn
  film grain into plastic.
- **Denoise before deband, sharpen never by default.** Sharpening on a soft DVD
  source creates halos, which are artifacts.
- Prefer the *simplest* chain that fixes the diagnosis.

## 4. Work out the best settings for *this* disc

There is no recipe to follow. Every disc gets diagnosed (§2), then its settings
are **derived by measurement**. The tables below are where to start bracketing,
not answers. You are the expert here: decide, record why, and move on. Do not
ask the user to choose a CRF.

That includes quirks: a series is not uniform. Different seasons, studios,
masters and even discs in the same box set are authored differently. If a disc
looks unlike the last one, diagnose it again instead of reusing the setting.

### 4.1 The procedure, for every title

1. **Classify** the source: DVD / Blu-ray / UHD; film or video; clean or noisy;
   animation or live action; SDR or HDR.
2. **Sample** 2–4 minutes from the middle (skip logos, recaps, credits).
3. **Bracket** three or four candidates from the class ladder below, hardware
   first.
4. **Score** each: structural audit, VMAF, butteraugli, and eyeball the worst
   frames at 1:1 and zoomed.
5. **Apply the acceptance rule** for that class (§4.6), not a universal number.
6. **Pick the smallest passing candidate with margin**, and record encoder,
   quality, filters and the reason in the sidecar and the batch report.
7. **Reuse** that setting for titles of the same class from the same
   master/season. **Re-bracket** when the disc changes character.

```bash
# candidates for one class; swap the ladder per §4.2–4.4
for q in 24 22 20; do
  discforge encode "$sample" "$WORK/build/hw-$q.mkv" --action none \
    --encoder av1_vaapi --quality $q --10bit --sidecar "$WORK/reports/hw-$q.job.json"
done
for c in 22 20 18; do
  discforge encode "$sample" "$WORK/build/sw-$c.mkv" --action none \
    --encoder svtav1 --preset 4 --quality $c --sidecar "$WORK/reports/sw-$c.job.json"
done
discforge audit "$sample" "$WORK/build/hw-22.mkv" --job … --json …
butteraugli ref-frames/ out-frames/
```

### 4.2 DVD (480i/480p, MPEG-2)

Expect: soft picture, analogue noise and static, MPEG-2 blocking, banding in
gradients, telecine and lying frame-rate headers, anamorphic 16:9, 4:3
pillarboxing, and extras that are themselves interlaced.

**Ladder (hardware first):**

| candidate | settings |
|---|---|
| A | `av1_vaapi --blbrc --10bit` ICQ 22 |
| B | A + `deband` (gradients/animation), + `--denoise light` if the source is noisy TV |
| C | A at ICQ 20 (when A shows artifacts) |
| D | `svtav1` preset 6 CRF 20, then 18 (when hardware cannot clear the bar) |

**Acceptance:** VMAF ≥ 96 and p1 ≥ 92; no banding visible on a zoomed gradient
frame; no new blocking or ringing; interlace fully resolved. Butteraugli around
1.7–2.0 is **normal for grainy DVD and is not a failure** — the metric is
penalising removal of the source's own noise, which is wanted here. Do not
chase 1.5 on DVD; chase the artifacts instead.

Typical outcome: 2–3.5× smaller. Denoise light for analogue noise, never heavy
denoise on film grain; deband animation and any smooth gradient.

### 4.3 Blu-ray (1080p, H.264/VC-1/MPEG-2)

Expect: already-efficient compression, intentional film grain, 1080i on some TV
releases, DTS-HD MA/TrueHD audio, PGS subtitles. These are much closer to
transparent sources than DVD, so the win is smaller and the bar is stricter.

**Ladder:** hardware `--blbrc --10bit` ICQ 22 → 20; software `svtav1` preset 4–6
CRF 22 → 20. For 1080i, deinterlace properly (`bwdif=deint=all`) before encoding.

**Acceptance:** VMAF ≥ 96, butteraugli ≤ 1.5 typical, grain structure preserved,
no new artifacts. If the source is already efficient and no encode beats a
**remux** at that bar, remux — a copy is the best possible encode.

Typical outcome: 1.5–3× smaller. Do not denoise film; deband only where
gradients band.

### 4.4 UHD 4K (2160p, HEVC, HDR/DV)

Expect: HDR10/HLG/Dolby Vision, 10-bit minimum, and a hardware encoder that is
genuinely strong at this resolution.

**Ladder:** hardware `--blbrc --10bit` ICQ 22–24 keeping HDR metadata; software
`svtav1` preset 4 CRF 20–22 only if needed. Tone-map only when the target
clients cannot play HDR — and say so, because it changes the look.

**Acceptance:** VMAF ≥ 96 in the native pipeline, no banding or crushed
highlights, HDR metadata intact, verified on an HDR-capable client if possible.

Typical outcome: 1.5–2.5× smaller.

### 4.5 Modifiers that override the ladder

- **Analogue noise / static** (VHS-era, bad broadcast masters): denoise light,
  then deband. Never let denoise smear faces or destroy fine texture.
- **Animation / line art**: protect edges. No sharpening, deband gradients,
  quality one step higher than the ladder.
- **Very grainy film**: keep grain; if size matters, denoise *gently* and accept
  a lighter grain rather than plastic skin.
- **Hybrid content**: per-title treatment (§3), never per-series.
- **Already efficient**: remux if no encode wins at the bar.

### 4.6 Encoder constraints (do not rediscover these)

- **Intel VAAPI AV1 is the hardware path** (`vainfo` must list `AV1Profile0` with
  `EncSlice`). Its knobs are `ICQ`, `--blbrc` (~25% at equal quality) and
  `--10bit`; there is **no preset**. B-series prerequisites, verified: kernel
  6.12+, the `xe` driver, and **Resizable BAR** (the VRAM aperture BAR should be
  tens of GiB, not 256 MiB). If ReBAR is off, the media driver can crash the
  encoder.
- **QSV is a dead end here** — tested twice (Intel's 24.04/`i915` runtime, and
  `vpl-gpu-rt` 1.2.17 built from source): both fail with `MFX session: -9` on
  this 26.04/`xe` stack. Same media engine as VAAPI anyway. Do not rebuild for
  it.
- **SVT-AV1 is the software fallback** and the quality-per-bit leader at low
  rates: preset 4–6 at 480p, 4 at 1080p+.
- Published comparisons and measurements agree: hardware AV1 is competitive at
  high bitrates and slips below roughly 2 Mbps; at 480p the Arc has a
  perceptual floor. At 1080p and 4K it is usually excellent.

**Fallback ladder:** hardware at the ladder's quality → hardware one step higher
→ software at matched quality → remux. Record which rung you used and why.

## 5. Encode

```bash
discforge encode "$src" "$WORK/build/$name.mkv" \
  --action ivtc|deinterlace|ivtc_hybrid|none \
  --encoder av1_vaapi|svtav1 --quality N --preset P \
  --vf "…" --sidecar "$WORK/reports/$name.job.json"
```

- Dry-run first and read the command. The filters are the whole job.
- `--action auto` classifies and refuses on ambiguity; pass the action
  explicitly once you have diagnosed the title.
- One hardware encode at a time; the VAAPI engine is shared.
- Watch the first title of a batch end to end before launching hundreds.

## 6. Verify — the part that makes this trustworthy

Structural checks (`discforge audit`) plus a perceptual check, plus eyes.

`discforge audit "$src" "$out" --job … --json …` asserts:

- frame count against the expectation for the treatment chosen (0.8× for 3:2
  IVTC, 1.0× otherwise), ±0.2%;
- measured cadence, not the declared one;
- resolution and SAR unchanged;
- audio and subtitle track counts not reduced;
- duration within 0.75 s;
- no residual interlace (per ~15 s tile; fail at ≥0.95 combed, repeated fields
  ≥0.15);
- no *new* freezes (freezes present in the master are not failures).

Perceptual checks:

- **VMAF** for gross fidelity — necessary but nowhere near sufficient. It rates
  visibly smoothed encodes 95–97.
- **butteraugli** for perceptual similarity (`~/.local/bin/butteraugli`). Its
  generic scale is 1.0 good / 1.5 acceptable / 2.0 bad, but the **class rule in
  §4.2–4.4 governs**, not the generic scale: DVD is expected to land near 1.7–2.0
  because the source's own noise is being removed, while Blu-ray should be ≤1.5
  and UHD checked against its native pipeline. Chasing 1.5 on a DVD is a waste
  of time and a route to undersized, smeared encodes.
- **Control**: a lossless encode (`-c:v libx264 -qp 0`) must score 0.00. If it
  does not, the comparison is wrong.
- Extract frames as `format=rgb24` on both sides; 10-bit PNGs inflate the score.
- Interpret with care: butteraugli measures *difference from source*, including
  the removal of the source's own compression noise. A 2.0 can mean "cleaner",
  not "worse". Confirm banding/blocking by eye before rejecting.
- **Record the decision** for every class you bracket: encoder, quality, filters,
  why the class rule passed, and what the alternative would have cost. That is
  what the batch report shows the user, and it is what makes a later disc quick
  to judge.
- Look at frames from the worst-scoring moments, zoomed. If the user can see it,
  it is a failure regardless of the number.

When a title fails: fix the cause (wrong chain, too low quality, wrong rate),
re-encode, and re-audit. Quarantine after two failures with the audit JSON and
say so in the report. Never ship a miss silently.

## 7. Name and place it for Jellyfin

```
Show (Year)/
├── Season 01/
│   ├── Show (Year) - S01E01 - Episode Title.mkv
│   ├── extras/
│   └── featurettes/
├── Season 00/Show (Year) - S00E01 - Special Title.mkv
└── extras/                                  ← show-wide extras
Film (Year)/Film (Year).mkv
Film (Year)/extras/
```

- Jellyfin reads `SxxEyy` anywhere in the filename; keep the `"Show - S01E01 -
  Title"` shape. Multi-episode files: `S01E01-E02`.
- Use TMDB for show/season/episode naming and runtimes; match by runtime first,
  disc order second, filename last. Rip filenames are not evidence.
- Episode titles: strip `/ : ? * < > | " \` (Jellyfin reserves them).
- **Extras** go in recognised folders — `extras`, `featurettes`, `trailers`,
  `clips`, `interviews`, `behind the scenes`, `deleted scenes`, `scenes`,
  `shorts`, `samples`, `other` — at series, season or movie level. The filename
  becomes the displayed title, so name it for a human. Never leave loose video
  files in a Season folder; Jellyfin parses them as episodes.
- `-featurette` / `-trailer` / `-behindthescenes` suffixes are for an extra that
  belongs to one specific episode; otherwise use a folder.
- Specials/bonus discs → `Season 00`. Films on TV discs stay films.
- Sidecars, reports and `_review/` material live outside the library.

## 8. Finish

- One report: what was processed, settings used per source class, sizes in/out,
  wall time, anything quarantined and why, and anything the user should eyeball.
- Remind them to reindex Jellyfin (they do it manually).
- Leave nothing running, no `.part` files, nothing stray in the library.

## 9. Ask the user only when

- The only options destroy data (delete sources, overwrite a library entry).
- A title is genuinely unidentifiable and the naming decision is costly to undo.
- The source is so damaged that any encode is a judgement call between two
  visible failure modes.
- They asked for something that contradicts the quality contract.

Otherwise: decide, record the decision in the sidecar and report, and keep going.

## Appendix: measured baselines from this NAS

Evidence from real processing, useful as a starting hypothesis — **not** rules.
Formats vary per disc, season and studio; verify with §2 before trusting any of
this.

- ARM output has been seen putting the real episodes inside `extras/`, with a
  play-all at the disc root, and with per-season naming that varies wildly.
- DVD-era TV: 720×480 anamorphic MPEG-2, AC3 stereo plus a second language, six
  DVD bitmap subtitle tracks, ~5 chapters, ~660–730 MB per 22-minute episode.
- Soft-telecined DVDs declared 29.97 while decoding at 23.98; other seasons of
  the same show decoded at 29.97. Measuring per disc was the only way to know.
- Intel VAAPI at 480p: butteraugli plateaued near 1.66 even at ICQ 14 (file
  larger than source). `--blbrc` bought ~25% at equal VMAF; `--10bit` improved
  gradients. SVT preset 6 CRF 20 reached ~3.5× smaller but smoothed grain
  (butteraugli 3.1). AV1 film-grain synthesis scored worse (3.6) in testing.
- Speed on this box at 480p: hardware ≈ 1 min per episode, SVT preset 6 ≈ 3.5
  min, preset 4 ≈ 12 min; hardware uses roughly a tenth of the energy.
- Audit cost: several full decodes per title, ~3–5 min per 22-minute episode.
- VMAF rated every candidate above 95; butteraugli separated them by a visibly
  meaningful margin. Both are required.
