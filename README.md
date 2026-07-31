# FaceFusionMac

A local-first face-swapping app for macOS. No Python, no FFmpeg, no Conda,
no Homebrew — install the app, download the models once, and everything after
that runs on your Mac with no network connection.

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

Apple Silicon, Release build, 640×338 video, one face per frame, all models
loaded via the Core ML execution provider:

| Stage | ms/frame |
|---|---|
| Detect (`yoloface_8n`) | 14 |
| Landmarks (`2dfan4`) | 87 |
| Swap (`inswapper_128`) | 102 |
| Composite | 2 |
| Restore (`gfpgan_1.4`) | 340 |
| **Total** | **545** (~1.9 fps) |

Turning off *Enhance detail* roughly doubles throughput to ~3.9 fps. The time is
dominated by model inference, not by the surrounding code — Core ML compiles and
caches all five graphs (~1.7 GB of compiled artefacts) on first launch, and
reuses them afterwards.

Note that a Debug build is ~2.5× slower (0.7 fps): the pixel loops are scalar
Swift and depend on optimisation. Measure in Release.

## Building

```sh
xcodebuild -project FaceFusionMac.xcodeproj -scheme FaceFusionMac \
           -configuration Release -destination 'platform=macOS,arch=arm64' build
```

Swift Package Manager resolves ONNX Runtime automatically. Build via the
**scheme**, not `-target`: SPM module maps are only generated for scheme builds.

## Testing

```sh
# Unit tests only — no models needed.
xcodebuild -project FaceFusionMac.xcodeproj -scheme FaceFusionMac \
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
Release/FaceFusionMac.app/Contents/MacOS/FaceFusionMac --selftest
```

Reads `source.jpg` and `target.mp4` from `SelfTest/` in the shared container,
downloads any missing models, exports `output.mp4`, and exits non-zero on
failure. It reads from the container rather than from argv because the app is
sandboxed — without the user picking them through the open panel, arbitrary
paths are not readable.

## Debugging

Both processes log to one subsystem:

```sh
log stream --predicate 'subsystem == "com.lisenhuang.FaceFusionMac"' --level debug
```

Categories: `engine` (model loading, execution provider), `inference`
(per-frame stage timings, every 50 frames), `client` (the app side of the XPC
link), `models` (downloads).
