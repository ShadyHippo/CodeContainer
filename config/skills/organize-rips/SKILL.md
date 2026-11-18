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
`--action ivtc_hybrid`: field match, deinterlace only the frames that are still
combed, then decimate. Do not stack `ivtc` and `deinterlace` by hand.

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
| GPU healthy | `av1_vaapi` | `vainfo --device /dev/dri/renderD128` must list AV1 encode. Fast; ICQ rate control |
| GPU absent/wedged | `svtav1` | `preset 4` for 480p (quality first), `4–6` for 1080p. Slower but better per bit at 480p |
| Must match an existing library | `x265` | only when compatibility beats efficiency |

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

| source | encoder | quality | why |
|---|---|---|---|
| DVD 480p | `svtav1` preset 4 | CRF 22-24 | software wins per bit at 480p; hardware AV1 is tuned for 1080p |
| DVD 480p | `av1_vaapi` | ICQ 24 | only if it clears the gate; verify with VMAF, do not assume |
| Blu-ray 1080p | `svtav1` preset 4-6 | CRF 22-24 | best quality per bit when time is free |
| Blu-ray 1080p | `av1_vaapi` | ICQ 22 | hardware sweet spot, much faster |
| Anything already efficient | `--remux` | — | no re-encode at all; a lossless copy beats a re-encode |

A failed gate is cheaper than a bad library entry: re-encode lower before
accepting a marginal score, and only ever *raise* the quality target, never
lower it mid-batch to save time.

**Other choices**

- **Denoise**: `light` only for visibly noisy DVD; never on Blu-ray. Denoising
  raises the metrics and lowers the bitrate while removing real detail — when
  in doubt, leave it off. Grain is part of the film; the user asked for no
  *artifacts*, not for a grain-free picture.
- **Audio**: `--audio copy` unless the user named a client problem. Copying DTS-HD
  and TrueHD is correct; transcoding them silently is not.
- **Subtitles**: `copy`. DVD VobSub and PGS survive into MKV. Do not OCR unless
  asked — it is slow, lossy and needs review.
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
duration (±0.75 s), residual interlacing (sampled across three windows: repeated
fields fail at ≥ 0.15, combing fails at ≥ 0.75, and 0.40–0.75 is reported as a
warning to eyeball), and no freeze ≥ 2 s
— including a freeze that runs to the end of the file, which is the classic
signature of a stalled encode.

Thresholds have defaults (VMAF 95 / p1 90, XPSNR 36); passing `0` disables a
check. Do not lower them to make a title pass.

**Failure handling:**

| reason | first response |
|---|---|
| VMAF/XPSNR low | re-encode at quality−4 (lower number = better), max 2 attempts |
| still interlaced after filtering | wrong action — re-classify longer, try the other chain, or `ivtc_hybrid` |
| freeze at the end of the file | encoder stalled; re-encode, and check free space |
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
Show (Year)/Season 01/Show (Year) - S01E01 - Episode Title.mkv
Show (Year)/Season 00/Show (Year) - S00E01 - Special Title.mkv
Show (Year)/Extras/Featurette Name.mkv
```

**Movies**

```
Film (Year)/Film (Year).mkv
Film (Year)/Extras/Featurette Name.mkv
```

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
