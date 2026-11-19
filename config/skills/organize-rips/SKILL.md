---
name: organize-rips
description: Turn a dump of raw ARM/MakeMKV disc rips into a Jellyfin library — identify titles, pick the right per-title treatment, transcode (Intel AV1 when available), audit each output against its source, and report. Use when the user says "organize rips", "sort these rips", "process the rip dump", "get these into Jellyfin", or points at a directory of disc rips and says "figure it out".
---

# Organize rips

Input is a directory of already-ripped MKVs from DVDs and Blu-rays (ARM writes
them; ripping is not your job). Output is a Jellyfin library, plus a report the
user reads when they come back.

The user's standing instruction is "figure it out, don't bother me, tell me when
you're done". So: do not ask which episode is which if you can determine it from
durations and TMDB. Do not ask which encoder to use if you can measure. Do stop
and ask if a whole batch is ambiguous in the same way, or if the only remaining
option is destroying data.

## 0. Invariants

- **Input is read-only.** Never write, move, rename or delete anything under it.
  If a mount is not actually read-only, behave as if it is.
- **Never delete the source** of a transcode, even after it passes.
- **Atomic output.** Encode to `<name>.part.mkv` in the destination directory,
  audit it, then rename. A half-written file must never sit in the library.
- **Resumable.** Every output has a `.job.json` sidecar recording source
  fingerprint, filters, encoder and quality. On a re-run, skip anything whose
  sidecar matches a passing audit.
- **Long batches run in `tmux`**, under `nice -n 10 ionice -c3`, because other
  agents share this box. One encode at a time; a hardware encode session is a
  single engine, not a pool.
- `/tmp` is the same filesystem as the projects share. There is no shadow
  scratch. Work in the output directory.

Check the mounts first, and say so clearly if they are missing rather than
writing into an unexpected place:

```bash
echo "${RIPS_IN:?set RIPS_IN}" "${LIB_TV:?set LIB_TV}" "${LIB_MOVIES:?set LIB_MOVIES}"
mount | grep -F -e "$RIPS_IN" -e "$LIB_TV" -e "$LIB_MOVIES"
```

Reports, audit JSON and quarantine live in `${DISCFORGE_WORK:-$HOME/Projects/discforge-work}`,
never in the library. That directory is durable, Jellyfin cannot see it, and it
survives a container rebuild. Create it if it is missing, and use it for the
whole batch:

```bash
WORK="${DISCFORGE_WORK:-$HOME/Projects/discforge-work}"
mkdir -p "$WORK/build" "$WORK/reports" "$WORK/quarantine"
```

## 1. Survey before touching anything

```bash
find "$RIPS_IN" -name '*.mkv' -printf '%s\t%p\n' | sort -k2
```

Then probe every file and build one table — duration, resolution, codec, fps,
field order, track counts:

```bash
for f in "$RIPS_IN"/*/*.mkv; do discforge probe "$f" --json; done | jq -s '.' > /tmp/dump.json
```

Disc boundaries are usually directories. Within a disc, **duration is the
primary signal**: an episode is 22–50 min, a film is 80–150, a featurette is
5–15, a trailer is 1–3, a menu is <1 min and often silence-plus-stills.

## 2. Identify what the batch actually is

`discforge tmdb` needs a token at `TMDB_TOKEN` or `~/.config/discforge/tmdb_token`.

```bash
discforge tmdb show "Show Name"            # -> id, name, first_air_date
discforge tmdb season --show-id 1234 --number 2   # -> per-episode runtimes
discforge tmdb movie "Film Name" --year 1999
```

Match titles to episodes **by runtime first, disc order second, filename last**.
MakeMKV names are meaningless (`title_t03.mkv`), so do not read meaning into them.

- **"Play all" titles** have a duration close to the *sum* of the individual
  episodes on the disc. Drop them; they are duplicates.
