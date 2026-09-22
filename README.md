# Human Detector

A recall-first macOS app that scans a photo library and sorts every image into
`clean/`, `review/`, or `trash/`. Nothing is ever deleted — `trash/` is a move,
and every run can be undone.

**Choose what you are keeping.** The **Goal** switch on the Dashboard flips the
meaning of the folders:

| Goal | `clean/` | `review/` | `trash/` |
|---|---|---|---|
| **Keep people** (default) | has a human | unsure | no human — delete these |
| **Remove people** | no human | unsure | has a human |

Detection is identical either way; only the verdict mapping changes. Set it in
the GUI, in Settings, or on the CLI with `--goal keep|remove`.

Built native: **SwiftUI + CoreML + Vision**, no Python at runtime. Everything
runs on-device and offline.

---

## Why the stack changed from the original plan

The original `Agents.md` specified a Python pipeline (Ultralytics + PyTorch MPS
+ ONNX Runtime SCRFD). That is a great research stack but it cannot ship inside
a Swift app, so the shipped design replaces it:

| Original plan | Shipped design | Why |
|---|---|---|
| Ultralytics / PyTorch at runtime | CoreML `.mlpackage` + Vision | Native, offline, no Python dependency |
| `pillow-heif` for HEIC | ImageIO (built in) | macOS decodes HEIC and EXIF natively |
| SCRFD via ONNX Runtime | Vision faces by default, SCRFD→CoreML optional | No ONNX Runtime in a Swift app |
| MPS device pinning / batch tuning | `MLComputeUnits.cpuAndNeuralEngine` | ANE is the accelerator on Apple Silicon |
| "Mac mini M6" hardcoded | Hardware auto-detection + presets | M6 does not exist; presets key on RAM/cores |
| `shutil.move`, no undo | Manifest + undo journal | A wrong verdict is reversible in one click |
| "Zero false negatives" | Review band + calibration | No detector is 100%; honesty beats a slogan |

The Python export script is still there, but it runs **once** to produce
`.mlpackage` files. The app never touches Python.

---

## Quick start

### 1. Export the models (once)

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install ultralytics coremltools onnx onnxruntime onnx2torch torch

# Person models (YOLO26 seg, all sizes). Use --family yolo11 for the fallback line.
python Models/export_models.py --family yolo26 --sizes n s m x --task seg

