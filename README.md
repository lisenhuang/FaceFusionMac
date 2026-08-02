# Morphiqo

A local-first face-swapping app for macOS, for video and for photos. No Python,
no FFmpeg, no Conda, no Homebrew — install the app, download the models once,
and everything after that runs on your Mac with no network connection.

```
SwiftUI app  ──XPC──▶  FaceFusionEngine.xpc  ──▶  ONNX Runtime  ──▶  Core ML  ──▶  ANE / GPU
   │                        │
   │                        └── models on disk (shared App Group container)
   └── AVFoundation decode / encode  (replaces FFmpeg)
```

## How it is put together

| Piece | Role |
|---|---|
| `FaceFusionMac` | SwiftUI app: media selection, preview, progress, export, model downloads. The only component with network access. |
| `FaceFusionEngine.xpc` | Embedded XPC service. Owns the models and does every inference. **No network entitlement.** |
| `Shared/` | The IPC contract, compiled into both targets. |
| ONNX Runtime 1.24.2 | Statically linked into the engine via Swift Package Manager. Nothing to install. |

### Why a separate process

Model weights are ~560 MB resident. Keeping them out of the UI process means
the app stays responsive and a fault inside ONNX Runtime kills a restartable
helper rather than the app. Frames cross the boundary as `IOSurface`, which XPC
passes **by reference**, so a 1080p frame moves without being copied.

### Why the engine cannot phone home

The app and the engine are separately sandboxed and meet in a shared App Group
container. The app holds `com.apple.security.network.client` because it has to
download models once. The engine holds no network entitlement at all — so once
the models are on disk, offline operation is enforced by the sandbox rather
than by convention.

> A note on a wrong turn worth avoiding: `com.apple.security.inherit` looks like
> the natural fit for an XPC service, but it is meant for processes an app
> spawns itself. XPC services are started by launchd, `secinitd` rejects the
> registration, and the service traps inside dyld before `main()` runs. Hence
> the App Group.

## The pipeline

Per frame, mirroring FaceFusion 3.8.0's `inswapper` path:

1. **Detect** — `yoloface_8n` on a 640×640 canvas → boxes + 5 key points.
2. **Refine** — `2dfan4` → 68 landmarks, reduced back to 5. Steadier than the
   detector's own points across a video.
3. **Align** — least-squares similarity transform onto the `arcface_128`
   template. This is the closed-form 2-D Procrustes solution, which is what
   OpenCV's `estimateAffinePartial2D` converges to.
4. **Condition** — the source portrait's ArcFace embedding, projected through
   the 512×512 `emap` matrix stored as the last initializer *inside* the
   inswapper ONNX file. Note the divisor is the magnitude of the **original**
   embedding, not of the projected result.
5. **Swap** — `inswapper_128_fp16` on a 128×128 aligned crop.
6. **Composite** — feathered box mask, inverse warp, paste back.
7. **Restore** — optional `gfpgan_1.4` at 512×512 over the composited frame.

`emap` is read with a small purpose-built ONNX protobuf walker
(`OnnxInitializer.swift`) — the file is memory-mapped, so the hundreds of
megabytes of weights are skipped rather than paged in.

### Photos

A photo target is the same pipeline with one frame. It differs only at the
edges: there is no timeline to scrub, the codec toggle gives way to the save
panel's PNG/JPEG choice, and the result is written by ImageIO instead of an
encoder. The image is decoded at full resolution rather than the 2048 px cap
used for the source portrait — that cap exists because the source only ever
feeds a 112 px crop, whereas a target photo is what gets written back out.

The export re-runs the swap rather than saving what the preview produced, so
the file always matches the settings as they stand when Export is pressed.

### Choosing which faces get replaced

*Every face* and *One face* are geometric: replace all of them, or replace the
one nearest a point you clicked. *Choose* is not, and the difference matters
for video.