- **Films on TV discs**, "bonus disc" content, and season-finale double-length
  episodes are real and will confuse runtime matching. Cross-check against
  TMDB episode count before deciding.
- **Extras** are the remainder: anything under ~60% of the median episode
  runtime. Route them to the extras mechanism in step 6, never into a season as
  a fake episode.
- If filenames from ARM already carry `SxxExx`, trust that only after checking
  it agrees with the disc's episode runtimes.

When a title is genuinely ambiguous, look at it instead of guessing:

```bash
mid=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$f" | awk '{printf "%d", $1/3}')
ffmpeg -v error -ss "$mid" -i "$f" -frames:v 12 -vf "scale=320:-2,tile=4x3" -f image2 /tmp/sheet-%02d.png
magick montage /tmp/sheet-*.png -tile 4x3 -geometry +2+2 /tmp/contact.png
```

Report the contact sheet path rather than describing guesses.

## 3. Classify the source — this decides the filter chain

```bash
discforge classify "$f"        # samples 3 windows, runs idet
```

| verdict | action | meaning |
|---|---|---|
| `progressive` | `none` | already clean; filter nothing |
| `telecined` | `ivtc` | film stored with 3:2 pulldown; recover 23.976 |
| `interlaced-video` | `deinterlace` | true interlaced video (sport, news, some extras) |
| `mixed` | inspect | hybrid or badly flagged; look at frames |

For a title that is mostly film but has genuinely interlaced sections, use
`--action ivtc_hybrid`: field match, then deinterlace the frames still flagged,
then decimate. Do not stack `ivtc` and `deinterlace` by hand.

**Known limitation:** that middle step only touches frames the bitstream flags as
interlaced, so on a disc whose flags lie it degrades to plain `ivtc`. If the
audit still reports combing after `ivtc_hybrid`, re-encode with
`--action deinterlace` (which processes every frame) and accept the slight
softening. The audit is what catches this; do not eyeball it once and move on.

Rules that matter more than the verdict:

- **Never IVTC 25 fps content.** PAL film in an interlaced container is 25p
  split across fields, not 3:2 pulldown. IVTC has nothing to remove there and
  will throw away real frames. Use `deinterlace`, or `none` if it weaves
  cleanly. (The audit derives its expected frame count from the fps ratio for
  exactly this reason: 29.97→23.976 is 0.8×, PAL is 1.0×.)
- **Do not deinterlace 29.97 telecined film.** It keeps the duplicate frames as
  smeared pairs.
- **Do not trust `field_order` metadata** — DVD flags lie. The `idet` numbers
  are the evidence.
- A Blu-ray that is H.264/VC-1, progressive, and already efficient is a
  **remux candidate**: re-encoding it to AV1 may save <25% and cost a
  generation of quality. Decide with numbers, not habit.

## 4. Pick the settings for this title

There is no global profile. Choose per title and record why in the sidecar.

**Encoder**

| situation | encoder | notes |
|---|---|---|
| GPU healthy | `av1_vaapi` | `vainfo --device /dev/dri/renderD128` must list `AV1Profile0` **EncSlice**. Use `--blbrc --10bit` |
| GPU absent/wedged | `svtav1` | `preset 6` for 480p, `4–6` for 1080p. ~15% smaller than VAAPI at equal VMAF, ~3.5× slower |
| Must match an existing library | `x265` | only when compatibility beats efficiency |

**Perceptual QA, and why VMAF is not enough:** VMAF scores 95-97 on encodes
that butteraugli rates "bad". Use both:

```bash
# mean over sampled frames; guidance: 1.0 good, 1.5 acceptable, 2.0 bad
butteraugli ref-dir/ dist-dir/
```

Extract matching frames from both sides with
`-vf "select='not(mod(n\,150))',format=rgb24" -vsync 0 dir/%04d.png`. A
lossless encode (`-c:v libx264 -qp 0`) must read 0.00 - if it does not, the
comparison pipeline is wrong, not the encode.

