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

## 4. Choose the encoder and the quality point

The user wants the smallest file that clears the bar. That means *targeting
quality*, not picking a CRF and hoping.

**Bracket on a sample, then commit.** Take 2–4 minutes from the middle of a
title, try two or three settings, score each (§6), and pick the smallest that
clears the bar with margin. Then use that setting for the batch.

Encoder selection:

- **Intel VAAPI AV1** when the GPU works (`vainfo` shows `AV1Profile0` with
  `EncSlice`): fastest, lowest energy. VAAPI has **no preset knob** — quality is
  `ICQ` plus `--blbrc` (block-level rate control, worth ~25% at equal quality)
  and `--10bit`. `av1_qsv` is not usable here (no oneVPL runtime); do not chase
  it.
- **SVT-AV1** on CPU when the GPU is unavailable, or when size matters more
  than time. Preset 4–6 at 480p, 4 at 1080p and above.
- **Never encode blindly with the hardware encoder at low resolution.** It has a
  perceptual floor: on grainy 480p DVD it cannot reach transparency at any
  bitrate, and beyond a point the file gets larger than the source. Measure it
  rather than assuming either way; on 1080p/4K it is usually excellent.

Starting points (verify by measurement, do not trust):

| source | encoder | start at |
|---|---|---|
| DVD 480p film | SVT preset 6 / VAAPI ICQ 22 + `--blbrc --10bit` | CRF 20 / ICQ 22 |
| DVD 480p noisy TV | as above + light denoise + deband | one step higher quality |
| Blu-ray 1080p | VAAPI ICQ 22 or SVT preset 4–6 | CRF 22 |
| 4K UHD | VAAPI ICQ 22–24; keep HDR, 10-bit mandatory | measure tone-mapping need |

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
- **butteraugli** for perceptual similarity (`~/.local/bin/butteraugli`;
  1.0 good, 1.5 acceptable, 2.0 bad by its own guidance).
- **Control**: a lossless encode (`-c:v libx264 -qp 0`) must score 0.00. If it
  does not, the comparison is wrong.
- Extract frames as `format=rgb24` on both sides; 10-bit PNGs inflate the score.
- Interpret with care: butteraugli measures *difference from source*, including
  the removal of the source's own compression noise. A 2.0 can mean "cleaner",
  not "worse". Confirm banding/blocking by eye before rejecting.
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
