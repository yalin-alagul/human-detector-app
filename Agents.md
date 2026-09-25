# Human Detection Filter — Build Plan

A recall-first pipeline that scans a photo dataset and sorts every image into
`clean/`, `review/`, or `trash/`. Optimized for a **Mac mini M6 with 24 GB
unified memory**. Nothing is hard-deleted mid-run — `trash/` is a move, and you
delete it yourself at the end after spot-checking.

---

## 1. Goal and definitions

- **Goal:** a dataset containing zero human presence.
- **"Human" means:** a face, a full body, or any body part (arm, leg, hand,
  foot, torso) — from the front or the back, at any scale, in any lighting.
- **Output contract:** every input image lands in exactly one folder:
  - `clean/` — no human detected, high confidence
  - `review/` — model was unsure (borderline scores), needs a quick human glance
  - `trash/` — human detected, quarantined (moved, not deleted)

## 2. Hardware: what the M6 + 24 GB unlocks

24 GB unified memory is generous. It means you can run **x-large models at high
input resolution** — and resolution is what catches small/distant figures. A
weaker machine would force you into `yolo11n` at 640 px and you'd miss
background people. You don't have that problem.

## 3. Model stack

### Primary: YOLO11x-seg (Ultralytics), class `person`

The main workhorse. Reasons for the pick:

- Largest, most accurate YOLO11 — best mAP of any detector that still runs
  sanely on Apple Silicon.
- The `-seg` variant produces **instance masks**, not just bounding boxes.
  Masks catch partial bodies (a leg, a torso behind a counter) that box-only
  models sometimes drop.
- Runs on MPS (Apple GPU) out of the box via Ultralytics.

### Secondary: SCRFD face detector (InsightFace)

A dedicated face specialist. Catches tiny distant faces and face-only crops
that the person model can miss at odd angles. Lightweight, runs on CPU via
ONNX Runtime.

### Considered and rejected

- **Grounding DINO** — slower, no real gain for a fixed "person" class.
- **SAM / SAM2** — not a detector, needs prompts; wrong tool for this job.
- **MediaPipe Selfie Segmentation** — fast but noticeably worse masks than
  YOLO11x-seg; redundant once you have instance segmentation.

## 4. Pipeline stages (ordered cheap → expensive)

1. **Normalize the image.** Apply EXIF orientation
   (`ImageOps.exif_transpose`), convert HEIC via `pillow-heif` (Mac photo
   libraries are full of HEIC), skip corrupt files with a logged warning.
2. **Stage 1 — YOLO11x-seg at 1280 px.** 1280 input resolution is the key
   setting: small figures survive downscaling. Confidence threshold **0.25**.
   Any `person` instance → `trash/`.
3. **Stage 2 — SCRFD faces.** Only runs on Stage 1 negatives. Any face with
   confidence ≥ 0.5 → `trash/`.
4. **Stage 3 — Review band.** YOLO confidence 0.10–0.25, or face confidence
   0.3–0.5 → `review/`. These are the "model squinted at it" cases.
5. **Everything else → `clean/`.**
6. **Log every decision** to a CSV manifest: filename, SHA-256 hash, verdict,
   stage, top score. The hash lets you resume interrupted runs and proves what
   happened to each file.

## 5. Thresholds

Starting points — **calibrate on a sample before the full run** (see §7):

| Signal              | trash/      | review/     | clean/      |
|---------------------|-------------|-------------|-------------|
| YOLO person conf    | ≥ 0.25      | 0.10 – 0.25 | < 0.10      |
| SCRFD face conf     | ≥ 0.50      | 0.30 – 0.50 | < 0.30      |

Tune so that **false negatives are zero on the calibration sample** — lower
thresholds until no human slips into `clean/`, even if `trash/` gets noisier.
A noisy trash folder is correct behavior for this task.

## 6. File handling rules

- Move, never delete. `shutil.move` into the output folders.
- Preserve relative paths inside each output folder
  (`vacation/img_01.jpg` → `trash/vacation/img_01.jpg`) — keeps the dataset
  navigable.
- Duplicate files (same SHA-256): process once, apply the verdict to all
  copies, note it in the manifest.
- Very large panoramas (> 4000 px on the long edge): tile into overlapping
  1280 px crops for Stage 1, since a person occupying 1% of an 8K image
  vanishes at resize. Reassemble verdicts per image.

## 7. Calibration protocol (before the full run)

1. Random-sample **300 images**, run the pipeline.
2. Manually check all `trash/` and `review/` verdicts on the sample.
3. Adjust thresholds until zero false negatives on the sample.
4. Lock the thresholds, then run the full dataset.

## 8. Performance tuning

- Batch size 4–8 for YOLO on MPS (start at 4, raise until memory complains).
- SCRFD only runs on negatives, so its cost is minor.
- Use a process pool for image loading/preprocessing so the GPU never idles
  on I/O.