Banding is the artifact VMAF hides best. Prevention, in order of value: 10-bit
output, `deband` filter, and enough bitrate. Batches on this library showed
hardware 10-bit + `deband` at ICQ 22 as the best perceptual result per byte;
software SVT at CRF 20 was 35% smaller but butteraugli 3.1 (grain smoothed
away), which is a visible change. AV1 film-grain synthesis did not help here
in testing.

**Hardware notes learned the hard way:**

- VAAPI AV1 has **no speed or quality preset**. `-preset` is not a thing here;
  ICQ is the only quality knob. `--blbrc` (block-level rate control) is the
  efficiency knob and is worth roughly 25% at identical VMAF — keep it on.
- `--10bit` (`p010le`, profile main) costs ~3% size and buys banding headroom,
  which VMAF does not measure but DVD gradients show immediately. On for DVD.
- `av1_qsv` is *not* usable in this image: the oneVPL GPU runtime
  (`libmfx-gen`) is not packaged in Ubuntu 26.04, so MFX session creation fails
  with `-9`. Do not burn time on QSV presets; VAAPI is the supported path.

Check the GPU once per batch, and never retry it in a loop:

```bash
LIBVA_DRIVER_NAME=iHD vainfo --device /dev/dri/renderD128 2>&1 | grep -i 'AV1Profile0.*Enc'
```

If it fails, note it in the report, use `svtav1`, and move on. A wedged card is
the host's problem, not something to debug mid-batch.

**Quality starting points.** The user's standing rule is *quality over size*:
they do not care how long an encode takes, only that the library is AV1, looks
as good as the disc, and carries no interlace, blocking or smeared grain. When
in doubt, spend the bits and take the slower preset.

| source | encoder | quality | measured on a real DVD episode (3-min sample, audio included) |
|---|---|---|---|
| DVD 480p | `av1_vaapi` + `--blbrc --10bit` | ICQ 22 + `deband` | **preferred**: 325 MB / 22 min (2.3x smaller), VMAF 96.6, butteraugli 2.0 |
| DVD 480p | `av1_vaapi` + `--blbrc` | ICQ 24 | 223 MB (3.3x), VMAF 95.4 - smaller, visibly smoothed: only when space matters |
| DVD 480p | `av1_vaapi` + `--blbrc --10bit` | ICQ 18-20 | 470-510 MB (1.4x): only when the user asks for maximum fidelity |
| DVD 480p | `svtav1` | CRF 20 | 31.1 MB, VMAF 96.6, 28 s → best size per bit |
| Blu-ray 1080p | `av1_vaapi` + `--blbrc` | ICQ 22-24 | hardware is in its element here |
| Blu-ray 1080p | `svtav1` preset 4-6 | CRF 22-24 | when the GPU is down or the last few percent matter |
| Anything already efficient | `--remux` | — | no re-encode at all; a lossless copy beats a re-encode |

Pick hardware when the library is large or power matters (roughly 10× less
energy per title: ~8 s of GPU versus ~28 s of all-core CPU). Pick software when
you want the smallest file at equal VMAF. Both pass the same gate, so this is a
cost choice, not a quality one.

A failed gate is cheaper than a bad library entry: re-encode lower before
accepting a marginal score, and only ever *raise* the quality target, never
lower it mid-batch to save time.

**Other choices**

- **Denoise**: `light` only for visibly noisy DVD; never on Blu-ray. Denoising
  raises the metrics and lowers the bitrate while removing real detail — when
  in doubt, leave it off. Grain is part of the film; the user asked for no
  *artifacts*, not for a grain-free picture.
- **Audio**: `--audio copy`, always. **Preserve every audio track, every
  language** — this is a standing instruction, not a size trade-off. Copying
  DTS-HD, TrueHD and dual-language AC3 is the correct outcome; transcoding,
  downmixing or dropping a track requires the user to ask for it explicitly.
