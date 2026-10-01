# File-backed maturity workloads

This corpus extends exact native-pixel comparisons beyond embedded unit fixtures.
The original compressed streams, source YUV, independent references and syntax
traces are retained. The [manifest](manifest.json) records commands, versions,
hashes, actual color metadata, coded/displayed frame evidence and grid item links.

| Workload | Format | Independent reference |
| --- | --- | --- |
| `photo_8bit_3840x2160` | 4K photographic 8-bit 4:2:0 | dav1d + static libavif |
| `scene_10bit_3840x2160` | 4K synthetic 10-bit 4:2:0 | dav1d + static libavif |
| `scene_12bit_2048x1152_422` | Synthetic 12-bit 4:2:2 | dav1d + static libavif |
| `photo_12bit_1921x1081_444` | Odd-sized photographic 12-bit 4:4:4 | dav1d + static libavif |
| `video_10bit_320x180_300` | 300 distinct frames, 10-bit 4:2:0 | dav1d, display order |
| `alpha_grid_12bit_1920x1088` | Color + alpha grids, 12-bit | libavif, with eight separately dav1d-checked cells |

A separate [HD video manifest](hd-video-manifest.json) adds
`video_10bit_1920x1080_16`: 16 distinct 10-bit 4:2:0 pictures at 1080p, with an
eight-picture key interval and encoder lookahead. This exercises larger inter
reference/motion fields separately from the small sustained sequence. Keeping
its manifest separate preserves the original six-workload record and artifacts.

This HD sequence exposed a compound spatial-motion bug in displayed picture 2
(zero-based). Three 32×32 blocks inherited vectors from a GLOBAL_GLOBALMV
neighbour at its own centre. Affine/rotzoom candidates must use the current
block centre separately for each reference before precision lowering and pair
deduplication. The correction in `av1_mv.mbt` restores exact samples for all 16
pictures on native, JS and wasm-gc. The
[before/after record](../../../benchmarks/results/hd-global-regression.json)
retains the original mismatch and four focused regressions. The
[source-only reverse patch](compound-global-baseline.patch) reproduces the old
behavior in a disposable local copy; do not apply it to the accepted decoder.
The derivation was checked against dav1d 1.2.1
[`add_spatial_candidate` / `dav1d_refmvs_find`](https://github.com/videolan/dav1d/blob/1.2.1/src/refmvs.c)
and [`splat_tworef_mv`](https://github.com/videolan/dav1d/blob/1.2.1/src/decode.c).
The adjacent forced-integer translation correction has a separate
[focused derivation regression](../../../benchmarks/results/global-integer-regression.json).
The HD sequence demonstrates the compound candidate error; it is not claimed
as a separate bitstream reproduction of the integer-only precision case.

The video is 12 seconds at 25 fps. It contains 300 coded pictures, five key
pictures, 31 hidden pictures and 31 show-existing operations, yielding 300
presentations. A sustained consumption run replays these same saved bytes ten
times through one decoder (3,000 presentations), retaining only one caller
picture while references update. This checks repeated GOP resets and reference
lifetime; it is not 3,000 distinct independently encoded pictures.

The alpha grid assembles four 960×576 color cells and four monochrome alpha
cells, cropping the bottom row to a 1920×1088 canvas. Inputs vary by cell.
It uses full-range alpha and no premultiplication. Each encoded cell has a
separate native dav1d reference and a libavif-checked AVIF; the complete grid's
color and alpha references come directly from libavif.

## Photographic source and attribution

The photographic source is NASA / Apollo 17 crew, photograph **AS17-148-22727**
(December 7, 1972). NASA identifies it in [The Blue Marble: The View From Apollo 17](https://www.nasa.gov/image-article/blue-marble-view-from-apollo-17/).
The saved [original JPEG](apollo17-blue-marble.jpg) was downloaded from the
[NASA image archive](https://images-assets.nasa.gov/image/as17-148-22727/as17-148-22727~orig.jpg).
It is 4579×4579; SHA-256 is
`cb4c3d2da98ee72130ebfd2ea472fc84ede6726002c2a8c9cabd86e4deea9f0f`.

Use follows [NASA's media usage guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/)
for factual educational/informational material with source acknowledgment.
This is decoder test material; NASA does not endorse the library. The original
photograph and its credit retain their own status rather than being relicensed
as MoonAV1 code. Test inputs are explicitly center-cropped, optionally rescaled,
converted to YUV and lossily AV1-encoded; they are not unchanged copies of the
photograph. The 12-bit variant is derived from an 8-bit JPEG, not a native HDR
capture. Conversion commands are retained in the manifest.

## Precision and reproduction

Native references are tightly packed Y/U/V (Y alone for monochrome), then the
next displayed frame. Eight-bit samples are bytes; 10/12-bit samples are
unshifted little-endian uint16. Odd chroma dimensions round up. Every sample is
compared, with zero tolerance. No image digest or sampled subset replaces pixel
comparison. Saved hashes protect provenance and input identity separately.

Encoding uses FFmpeg 9.0.1 / libaom `3.14.1-147-gec0dedc1a2`, one thread,
CPU-used 6 and CRF 32. Video uses 16-frame lookahead; the sustained sequence has
a 64-frame key interval and the HD sequence has an eight-frame key interval.
dav1d 1.2.1 and libavif 0.11.1 supply independent native references. Actual
color metadata is recorded rather than inferred from requested encoder flags.

```sh
python scripts/generate-maturity-reference.py --check
python scripts/generate-maturity-reference.py --check --redecode --libavif /path/to/avif.dll
python scripts/check-file-fixtures.py --video-repetitions 10 --output _build/maturity-current.json
python scripts/generate-maturity-reference.py --group hd-video --check --redecode --libavif /path/to/avif.dll
python scripts/check-file-fixtures.py --manifest tests/fixtures/av1-maturity/hd-video-manifest.json --output _build/hd-video-current.json
```

Generation writes only this corpus and refuses to replace a completed manifest.
Per-case JSON records allow an interrupted initial generation to resume without
re-encoding completed cases. Normal verification reads the saved files and
does not need external codecs. The [consumer](../../file_decode/main.mbt) reads
independent references incrementally; its C/Node adapters implement file IO
only, while AV1/AVIF decoding remains MoonBit on all three backends.

These workloads are additional regression evidence, not exhaustive codec
conformance, arbitrary-duration playback, all photographs or all 4K profiles.