- Checkpoint via the manifest: on restart, skip hashes already processed.
- Rough expectation: comfortably thousands of images per hour on the M6. Time
  the 300-image sample and extrapolate.

## 9. Validation & QA

- Spot-check 100 random `clean/` images. One missed human → thresholds too
  strict → lower and re-run only `clean/`.
- Glance through `review/` — the one manual step, fast because the folder is
  small by design.
- Check the score histogram in the manifest: if `review/` is empty and
  `trash/` is huge, thresholds are too aggressive; if `review/` is enormous,
  they're too lax.

## 10. Final deletion (optional, at the very end)

Only after QA passes: `rm -rf trash/` — or move it to an external drive first
if you're cautious. Keep the manifest as your audit trail.

## 11. Failure modes to expect

- **Statues, mannequins, reflections, posters of people** will land in
  `trash/`. Decide upfront whether those count as "human" for your dataset.
- **MPS hiccups:** if Ultralytics doesn't pick up MPS, force `device="mps"`;
  fall back to CPU rather than debugging for an hour.
- **ONNX Runtime on ARM Mac:** install the plain `onnxruntime` wheel (not
  `onnxruntime-gpu`); SCRFD runs fine on CPU.

## 12. Install

```bash
python3 -m venv humanfilter && source humanfilter/bin/activate
pip install ultralytics pillow-heif tqdm onnxruntime
# SCRFD model file (scrfd_10g_bnkps.onnx) from the InsightFace model zoo
```

## 13. Known limits

No detector is 100%. Expect roughly: out of 1,000 photos containing humans, a
couple dozen edge cases (tiny background figures, heavy occlusion, extreme
blur) may slip through confidently-wrong into `clean/`. The `review/` folder
covers the unsure cases; the spot-check in §9 covers the rest. If "zero
humans" is a legal/privacy hard requirement rather than best-effort, budget a
manual pass over `review/` plus random `clean/` batches.

---

## 14. Implementation status (what actually shipped)

This plan was implemented as a native macOS app, with these deliberate
corrections. See `README.md` for the full guide.

- **Runtime is SwiftUI + CoreML + Vision.** No Python, no PyTorch, no ONNX
  Runtime at runtime. Python is used once, by `Models/export_models.py`, to
  produce `.mlpackage` files, and by `Models/upload_to_hf.py` to put them on
  Hugging Face.
- **Models are not bundled.** The app ships without models (about 3 MB) and
  downloads them from a Hugging Face repo (`<username>/human-detector-models`,
  private by default; username, repository and token in Settings, the token in
  the Keychain) into `Application Support/HumanDetector/Models`. The Dashboard
  and the Models page download, remove, re-download and import them. Every
  model is optional.
- **One installed app.** `make install` / `make run` build Release into
  `/Applications` and delete the build product; build folders are `*.noindex`
  and unregistered from LaunchServices so no second copy shows up.
  `/System/Applications` is read-only (sealed system volume). The app is
  arm64-only.
- **HEIC is handled by ImageIO**, not `pillow-heif`.
- **Faces** default to Vision's built-in detector; SCRFD is available as an
  optional CoreML export.
- **Hardware is detected, not assumed.** There is no "M6"; presets key on RAM
  and cores (`lite` 8 GB, `balanced` 16 GB, `max` 24 GB+). The 16 GB M1 dev
  MacBook Pro auto-selects `balanced` (`yolo26m-seg` @ 960 px); the M6 Mac mini
  (24 GB) selects `max` (`yolo26x-seg` @ 1280 px) and is verified on it. Core
  counts read every perflevel, so the M6's three tiers show as `2S+4P+6E`.
- **Builds need full Xcode.** The Makefile and pre-push hook set
  `DEVELOPER_DIR` to `/Applications/Xcode.app` when `xcode-select` points at
  the Command Line Tools (no XCTest, no `xcodebuild`).
- **Masks are optional.** Presence needs only boxes; `computeMasks` defaults
  off and is enabled for the review UI.
- **Undo exists.** Every move is journalled; `Undo Last Run` restores it.
- **Calibration is a first-class screen.** Raw scores are cached so thresholds
  can be re-tuned with zero extra inference.
- **The CLI is a separate non-sandboxed binary**; the shipped app is sandboxed
  and notarizable. Its only network entitlement is `network.client`, used to
  download models.

### Goal switch

The shipped app adds a **Goal** setting, defaulting to *Keep people* (photos with
a human → `clean/`, photos with nobody → `trash/`). Set it to *Remove people* on
the Dashboard or with `--goal remove` to restore the original
zero-human-presence behaviour from this document.

### Undo / resume correctness

Restoring files with **Undo Last Run** also records them in
`restored.jsonl`; `processedHashes` compares place vs. restore timestamps so a
restored file is scanned again rather than skipped. Journal and run files use a
unique timestamp so two runs in the same second cannot overwrite each other.
`humandetector reset --output <dir>` forgets all prior decisions.