- **Subtitles**: `copy`, every track, every language, including DVD VobSub and
  PGS bitmap subtitles. Never prune them to save space. Do not OCR unless
  asked — it is slow, lossy and needs review.
- Verify afterwards that the output has **at least** the source's audio and
  subtitle track counts; the audit checks this and a drop fails the job.
- **Anamorphic DVD**: keep 720×480 and its SAR. Do not upscale, do not stretch.

## 5. Encode

Encode into `$DISCFORGE_WORK/build/`, audit there, and only then move the file
into the library. That keeps `.job.json` and audit JSON out of Jellyfin's view,
and it means a failed encode never has to be cleaned up from a media folder.
Always dry-run first and read the command — that is the whole point of picking
settings per title:

```bash
discforge encode "$f" "$WORK/build/$name.mkv" --action ivtc \
  --encoder svtav1 --preset 4 --quality 23 --dry-run
discforge encode "$f" "$WORK/build/$name.mkv" --action ivtc \
  --encoder svtav1 --preset 4 --quality 23 \
  --sidecar "$WORK/reports/$name.job.json"
```

`--action auto` runs `classify` itself and refuses on `mixed`, which is the right
default for bulk. Pass `--action` explicitly when you already know.

## 6. Audit — the gate, not a report

Nothing enters the library unaudited. The audit compares against the source
*through the same filter chain*, so IVTC'd output is scored against IVTC'd
reference rather than against interlaced frames.

```bash
discforge audit "$src" "$WORK/build/$name.mkv" \
  --job "$WORK/reports/$name.job.json" \
  --vmaf-min 95 --vmaf-p1-min 90 \
  --json "$WORK/reports/$name.audit.json"
```

Suggested thresholds — these are starting points, calibrate on the first disc of
a batch and then keep them:

| check | DVD 480p | Blu-ray 1080p |
|---|---|---|
| VMAF mean | ≥ 95 | ≥ 96 |
| VMAF p1 | ≥ 90 | ≥ 92 |
| XPSNR y (no VMAF build) | ≥ 36 | ≥ 38 |

If a title cannot clear these at a sane bitrate, that is a signal to remux it
or to leave it alone rather than to accept a worse encode.

The audit also asserts frame count (±0.2%, expected from the fps ratio for
IVTC), fps, resolution, sample aspect ratio, audio/subtitle track counts,
duration (±0.75 s), residual interlacing (the output is tiled into contiguous
~15s tiles and every tile is judged on its own: repeated fields fail at ≥ 0.15,
combing fails at ≥ 0.95 in any tile (a fully combed tile reads 1.00), and
0.50–0.95 is reported as a warning to eyeball — idet over-reads detail-heavy
content, so treat that band as "look at it", not "it is broken"; a per-tile max
is used because averaging a combed section into the whole file hides it. Note
the deliberate asymmetry: source classification calls 0.90 interlaced, the audit
needs 0.95 before failing an output, because a wrong re-encode is cheaper than
quarantining a clean one), and no freeze ≥ 2 s
— including a freeze that runs to the end of the file, which is the classic
signature of a stalled encode.

Thresholds have defaults (VMAF 95 / p1 90, XPSNR 36); passing `0` disables a
check. Do not lower them to make a title pass.

The audit decodes the output several times (frame count, freezes, interlace,
VMAF). At 1080p that is minutes per title; that cost is the point, and
`--interlace-chunk-seconds N` only trades tile size for time (below 10s is
clamped) — the final decision should use the default full tile set.

`--remux` copies without re-encoding, so it cannot remove pulldown or combing.
The tool refuses `--remux --action ivtc|deinterlace`, and the audit will
(rightly) fail a remuxed telecined title on repeated fields. Remux is for
content that is already progressive and efficient, nothing else.

**Failure handling:**

