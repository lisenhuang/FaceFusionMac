//
//  ImageOps.metal
//  FaceFusionEngine
//
//  The GPU half of `ImageBuffer.swift`.
//
//  These kernels are not a reinterpretation of the pixel maths — they are a
//  transcription of it. The CPU implementations were validated against a
//  Python/OpenCV ground truth and are still the fallback, so anything here that
//  rounds differently, samples on a different grid, or reassociates an
//  accumulation is a bug even if the picture looks fine. The rules that matter:
//
//   * BGRA is addressed as `device uchar4 *` over an explicit `rowBytes`, never
//     as a texture. A texture would bring a pixel-format conversion and a
//     sampler with its own rounding, and the GPU would then be looking at
//     different numbers from the CPU. This way it sees the same bytes.
//   * Sampling is destination-driven at pixel centres: take (x + 0.5), map it
//     through the inverse transform, then shift back half a pixel. That is
//     OpenCV's integer-grid convention and the whole alignment pipeline is
//     calibrated to it.
//   * Coordinates are clamped to the edge, never wrapped or zeroed.
//   * A warp that shrinks by more than half is box-reduced by an integer factor
//     first and *then* sampled bilinearly. Two steps, in that order. A
//     single-pass wide filter would be a better image but a different number.
//   * Anything that becomes a byte is `round()`ed — half away from zero, as
//     Swift's `.rounded()` is — and then clamped, in that order.
//
//  The inverse transforms arrive already inverted, computed on the CPU in
//  double precision, so both paths start from bit-identical coefficients.
//
//  This file is a byte-for-byte copy of the iOS one and must stay that way.
//  The two apps are one pipeline on two platforms, and a kernel that rounded
//  differently here would put the Mac's output out of step with the iPhone's
//  for reasons no test on either side would explain.
//
//  Correctness check for whoever touches this next: over a handful of random
//  transforms a GPU result must match the CPU result to within ±1 of 255 on
//  every channel. The slack exists only because Metal compiles with fast maths
//  and may contract a multiply-add; it is not licence for a different
//  algorithm.
//

#include <metal_stdlib>
using namespace metal;

/// 1/255 as a single-precision constant. The CPU multiplies by this rather
/// than dividing by 255, and the two do not always agree in the last bit.
constant float kInverseByteScale = 1.0f / 255.0f;

/// A 2-D affine map, already inverted (destination -> source).
///
/// Every field of every parameter struct in this file is a 4-byte scalar. That
/// is deliberate: it makes the Metal and Swift layouts identical without a
/// bridging header, which the app target does not have.
struct Affine {
    float a, b, c, d, tx, ty;
};

// MARK: - Sampling

/// Bilinear tap with edge replication, in the CPU's exact order of operations.
static inline float4 sample_bgra(device const uchar *base,
                                 uint rowBytes,
                                 uint width,
                                 uint height,
                                 Affine t,
                                 float fx,
                                 float fy)
{
    float maxX = float(width - 1);
    float maxY = float(height - 1);

    float sx = clamp(t.a * fx + t.c * fy + t.tx - 0.5f, 0.0f, maxX);
    float sy = clamp(t.b * fx + t.d * fy + t.ty - 0.5f, 0.0f, maxY);

    // Truncation is floor here because the clamp above guarantees sx, sy >= 0.
    int x0 = int(sx);
    int y0 = int(sy);
    int x1 = min(x0 + 1, int(maxX));
    int y1 = min(y0 + 1, int(maxY));
    float wx = sx - float(x0);
    float wy = sy - float(y0);

    device const uchar4 *r0 = (device const uchar4 *)(base + uint(y0) * rowBytes);
    device const uchar4 *r1 = (device const uchar4 *)(base + uint(y1) * rowBytes);

    float w00 = (1.0f - wx) * (1.0f - wy);
    float w10 = wx * (1.0f - wy);
    float w01 = (1.0f - wx) * wy;
    float w11 = wx * wy;

    return float4(r0[x0]) * w00 + float4(r0[x1]) * w10
         + float4(r1[x0]) * w01 + float4(r1[x1]) * w11;
}

