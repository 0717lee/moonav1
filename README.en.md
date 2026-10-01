# MoonAV1

A pure MoonBit AV1/AVIF decoder for native, JavaScript and wasm-gc. The decoding core does not call browser image decoders or native codec libraries. External decoders are used only to produce independent test references.

Extracted from [PixelForge](https://github.com/0717lee/pixelforge); see [provenance](PROVENANCE.md), [handoff and acceptance criteria](HANDOFF.md), and [third-party notices](THIRD_PARTY_NOTICES.md). This public MVP is based on the independent decoder from September 24, 2026 and provides RGBA8 output. It has not been published to Mooncakes. The existing implementation remains in PixelForge's public history.

PixelForge has no active MoonAV1 dependency and removed its built-in AV1/AVIF pixel decoder in `0.19.0`. Future integration will use a released MoonAV1 package.

## Scope

- 8/10/12-bit AV1, monochrome and 4:2:0/4:2:2/4:4:4; intra/inter reconstruction, persistent references and entropy state, tiles, quantization, filtering and film grain.
- AVIF primary images, auxiliary alpha, grids, premultiplied-alpha associations and animated color/alpha tracks.
- RGBA convenience APIs return straight RGBA8. Native-depth samples are retained through reconstruction and composition.
- No encoding, image filters, UI or filesystem dependency.

RGBA preserves source primaries/transfer, uses nearest-neighbor chroma replication and rounds/clips at final conversion. Unspecified matrices use BT.601; XYZ is converted to BT.709/sRGB. There is no HDR tone mapping or display-gamut adaptation. Four PQ reference channels match independent high-precision H.273 results with at most one unit of difference from zimg; see the [color contract](tests/fixtures/av1-color/README.md).

## Quick start

Install MoonBit, clone the source and run the example from the repository root:

```sh
git clone https://github.com/0717lee/moonav1.git
cd moonav1
moon run examples/decode --target js
```

Expected output: `64x64 AV1 -> RGBA8 OK`. The example decodes an embedded 10-bit AV1 sample, checks dimensions and pixels, and verifies rejection of empty input. No external decoder or image download is needed. It also runs with `--target wasm-gc` and `--target native`.

## Library API

The package identifier is `0717lee/moonav1` and is currently unavailable from Mooncakes. The example below shows the `@moonav1` alias used by a consumer after importing the package. PixelForge currently has no active dependency on this library:

```moonbit
fn decode_image(bytes : Array[Byte]) -> @moonav1.Image? {
  @moonav1.avif_decode_rgba(bytes)
}
```

Use `av1_decode` for raw AV1, `avif_decode_rgba` for AVIF with alpha/grid composition, and `avif_decode_animation` for timed animation frames. Create an `av1_video_decoder` and pass units to `av1_video_decode_temporal_unit` for persistent AV1 state. `None` indicates rejection; `Some([])` indicates a valid hidden-only unit. See [the complete interface](pkg.generated.mbti).

## Build

The pinned compiler is `0.10.11+6ff76a5f9`; native tests require a C toolchain.

```sh
moon check
moon test --target js
moon test --target wasm-gc
moon test --target native
```

Ordinary tests are self-contained and do not require PixelForge or an external decoder. Fixture manifests preserve independent pixels, source versions and commands. Reference-generation tools are in `scripts/`.

This independent library retains its base decoder source, tests, fixtures, generators and licensing documents for standalone development. Public native-pixel APIs, RGBA16, streaming, ICC/HDR and video containers are outside this public MVP. Existing local extensions will be prepared for publication in separate changes.

Apache-2.0, with the upstream notices retained. “Pure MoonBit” describes the implementation language, not original authorship of every algorithm.
