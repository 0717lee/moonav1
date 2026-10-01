# MoonAV1

A pure MoonBit AV1/AVIF decoder for native, JavaScript and wasm-gc. The decoding core does not call browser image decoders or native codec libraries. External decoders are used only to produce independent test references.

[简体中文](README.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)

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

The package identifier is `0717lee/moonav1`; it has not been published to Mooncakes. After importing the package, consumers can use the `@moonav1` alias:

```moonbit
fn decode_image(bytes : Array[Byte]) -> @moonav1.Image? {
  @moonav1.avif_decode_rgba(bytes)
}
```

Use `av1_decode` for raw AV1, `avif_decode_rgba` for AVIF with alpha/grid composition, and `avif_decode_animation` for timed animation frames. Create an `av1_video_decoder` and pass units to `av1_video_decode_temporal_unit` for persistent AV1 state. `None` indicates rejection; `Some([])` indicates a valid hidden-only unit. See [the complete interface](pkg.generated.mbti).

## Build

The pinned compiler is `0.10.14+7d59c7ec9`; native tests require a C toolchain.

```sh
moon check
moon build
moon test --target js
moon test --target wasm-gc
moon test --target native
```

Ordinary tests are self-contained and do not require an external decoder. Fixture manifests preserve independent pixels, source versions and commands. Reference-generation tools are in `scripts/`.

## License

[Apache-2.0](LICENSE). Algorithm, table and reference-tool attribution is retained in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