| reason | first response |
|---|---|
| VMAF/XPSNR low | re-encode at quality−4 (lower number = better), max 2 attempts |
| still interlaced after filtering | wrong action — re-classify longer, try the other chain, or `ivtc_hybrid` |
| freeze at the end of the file | encoder stalled; re-encode, and check free space |
| freeze that is also in the source | a black hold or fade in the master, not an encode fault: confirm with `discforge audit "$src" "$src"`, then raise `--freeze-seconds` and note it in the report |
| "belongs to a different source" | the sidecar was written for another file; re-encode rather than bypassing the check |
| frame count short/long | encoder dropped or duplicated frames; re-run; check `decimate` |
| fps wrong | IVTC applied to 25 fps, or missing on telecined 29.97 |
| duration short | truncated file; re-encode, check free space |
| tracks dropped | mapping error; do not ship |
| freezes | source stutter or a broken encode; inspect before shipping |

After two failed attempts, move the title to `$DISCFORGE_WORK/quarantine/` with its audit JSON
and list it in the report. Do not silently ship a miss.

## 7. Organize into the library

Move with a rename, never a copy-then-delete across filesystems when `mv` works.

**Television**

```
Show (Year)/
├── Season 01/
│   ├── Show (Year) - S01E01 - Episode Title.mkv
│   ├── extras/                     ← unclassified extras from season 1 discs
│   ├── featurettes/                ← making-ofs
│   ├── trailers/                   ← trailers and promos
│   └── interviews/
├── Season 00/
│   └── Show (Year) - S00E01 - Special Title.mkv
└── extras/                         ← show-wide extras (e.g. a bonus disc)
```

**Movies**

```
Film (Year)/
├── Film (Year).mkv
├── extras/
└── featurettes/
```

**Extras: the rules Jellyfin actually implements** (from its media docs):

- The recognised folder names are `extras`, `featurettes`, `trailers`, `clips`,
  `interviews`, `behind the scenes`, `deleted scenes`, `scenes`, `shorts`,
  `samples`, `other`. Use those spellings; `extras` and `other` are the generic
  catch-alls.
- Extras folders are honoured at **series**, **season** and **movie** level.
  Put a disc's extras on the season whose discs produced them; only use the
  series-level folder for show-wide material (a bonus disc, a reunion special).
- **Never leave extras loose in a Season folder.** Jellyfin parses loose video
  files there as episodes; a 90-second promo becomes S01E05 and shifts nothing
  but looks wrong forever.
- The **filename becomes the extra's title** in the UI. Use a human-readable
  name ("Season 2 - Disc 1 - Gag Reel"), never `B1_t01`.
- The `-featurette`, `-trailer`, `-interview`, `-behindthescenes`, `-deleted`
  suffixes exist for the case where an extra belongs to **one specific
  episode**; then attach it to that episode's filename. For disc extras we
  cannot attribute an item to an episode, so prefer the folder form.
- Bitmap or foreign-language extras are still extras: preserve their tracks.

- Episode titles come from TMDB, sanitised: no `/`, `:`, `?`, `*`; keep the
  apostrophes and dashes.
- Leave a **generic clean name** when TMDB has no episode title: still
  `S01E03`, never `title_t03`.
- Multi-episode files: `S01E01-E02`.
- Fix container metadata so the library is tidy without re-muxing: set the
  language on every track the ripper left as `und`, and pick the default audio /
  subtitle stream deliberately:
  ```bash
  mkvpropedit "$f" \
    --edit track:a1 --set language=eng --set flag-default=1 \
    --edit track:a2 --set language=eng --set flag-default=0 \
    --edit track:s1 --set language=eng --set flag-default=1
  ```

**Sidecars stay out of the library.** Reports and audit JSON go to
a sibling path outside the library — `$LIB_TV/../_discforge-reports/<Show>/<file>.json`
or a dedicated reports directory. Jellyfin must never see a `.json`, a
`.part`, or a `.job.json` in a media folder.