/// The same tap over a single-channel float mask. Masks are never prefiltered
/// — `FloatMask.warped` does a bare bilinear read and the feathering hides the
/// aliasing — so this must not gain a box-reduce of its own.
static inline float sample_mask(device const float *values,
                                uint width,
                                uint height,
                                Affine t,
                                float fx,
                                float fy)
{
    float maxX = float(width - 1);
    float maxY = float(height - 1);

    float sx = clamp(t.a * fx + t.c * fy + t.tx - 0.5f, 0.0f, maxX);
    float sy = clamp(t.b * fx + t.d * fy + t.ty - 0.5f, 0.0f, maxY);

    int x0 = int(sx);
    int y0 = int(sy);
    int x1 = min(x0 + 1, int(maxX));
    int y1 = min(y0 + 1, int(maxY));
    float wx = sx - float(x0);
    float wy = sy - float(y0);

    return values[uint(y0) * width + uint(x0)] * (1.0f - wx) * (1.0f - wy)
         + values[uint(y0) * width + uint(x1)] * wx * (1.0f - wy)
         + values[uint(y1) * width + uint(x0)] * (1.0f - wx) * wy
         + values[uint(y1) * width + uint(x1)] * wx * wy;
}

/// What the CPU stores after a warp: an 8-bit pixel. Fusing a warp into a
/// tensor without this step would skip the quantisation the models were
/// measured against, so the fused kernel below rounds here too.
static inline float4 quantise(float4 v)
{
    return clamp(round(v), 0.0f, 255.0f);
}

// MARK: - box_reduce

struct BoxReduceParams {
    uint srcWidth, srcHeight, srcRowBytes;
    uint dstWidth, dstHeight, dstRowBytes;
    uint factor;
    float inverseArea;
};

/// Averages each `factor` x `factor` block into one pixel, matching
/// `BGRAImage.boxReduced`. The accumulation order — rows outer, columns inner,
/// into one running float4 — is copied from the CPU so the rounding at the end
/// lands on the same side of a half.
kernel void box_reduce(device const uchar *src [[buffer(0)]],
                       device uchar *dst [[buffer(1)]],
                       constant BoxReduceParams &p [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.dstWidth || gid.y >= p.dstHeight) { return; }

    float4 sums = float4(0.0f);
    for (uint dy = 0; dy < p.factor; ++dy) {
        uint sy = min(gid.y * p.factor + dy, p.srcHeight - 1);
        device const uchar4 *row = (device const uchar4 *)(src + sy * p.srcRowBytes);
        for (uint dx = 0; dx < p.factor; ++dx) {
            uint sx = min(gid.x * p.factor + dx, p.srcWidth - 1);
            sums += float4(row[sx]);
        }
    }
    sums *= p.inverseArea;

    device uchar4 *out = (device uchar4 *)(dst + gid.y * p.dstRowBytes);
    out[gid.x] = uchar4(quantise(sums));
}

// MARK: - warp_bgra

struct WarpParams {
    uint srcWidth, srcHeight, srcRowBytes;
    uint dstWidth, dstHeight, dstRowBytes;
    Affine inverse;
};

/// Destination-driven bilinear warp with edge clamp, matching
/// `BGRAImage.drawWarped`. The alpha channel is carried through like any other,
/// which is what the CPU does.
kernel void warp_bgra(device const uchar *src [[buffer(0)]],
                      device uchar *dst [[buffer(1)]],
                      constant WarpParams &p [[buffer(2)]],
                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.dstWidth || gid.y >= p.dstHeight) { return; }

    float4 v = sample_bgra(src, p.srcRowBytes, p.srcWidth, p.srcHeight,
                           p.inverse, float(gid.x) + 0.5f, float(gid.y) + 0.5f);

    device uchar4 *out = (device uchar4 *)(dst + gid.y * p.dstRowBytes);
    out[gid.x] = uchar4(quantise(v));
}

// MARK: - warp_to_tensor

struct WarpTensorParams {
    uint srcWidth, srcHeight, srcRowBytes;
    uint spanWidth, spanHeight;        // the region actually written
    uint tensorWidth, tensorHeight;    // the padded extent
    uint c0, c1, c2;                   // which byte of the BGRA pixel each plane reads
    float mean, standardDeviation;
    Affine inverse;
};