Faces are re-detected independently on every frame, and detection order is
left-to-right within a single frame — so "the second face" stops naming the
same person the moment two people cross, and a fixed point stops naming anyone
as soon as the subject moves. Neither survives a clip.

So *Choose* matches on identity instead. The app samples up to 48 frames across
the duration, asks the engine for an ArcFace embedding per face, and groups
those vectors into people by cosine distance — a running mean per person, so
one badly-timed frame cannot define someone for the rest of the video. Ticking
a person sends their 512-d identity to the engine, which then keeps only the
detections within `matchDistance` of one of them. This is FaceFusion's
`reference` face-selector mode, arrived at for the same reason.

Two consequences worth knowing:

- The reference set is pushed once per change, not per frame, and carries a
  generation number. A swap naming a generation the engine no longer holds is
  refused rather than run against a stale set — silently swapping the wrong
  person is a worse failure than a visible error.
- Sampling can miss someone who is only briefly on screen. Clicking their face
  in the preview adds them, which is why that gesture toggles rather than
  re-selects while *Choose* is active.

Matching costs one extra 112 px recognizer pass per detected face per frame,
and only in this mode — and it is free when *Resemblance* is below 100%, since
that already encodes each target face. It shows up as the `match` column in
`--benchmark`.

### One deliberate divergence

Aligning a 1024 px portrait to ArcFace's 112 px input is a ~6.7× reduction. The
reference samples that with a bare bilinear tap, which aliases badly — single
pixels differ from a correctly prefiltered crop by up to 183/255, and in video
that shows up as shimmer. `BGRAImage.warped` box-reduces before sampling
whenever a warp shrinks by more than half. This moved agreement with the
reference identity vector from 0.956 to 0.966 cosine; the remaining gap is
noise in the reference, not error here.

## Models

Fetched from the published FaceFusion asset release (`models-3.0.0`) and
verified against the SHA-256 digests in
[`FaceFusionMac/Resources/models.json`](FaceFusionMac/Resources/models.json)
before installation. A mismatch is discarded, not installed.

| Model | Size | Required | Licence |
|---|---|---|---|
| `yoloface_8n` | 12.7 MB | yes | GPL-3.0 |
| `arcface_w600k_r50` | 174 MB | yes | InsightFace, non-commercial |
| `inswapper_128_fp16` | 278 MB | yes | InsightFace, non-commercial |
| `2dfan4` | 98 MB | no | MIT |
| `gfpgan_1.4` | 340 MB | no | Apache-2.0 |

**The face-swapping models are licensed for non-commercial research use.** Only
swap faces of people who have agreed to it.

## Measured performance

Apple Silicon, Release build, 640×338 video, one face per frame. A 270-frame
export takes **97s** (~2.8 fps), down from 177s before tuning.

Per-frame stage cost, measured with `--benchmark`:

| Stage | ms/frame |
|---|---|
| Detect (`yoloface_8n`) | 10 |
| Landmarks (`2dfan4`) | 47 |
| Swap (`inswapper_128`) | 126 |
| Composite | 2 |
| Restore (`gfpgan_1.4`) | 280 |
| **Total** | **465** |

Turning off *Enhance detail* removes the largest single cost.

### What the execution-provider sweep showed

Same frame, same models, only the Core ML settings varied:

| Configuration | ms/frame | |
|---|---|---|
| `ALL` + static shapes | **465** | shipping default |
| `ALL` + dynamic shapes | 627 | 35% slower |
| `CPUAndGPU` | 763 | |
| `CPUAndNeuralEngine` | 7,859 | 17× slower |
| `NeuralNetwork` format | 14,995 | 32× slower |
| CPU only | 18,657 | 40× slower |

Two results are worth keeping in mind before "optimising":

**Declaring static input shapes is a free 35% win.** Every graph here has fully
static shapes; telling the EP so lets it absorb regions it otherwise leaves on
the CPU. This was originally set to `0` and was simply wrong.