## 8. Finish

The user asked to be told when it is done, not to watch it. Deliver:

1. One report file at `$DISCFORGE_WORK/reports/<batch>-<date>.md`: what landed where,
   episode/extras counts, encoder and quality used per source class, total size
   in/out, wall time, every title that needed a judgement call, every quarantine
   with its reason.
2. A short message: what is ready to watch, what needs their eyes, and the
   reminder to reindex Jellyfin (they do that manually).
3. Nothing left running, no `.part` files, no stray frames or contact sheets in
   the library.

## 9. What this library already taught us (do not rediscover)

Everything below was measured on real discs in this container. Trust it over
intuition, and re-measure only when the content changes class.

### How ARM lays out a disc

```
<Show>/Season NN/<DISC FOLDER>/
├── <DISC NAME>.mkv          ← "play all": duration ≈ sum of the episodes
└── extras/
    ├── D1_t04.mkv … D6_t09.mkv   ← the ACTUAL EPISODES (20-22 min each)
    └── B1_t01.mkv, C1_t03.mkv    ← real extras (10 s - 2 min)
```

- **Do not trust the `extras` folder name.** ARM puts episodes in it. Duration
  decides what a title is.
- The play-all is a duplicate; skip it. It also poisons any duration-based
  heuristic that looks at the disc as a whole.
- Layouts vary: some discs are play-all only, some seasons have odd names
  (`the_BiG_BANG_TH`, `..._177128189101`), bonus discs hold one long file.
  Verify per disc rather than assuming.
- A typical DVD episode here: MPEG-2 720×480 anamorphic (SAR 853:720), AC3
  stereo English plus a second language, six DVD bitmap subtitle tracks, five
  chapters.

### The frame-rate header lies

The container can declare 29.97 while the decoder actually produces 23.98
(soft telecine in the MPEG-2 flags). Measured: seasons 1–2 read 23.98 actual;
season 9 reads 29.98 actual. Both declare 29.97.

- Measure cadence by decoding (`frames / seconds`), never by `avg_frame_rate`.
- `discforge` measures it and adds `-r 24000/1001 -fps_mode cfr` when the header
  disagrees with the frames, and the audit compares measured rates.
- Symptom of getting it wrong: a file that claims 29.97 with 24 fps of frames,
  and a rate check that fails on a perfectly good encode.

### Interlace detection is noisier than it looks

- `idet`'s "Progressive" counter is unreliable; `Undetermined` often dominates
  even on clean content.
- Telecine is identified by **repeated fields** (≥0.15), not by combing counts.
- The combing ratio has a noise floor around 0.8 on detail-heavy material (a
  bit-identical file measured 0.86), so fail at ≥0.95, warn from ≥0.50, and
  judge **per ~15 s tile** — a whole-file average hides a localised defect.
- Calibration test that must pass: audit a file against itself and expect no
  interlace reason.

### Intel hardware, measured at 480p

- VAAPI AV1 has **no speed/quality preset**. `av1_qsv` is unusable here: the
  oneVPL GPU runtime is not packaged in Ubuntu 26.04 and MFX session creation
  fails with `-9`. Do not spend time on QSV.
- `--blbrc` (block-level rate control) buys ~25% at identical VMAF. `--10bit`
  costs ~3% and helps gradients, which VMAF cannot see. Both are on by default.
- The hardware encoder **cannot be transparent for grainy DVD**: butteraugli
  plateaus at ~1.66 even at ICQ 14, where the file is *larger than the source*.
- Software SVT-AV1 goes smaller but smooths grain: preset 6 CRF 20 = 207 MB per
  episode, butteraugli 3.1. Hardware 10-bit ICQ 22 + deband = 325 MB,
  butteraugli 2.0. Source is 660–730 MB.
- Film-grain synthesis (`-svtav1-params film-grain=10`) made butteraugli worse
  (3.6). Do not rely on it without measuring.

