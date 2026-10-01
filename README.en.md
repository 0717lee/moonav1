# MoonAV1

A pure MoonBit AV1/AVIF decoder for native, JavaScript and wasm-gc. The decoding core does not call browser image decoders or native codec libraries. External decoders are used only to produce independent test references.

[简体中文](README.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)

## Scope

- 8/10/12-bit AV1, monochrome and 4:2:0/4:2:2/4:4:4; intra/inter reconstruction, persistent references and entropy state, tiles, quantization, filtering and film grain.
- AVIF primary images, auxiliary alpha, grids, premultiplied-alpha associations and animated color/alpha tracks.
- Output includes native 8/10/12-bit planes, straight RGBA8 and RGBA16, including high-depth alpha and animation.
- Chunked AV1 input, lazy AVIF animation, structured errors, decode limits, display transforms and reusable output buffers.
- AV1 tracks in IVF, MP4/fMP4 and WebM/Matroska, including incremental container input and timestamp seeking.
- Explicit ICC input transforms, PQ/HLG-to-SDR conversion and alpha-aware fractional crop/resampling.
- No encoding, image filters, UI or filesystem dependency.

RGBA preserves source primaries/transfer, uses nearest-neighbor chroma replication and rounds/clips at final conversion. Unspecified matrices use BT.601; XYZ is converted to BT.709/sRGB. There is no HDR tone mapping or display-gamut adaptation. Four PQ reference channels match independent high-precision H.273 results with at most one unit of difference from zimg; see the [color contract](https://github.com/0717lee/moonav1/blob/main/tests/fixtures/av1-color/README.md).

## Install

Add the dependency to a MoonBit project:

```sh
moon add 0717lee/moonav1@0.2.0
```

Import it in the caller's `moon.pkg`:

```moonbit
import {
  "0717lee/moonav1",
}
```

The same package supports native, JavaScript and wasm-gc.

## Quick start

Install MoonBit, clone the source and run the example from the repository root:

```sh
git clone https://github.com/0717lee/moonav1.git
cd moonav1
moon run examples/decode --target js
```

Expected output: `64x64 AV1 -> RGBA8 OK`. The example decodes an embedded 10-bit AV1 sample, checks dimensions and pixels, and verifies rejection of empty input. No external decoder or image download is needed. It also runs with `--target wasm-gc` and `--target native`.

Run `moon run examples/native_pixels --target js` for native planes, RGBA16 and animation selection, or `moon run examples/extensions --target js` for streaming, metadata and output buffers. Both examples also support native and wasm-gc.

`moon run examples/containers --target js` demonstrates whole-file IVF decoding, timestamp seeking and incremental decoding. It also supports native and wasm-gc.

`moon run examples/color_video --target js` demonstrates ICC, HDR, fractional cropping and the three container formats, also on native and wasm-gc.

## Library API

After importing the package, consumers can use the `@moonav1` alias:

```moonbit
fn decode_image(bytes : Array[Byte]) -> @moonav1.Image? {
  @moonav1.avif_decode_rgba(bytes)
}
```

Use `av1_decode` for raw AV1, `avif_decode_rgba` for AVIF with alpha/grid composition, and `avif_decode_animation` for timed animation frames. Create an `av1_video_decoder` and pass units to `av1_video_decode_temporal_unit` for persistent AV1 state. `None` indicates rejection; `Some([])` indicates a valid hidden-only unit. See [the complete interface](pkg.generated.mbti).

`av1_decode_native`, `avif_decode_native` and `avif_decode_animation_native` retain native precision. RGBA16 convenience APIs and conversions preserve it through final quantization. `Av1StreamDecoder` and `AvifAnimationDecoder` provide incremental and lazy decoding; `Result` entry points expose classified errors with context and offsets. See [native pixels](docs/NATIVE_PIXELS.md), [RGBA16](docs/RGBA16.md), [caller APIs](docs/EXTENSIONS.md) and [decode limits](docs/DECODE_LIMITS.md).

`Av1ContainerDecoder`, `Av1ContainerStreamDecoder` and `Av1PresentationTimeline` handle [containers](docs/VIDEO_CONTAINERS.md), [chunked input](docs/CONTAINER_STREAMING.md), and [timestamp seeking and movie edits](docs/CONTAINER_TIMELINE.md).

[ICC transforms](docs/ICC.md), [HDR conversion](docs/HDR.md) and [fractional resampling](docs/RESAMPLING.md) are explicit operations that preserve the existing base-decoder color and pixel contracts.

## Build

The pinned compiler is `0.10.14+7d59c7ec9`; native tests require a C toolchain. Clone the GitHub source and run these commands from the repository root:

```sh
moon check
moon build
moon test --target js
moon test --target wasm-gc
moon test --target native
```

Ordinary tests are self-contained and do not require an external decoder. Fixture manifests preserve independent pixels, source versions and commands. Reference-generation tools are in `scripts/`.

## Extended validation and benchmarks

See [validation](docs/VALIDATION.md) for file consumers, real media and long-video checks, and [benchmarking](docs/PERFORMANCE.md) for reproducible measurements. Versioned release assets retain larger encoded inputs and independent pixels. Select groups with `python scripts/fetch-fixtures.py --list`; ordinary tests need no download.

## License

[Apache-2.0](LICENSE). Algorithm, table and reference-tool attribution is retained in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