# Optional tiny-face specialist
python Models/export_models.py --scrfd
```

Models land in `Resources/Models/` and are compiled into the app bundle by Xcode
(`.mlpackage` → `.mlmodelc`). Sizes are chosen per model tier:
`n=640, s=960, m=960, x=1280` (override with `--imgsz` or `--imgsz-map`).

> **SCRFD note:** recent coremltools releases removed the ONNX frontend, so the
> SCRFD path routes through `onnx2torch` (ONNX → PyTorch → CoreML) instead.
> `--scrfd` therefore needs `onnx`, `onnx2torch`, and `torch` installed.

### 2. Build the app

```bash
brew install xcodegen        # once
xcodegen generate
open HumanDetector.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project HumanDetector.xcodeproj -scheme HumanDetector -configuration Release build
```

### 3. Or use the headless CLI

```bash
swift build -c release
.build/release/humandetector hardware
.build/release/humandetector scan --input ~/Pictures --output ~/Sorted --preset auto
.build/release/humandetector undo --output ~/Sorted
.build/release/humandetector reset --output ~/Sorted   # forget past decisions
```

### Make targets

```bash
make test     # unit tests via SwiftPM
make xctest   # the same tests through Xcode (⌘U equivalent)
make app      # build the macOS app
make run      # build, refresh build/Human Detector.app, and open it
make models   # export the CoreML models
make icon     # regenerate the app icon / logo assets
```

---

## How a scan works

1. **Normalize** — ImageIO applies EXIF orientation, decodes HEIC/HEIF, and
   corrupt files are skipped with a logged warning.
2. **Stage 1 — YOLO person-segmentation.** Any `person` instance above the
   trash threshold wins immediately. Small/distant figures survive because the
   model runs at up to 1280 px.
3. **Stage 2 — faces.** Only runs when Stage 1 is negative: Vision faces
   (± SCRFD), plus Vision human rectangles and body pose as cheap extra recall.
4. **Stage 3 — review band.** Borderline scores go to `review/` for a glance.
5. **Everything else → `clean/`.**
6. **Manifest** — CSV + JSONL with path, SHA-256, verdict, stage, scores, and
   timing. The undo journal records every move.

Large panoramas (long edge over the threshold) are tiled with overlap so a
figure occupying 1% of an 8K frame does not vanish at resize.

---

## Configuration options

Editable in **Settings**, saved as JSON, and accepted by the CLI.

### Goal
- Keep people (trash empty photos) / Remove people (trash photos with people)

### Input / output
- Input root, output root
- Move vs copy
- Preserve relative paths (`vacation/img.jpg` → `trash/vacation/img.jpg`)
- Collision policy: append `(1)`, append short hash, skip, overwrite
- Supported extensions, skip corrupt files

### Person detector
- Family (`yolo26`, `yolo11`), size (`n/s/m/l/x`), task (`seg`, `detect`)
- Custom `.mlpackage` path
- Inference size (640–1600 px)
- Confidence and IoU thresholds
- Compute units (`cpuOnly`, `cpuAndNeuralEngine`, `cpuAndGPU`, `all`)
- Rasterize masks (off = faster, presence-only)
- Max detections

### Face + extra signals
- Enabled, provider (Vision / SCRFD / both)
- Minimum face size in pixels
- Human-rectangle and body-pose toggles

### Thresholds
- Person → trash, person review floor
- Face → trash, face review floor
- Human-rectangle → trash, body-pose → trash
- Minimum detection area (ignores speckles)

### Panorama
- Enable tiling, long-edge threshold, tile size, overlap

### Performance
- Preset (`auto` / `lite` / `balanced` / `max` / `custom`)
- Concurrency, prefetch depth
- Pause on thermal throttling, minimum free-memory guard

### Behaviour
- Resume (skip processed hashes), deduplicate by SHA-256
- Dry run, quarantine on/off
- CSV / JSONL manifests, per-image sidecar JSON

### Calibration & QA
- Calibration sample size and seed, spot-check size, histogram bins

### Interface
- Thumbnail size, show boxes/masks/heatmap, confirm before moving

---

## Hardware presets and tuning

The app detects RAM and cores and recommends a preset. You can override it.

| Preset | Person model | Input size | Concurrency | Fits |
|---|---|---|---|---|
| Lite | `…n-seg` | 640 | 2 | 8 GB machines |
| Balanced | `…m-seg` | 960 | 4 | 16 GB (this dev Mac: M1, 16 GB) |
| Max | `…x-seg` | 1280 | 6 | 24 GB+ (e.g. a future M6 Mac mini) |
| Custom | your choice | your choice | your choice | — |

**The “best model” default is `yolo26x-seg` at 1280 px on a 24 GB machine.**
Optimizations that make that practical:

1. `cpuAndNeuralEngine` compute units — keeps inference on the ANE and avoids
   the GPU/`MLIR` crash path some macOS hosts hit with `.all`.
2. FP16 exports (required for segment NMS paths anyway); INT8 weights optional.
3. `computeMasks = false` unless you are looking at the review grid — presence
   only needs the box and class.
4. Tiling instead of upscaling for panoramas.
5. One model instance, warmed up once, with inference serialized (the ANE is a
   single unit) while decode and Vision detectors run concurrently.
6. The memory guard refuses to start work below ~1.5 GB free.

On a 16 GB M1, choose **Balanced** for interactive runs and reserve **Max** for
overnight batches.

### Measured throughput (M1, 16 GB, 20 images, ANE)

| Model | Input | Throughput | Per image |
|---|---|---|---|
| `yolo26n-seg` | 640 | ~66 img/s | ~15 ms |
| `yolo26m-seg` | 960 | ~12.5 img/s | ~80 ms |
| `yolo26x-seg` | 1280 | ~3.7 img/s | ~270 ms |

Numbers are end-to-end (decode + inference + move + manifest). The ANE
serializes inference, so concurrency overlaps decoding rather than predictions.
A 24 GB machine with a newer chip should run the `x` model several times
faster; measure with `humandetector scan` before a big batch.

---

## Undo, resume, and "why did it finish in 0.2 s?"

Scans are resumable: each processed file’s SHA-256 is written to
`output/.humandetector/manifest.jsonl`, and a run skips hashes it has already
seen. That means a scan that finds nothing new legitimately finishes in a
fraction of a second.

The important detail is what **Undo Last Run** does: restoring a file also writes
a record to `restored.jsonl`, and resume compares the latest *place* event
against the latest *restore* event. A restored file is therefore scanned again
instead of being skipped forever.

If a scan appears to do nothing:

- the input folder may be empty because a previous **move** run emptied it —
  point the input at the folder that still holds the images, or switch
  **Settings → File handling → Copy**;
- every file may already be processed — press **Re-run all** on the Dashboard
  (or `humandetector reset`), or turn **Resume** off;
- the folder may be a package such as a Photos Library — export originals first.

The Dashboard reports all three cases instead of silently succeeding.

## Calibration

No detector is perfect, so the app makes imprecision visible instead of hiding
it:

1. **Calibrate** runs inference on a random, seeded sample (default 300).
2. Raw scores are cached, so moving a threshold slider re-classifies the sample
   **instantly with no extra inference**.
3. Tune until nothing human appears in `clean/`, then **Apply thresholds**.
4. **Review** shows the `review/` and `trash/` grids. Click any tile for a large
   preview with detection boxes; right-click to reclassify, which rewrites the
   manifest and stays undoable.
5. Spot-check a random batch of `clean/` before deleting anything.

---

## Sandboxing, signing, and distribution

The app is sandboxed (`Sources/HumanDetectorApp/HumanDetector.entitlements`)
with user-selected read/write, app-scoped bookmarks, and **no network
entitlement** — models are bundled, so the app never phones home.

To ship a signed, notarized build:

```bash
xcodebuild -project HumanDetector.xcodeproj -scheme HumanDetector \
  -configuration Release -archivePath build/HumanDetector.xcarchive archive
xcodebuild -exportArchive -archivePath build/HumanDetector.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
xcrun notarytool submit build/export/HumanDetector.app.zip \
  --keychain-profile <profile> --wait
xcrun stapler staple build/export/HumanDetector.app
```

The CLI is a separate, non-sandboxed SPM executable for headless Mac-mini
batches; the sandboxed app is the primary product.

---

## Project layout

```
Sources/
  HumanDetectorCore/         # engine: no UI, fully unit-tested
    Config/                  # AppConfig, presets, hardware detection
    IO/                      # ImageIO loader, SHA-256, manifest, mover, undo
    Detectors/               # CoreML YOLO, Vision faces/signals, SCRFD
    Pipeline/                # tiler, dedup, decision engine, scan, calibrator
    Models/                  # Detection, ManifestEntry
  HumanDetectorApp/          # SwiftUI app (dashboard, run, review, calibrate)
  HumanDetectorCLI/          # headless runner
Models/export_models.py      # one-time CoreML export
Tests/                       # unit tests
```

## Tests

```bash
swift test
```

Covers the decision engine, NMS, tiler coordinate mapping, file mover
collisions, deduplication, preset resolution, and JSON config round-trips.