### Quality: VMAF is necessary, not sufficient

VMAF rated every variant above 95–97 while butteraugli separated them by a
visible margin. Use both, and keep a control:

- `butteraugli` is installed at `~/.local/bin/butteraugli` (1.0 good, 1.5
  acceptable, 2.0 bad by its own guidance). It lives on the durable `~/.local`
  mount; if it is ever missing, `cargo install butteraugli-cli` restores it in
  about 15 seconds.
- **Control that must read 0.00**: encode a clip losslessly (`-c:v libx264
  -qp 0`) and compare. If it is not ~0, your extraction is wrong, not the encode.
- Extract frames on both sides as `format=rgb24`; 10-bit PNGs inflate the score.
- Sample ~1 frame per 5 s for a whole episode; a 3-minute sample is enough to
  shortlist settings.
- Note what the metric means: butteraugli measures *difference from source*,
  including the removal of the DVD's own MPEG-2 noise. A 2.0 is "different",
  not automatically "artifacts" — confirm banding/blocking by eye on the target
  screen before rejecting an encode.
- `discforge-banding` is a supplementary heuristic for plateau/banding
  structure; it is not a standard metric and never overrides the two above.

### Cost and mechanics

- Encode into `$DISCFORGE_WORK` (NVMe pool), move only finished, audited files
  into `/mnt/handoff` (array, parity-protected). Never leave intermediates,
  `.part` files, sidecars or reports on the array.
- Audit costs several full decodes per title (frame count, freezes, interlace
  tiles, VMAF, butteraugli): budget ~3–5 minutes per 22-minute episode at 480p.
- Encode speed: hardware ≈ 1 min/episode, SVT preset 6 ≈ 3.5 min, preset 4
  ≈ 12 min. Hardware also uses roughly a tenth of the energy.
- Freezes that exist in the master (end-of-episode holds, black frames) are not
  encode faults; the audit compares against the source and only fails new ones.
- Sidecars must travel with the audit (`--job`); the audit refuses a sidecar
  whose source fingerprint does not match, which is the guard against auditing
  against the wrong filter chain.

### If a batch has never been run before

1. Run `discforge probe` and `classify` on one disc; confirm the cadence and
   interlace verdict match the tables above.
2. Encode a 3-minute sample at two settings; score both with VMAF **and**
   butteraugli plus the lossless control.
3. Put the winners in `/mnt/handoff/_review/<show>/` and have the user watch
   before committing to hundreds of episodes. Metrics disagree; eyes decide.
4. Then run the batch with the chosen settings and report per-title results.

## Gotchas

- **Never** write to the input mount, even a thumbnail.
- **Do not parallelise hardware encodes.** VAAPI jobs share one engine; run one
  and audit another.
- **A DVD's 4:3 pillarboxed 16:9** looks like a small picture in a wide frame.
  That is correct — leave it.
- **HDR/UHD Blu-rays** need tone mapping (`zscale`/`tonemap`/`libplacebo` are
  present). Do not feed HDR to an 8-bit SDR encode without it.
- **VMAF needs `ffmpeg-vmaf`**; if it is missing the audit falls back to XPSNR
  and says so. Report that the audit was weaker than intended, do not pretend
  the number means the same thing.
- **Trust the audit over the encoder.** A hardware encode that scores below the
  bar is a failed encode, not a successful fast one.
- **Trust measured cadence over the header.** Soft-telecined DVDs declare 29.97
  and carry 23.98; normalise the output or the metadata lies forever.
- **Never trust ARM's `extras/` folder** to contain extras. It usually holds the
  episodes; classify by runtime.
- **Never average interlace statistics over a whole file**; tile it.
- **Never accept VMAF alone** as proof of visual quality. Run butteraugli and,
  when in doubt, look at the picture.
- **QSV is a dead end in this image**; use VAAPI.