/// Warp and normalise in one pass, which is what every model in the pipeline
/// actually wants: it removes a full intermediate BGRA crop per invocation.
///
/// The pad, when there is one, is left alone — the tensor arrives zeroed and
/// the detector's 640x640 canvas depends on that being exactly zero rather than
/// (0 - mean) / standardDeviation.
kernel void warp_to_tensor(device const uchar *src [[buffer(0)]],
                           device float *dst [[buffer(1)]],
                           constant WarpTensorParams &p [[buffer(2)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.spanWidth || gid.y >= p.spanHeight) { return; }

    float4 v = sample_bgra(src, p.srcRowBytes, p.srcWidth, p.srcHeight,
                           p.inverse, float(gid.x) + 0.5f, float(gid.y) + 0.5f);
    // Round to a byte first. The CPU writes the crop out as 8-bit and reads it
    // back, and that quantisation is part of the validated result.
    float4 q = quantise(v);

    uint plane = p.tensorWidth * p.tensorHeight;
    uint index = gid.y * p.tensorWidth + gid.x;
    uint offsets[3] = { p.c0, p.c1, p.c2 };

    for (uint c = 0; c < 3; ++c) {
        float raw = q[offsets[c]] * kInverseByteScale;
        dst[c * plane + index] = (raw - p.mean) / p.standardDeviation;
    }
}

// MARK: - pack_tensor

struct PackParams {
    uint srcWidth, srcHeight, srcRowBytes;
    uint spanWidth, spanHeight;
    uint tensorWidth, tensorHeight;
    uint c0, c1, c2;
    float mean, standardDeviation;
};

/// `BGRAImage.tensorCHW` for an image that is already the right size.
kernel void pack_tensor(device const uchar *src [[buffer(0)]],
                        device float *dst [[buffer(1)]],
                        constant PackParams &p [[buffer(2)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.spanWidth || gid.y >= p.spanHeight) { return; }

    device const uchar4 *row = (device const uchar4 *)(src + gid.y * p.srcRowBytes);
    float4 pixel = float4(row[gid.x]);

    uint plane = p.tensorWidth * p.tensorHeight;
    uint index = gid.y * p.tensorWidth + gid.x;
    uint offsets[3] = { p.c0, p.c1, p.c2 };

    for (uint c = 0; c < 3; ++c) {
        float raw = pixel[offsets[c]] * kInverseByteScale;
        dst[c * plane + index] = (raw - p.mean) / p.standardDeviation;
    }
}

// MARK: - unpack_tensor

struct UnpackParams {
    uint width, height, dstRowBytes;
    uint c0, c1, c2;
    float mean, standardDeviation;
};

/// `BGRAImage.fromTensorCHW`. Note the rounding here is *not* `round()`: the
/// CPU clamps to 0...1, scales by 255, adds a half and truncates, and that
/// expression is copied literally rather than tidied into a `round()` so the
/// two paths cannot disagree at a boundary.
kernel void unpack_tensor(device const float *src [[buffer(0)]],
                          device uchar *dst [[buffer(1)]],
                          constant UnpackParams &p [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) { return; }

    uint plane = p.width * p.height;
    uint index = gid.y * p.width + gid.x;
    uint offsets[3] = { p.c0, p.c1, p.c2 };

    uchar4 pixel = uchar4(0, 0, 0, 255);
    for (uint c = 0; c < 3; ++c) {
        float v = src[c * plane + index] * p.standardDeviation + p.mean;
        pixel[offsets[c]] = uchar(clamp(v, 0.0f, 1.0f) * 255.0f + 0.5f);
    }

    device uchar4 *out = (device uchar4 *)(dst + gid.y * p.dstRowBytes);
    out[gid.x] = pixel;
}

// MARK: - paste_back

struct PasteParams {
    uint dstRowBytes;
    uint originX, originY;
    uint regionWidth, regionHeight;
    uint patchWidth, patchHeight, patchRowBytes;
    uint maskWidth, maskHeight;
    float opacity;
    Affine patchInverse;
    Affine maskInverse;
};

/// Warps `patch` and `mask` into the destination region and blends, matching
/// `BGRAImage.pasteBack`.
///
/// There are two inverse transforms rather than one because the patch may have
/// been box-reduced before this ran while the mask never is, so the two no
/// longer share a mapping. The destination's alpha byte is left untouched: the
/// CPU blends channels 0...2 only, and overwriting alpha on a frame that came
/// out of a decoder would change what the encoder sees.
kernel void paste_back(device uchar *dst [[buffer(0)]],
                       device const uchar *patch [[buffer(1)]],
                       device const float *mask [[buffer(2)]],
                       constant PasteParams &p [[buffer(3)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.regionWidth || gid.y >= p.regionHeight) { return; }

    float fx = float(gid.x) + 0.5f;
    float fy = float(gid.y) + 0.5f;

    float alpha = clamp(sample_mask(mask, p.maskWidth, p.maskHeight,
                                    p.maskInverse, fx, fy), 0.0f, 1.0f) * p.opacity;
    if (!(alpha > 0.001f)) { return; }

    // The CPU blends against the warped patch *after* it has been written out
    // as bytes, so quantise before mixing.
    float4 source = quantise(sample_bgra(patch, p.patchRowBytes,
                                         p.patchWidth, p.patchHeight,
                                         p.patchInverse, fx, fy));

    device uchar4 *row = (device uchar4 *)(dst + (p.originY + gid.y) * p.dstRowBytes);
    uchar4 existing = row[p.originX + gid.x];

    float3 blended = float3(existing.xyz) * (1.0f - alpha) + source.xyz * alpha;
    existing.xyz = uchar3(clamp(round(blended), 0.0f, 255.0f));
    row[p.originX + gid.x] = existing;
}

// MARK: - pack_tensor_hwc

struct PackHWCParams {
    uint width, height, srcRowBytes;
};

/// `FaceOccluder.inputTensor`: channels-last, BGR, plain 1/255 with no mean
/// subtraction.
///
/// Channels-last because that graph was exported from TensorFlow and kept the
/// layout, which is why this cannot go through `pack_tensor` — the only
/// difference is where each of the three values lands, and the arithmetic per
/// value is identical, so this one is bit-for-bit rather than within-a-bit.
kernel void pack_tensor_hwc(device const uchar *src [[buffer(0)]],
                            device float *dst [[buffer(1)]],
                            constant PackHWCParams &p [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) { return; }

    device const uchar4 *row = (device const uchar4 *)(src + gid.y * p.srcRowBytes);
    uchar4 pixel = row[gid.x];

    uint out = (gid.y * p.width + gid.x) * 3;
    dst[out]     = float(pixel.x) * kInverseByteScale;
    dst[out + 1] = float(pixel.y) * kInverseByteScale;
    dst[out + 2] = float(pixel.z) * kInverseByteScale;
}

// MARK: - mask_warp

struct MaskWarpParams {
    uint srcWidth, srcHeight;
    uint dstWidth, dstHeight;
    Affine inverse;
};

/// `FloatMask.warped`. Uses the same `sample_mask` the paste-back kernel does,
/// which is the point: a mask sampled two different ways would put the seam in
/// two different places depending on which path ran.
kernel void mask_warp(device const float *src [[buffer(0)]],
                      device float *dst [[buffer(1)]],
                      constant MaskWarpParams &p [[buffer(2)]],
                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.dstWidth || gid.y >= p.dstHeight) { return; }

    dst[gid.y * p.dstWidth + gid.x] =
        sample_mask(src, p.srcWidth, p.srcHeight, p.inverse,
                    float(gid.x) + 0.5f, float(gid.y) + 0.5f);
}

// MARK: - mask_blur

struct MaskBlurParams {
    uint width, height;
    uint radius;
    uint horizontal;   // 1 along x, 0 along y
};

/// One pass of `FloatMask.blurred`'s separable Gaussian.
///
/// By far the most expensive thing the CPU was still doing per face per frame:
/// the restorer's 512x512 mask at the default feather is a ~150-tap kernel in
/// each direction, which is twenty-odd million multiply-adds a frame.
///
/// The weights are computed on the CPU and handed in, so both paths use
/// bit-identical coefficients, and the accumulation runs in the same order —
/// ascending tap index into one running float — so the two agree to within a
/// contracted multiply-add. Edge handling is a clamp, as it is there; note that
/// this is *not* the same as OpenCV's default border for `GaussianBlur`, but it
/// is what the validated Swift implementation does and that is the reference.
kernel void mask_blur(device const float *src [[buffer(0)]],
                      device float *dst [[buffer(1)]],
                      device const float *weights [[buffer(2)]],
                      constant MaskBlurParams &p [[buffer(3)]],
                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) { return; }

    int taps = int(p.radius) * 2 + 1;
    int radius = int(p.radius);
    float sum = 0.0f;

    if (p.horizontal != 0) {
        int limit = int(p.width) - 1;
        for (int k = 0; k < taps; ++k) {
            int sx = clamp(int(gid.x) + k - radius, 0, limit);
            sum += src[gid.y * p.width + uint(sx)] * weights[k];
        }
    } else {
        int limit = int(p.height) - 1;
        for (int k = 0; k < taps; ++k) {
            int sy = clamp(int(gid.y) + k - radius, 0, limit);
            sum += src[uint(sy) * p.width + gid.x] * weights[k];
        }
    }

    dst[gid.y * p.width + gid.x] = sum;
}