**Forcing the Neural Engine is catastrophic, not faster.** Pinning these graphs
to `CPUAndNeuralEngine` is 17× *slower* than letting Core ML choose — they are
convolutional generators that the ANE largely rejects, so the run degenerates
into constant fallback. `ALL` is correct: Core ML places most work on the GPU.

Core ML is doing the heavy lifting either way — the CPU-only baseline is 40×
slower.

### Concurrency

The export keeps `ExportRequest.concurrentFrames` (default 3) frames inside the
engine at once. The four models are four independent `ORTSession`s with
independent locks, so while one frame is in the enhancer another can be in the
detector, and decode/encode overlap both. Measured 1.8× end to end.

Destination buffers come from `AVAssetWriterInputPixelBufferAdaptor`'s own pool.
This matters: `append` retains the buffer and the encoder reads it
asynchronously, so hand-recycling a buffer straight back into the engine
overwrites a frame that has not been encoded yet — which showed up as the output
being shifted by exactly the pool depth.

Note a Debug build is ~2.5× slower: the pixel loops are scalar Swift and depend
on optimisation. Always measure in Release.

### Tools

```sh
Release/Morphiqo.app/Contents/MacOS/Morphiqo --benchmark  # sweep EP settings
Release/Morphiqo.app/Contents/MacOS/Morphiqo --profile    # Core ML compute plan
```

### Known remaining headroom

- **Explicit stage pipelining.** Frame-level concurrency overlaps stages only
  incidentally. Running each stage as its own pipeline step, with the enhancer
  session replicated and pinned to the GPU, is estimated at 2.4–2.7× over the
  serial baseline versus the 1.8× measured here. Not implemented.
- **Graph partitioning is unmeasured.** 126 ms for a 128×128 swapper suggests
  Core ML is cutting the graph into many subgraphs, each with a round trip. ORT
  logs this at verbose severity on stderr, which does not escape an XPC service
  — confirming it needs a standalone harness that loads the models in-process.

## Building

```sh
xcodebuild -project FaceFusionMac.xcodeproj -scheme Morphiqo \
           -configuration Release -destination 'platform=macOS,arch=arm64' build
```

Swift Package Manager resolves ONNX Runtime automatically. Build via the
**scheme**, not `-target`: SPM module maps are only generated for scheme builds.

## Testing

```sh
# Unit tests only — no models needed.
xcodebuild -project FaceFusionMac.xcodeproj -scheme Morphiqo \
           -destination 'platform=macOS,arch=arm64' \
           -only-testing:FaceFusionMacTests test
```

The geometry and masking tests check against ground truth captured from the
reference Python implementation (OpenCV + ONNX Runtime), so a regression in the
alignment maths fails the build rather than quietly degrading output.

The integration suite additionally runs the real models and compares the
composited frame against the reference output. It is skipped unless assets are
staged into the app's container:

```sh
Tools/stage-test-assets.sh <dir>   # dir contains models/ media/ out/
```

### End-to-end check

```sh
Release/Morphiqo.app/Contents/MacOS/Morphiqo --selftest
```

Reads `source.jpg` and `target.mp4` from `SelfTest/` in the shared container,
downloads any missing models, exports `output.mp4`, then exports `output.png`
through the photo path and checks the remembered-folder store. Exits non-zero on
failure. It reads from the container rather than from argv because the app is
sandboxed — without the user picking them through the open panel, arbitrary
paths are not readable.

The headless modes run from `applicationDidFinishLaunching`, not from a view's
`.task`. Launching the binary from a shell does not reliably produce a window,
and a view-driven headless run in that situation sits there producing no output
at all, which looks identical to a hang inside the pipeline.

## Debugging

Both processes log to one subsystem:

```sh
log stream --predicate 'subsystem == "com.lisenhuang.FaceFusionMac"' --level debug
```

Categories: `engine` (model loading, execution provider), `inference`
(per-frame stage timings, every 50 frames), `client` (the app side of the XPC
link), `models` (downloads).
