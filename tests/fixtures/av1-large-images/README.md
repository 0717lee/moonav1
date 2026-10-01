# Larger image and video references

These original, deterministic synthetic scenes extend the small correctness
fixtures to larger decoded surfaces. They are gradients, detailed patches and
a translated circle, generated with integer arithmetic; no external imagery
was used. They are not a photographic or long-video corpus.

| Case | Input | Presentations | Container/API coverage |
| --- | --- | --- | --- |
| `still_8bit_512x384` | 512×384, 8-bit 4:2:0 | 1 | Raw AV1, static AVIF |
| `still_12bit_512x384` | 512×384, 12-bit 4:2:0 | 1 | Raw AV1, static AVIF |
| `video_10bit_640x360` | 640×360, 10-bit 4:2:0 | 4 | Separate temporal units and concatenated raw AV1 |

The video contains one key frame and three inter frames. Its 360-pixel height
is not a multiple of the superblock size, exercising partial bottom blocks.
The independent syntax trace records frame headers and actual color metadata;
header permission alone is not evidence that a coding tool was selected.

## Source and pixel contract

[`generate-large-reference.py`](../../../scripts/generate-large-reference.py)
uses FFmpeg 9.0.1 with libaom `3.14.1-147-gec0dedc1a2`, one encoder thread,
`cpu-used=6`, CRF 32 and zero lookahead. Coding-tool switches otherwise retain
their defaults. Encoder arguments and input/output hashes are in
[`manifest.json`](manifest.json). Static AVIF containers remux the same AV1
stream without re-encoding.

Native pixels are independently decoded by dav1d 1.2.1. libavif 0.11.1 also
decodes each static container and must produce identical native planes and
metadata. The reference is the lossy stream's decoded output, not the encoder
input. Every native sample must match exactly; no RGB conversion, tolerance or
image digest substitutes for per-sample comparison.

References are frame-major, then Y/U/V, with tight rows. At eight bits, each
sample is one byte. At 10/12 bits, each sample is little-endian unsigned 16-bit,
without shifting away low bits. Current streams signal limited range and CICP
`(2,2,1)`; the manifest derives these values from the syntax trace rather than
assuming the encoder's requested tags were written.

Each case retains `.input.yuv`, untouched `.obu`, `.reference.yuv`, and the
normalized FFmpeg `trace_headers` transcript. Static cases also retain `.avif`.
The public consumer in [`benchmarks/large`](../../../benchmarks/large/main.mbt)
and its tests embed these saved values. Expected data is split into per-frame
functions to stay within the pinned compiler's source-segment limit.

## Reproduction

Ordinary tests and benchmarks require no external codec or Python. To check
the stored scene recipe, artifact hashes, metadata and embedding:

```sh
python scripts/generate-large-reference.py --check
```

To additionally decode the saved streams again without re-encoding or writing
references:

```sh
python scripts/generate-large-reference.py --check --redecode --libavif /path/to/avif.dll
```

To refresh only the MoonBit embedding, use `--embed-only`. Full regeneration
requires the recorded tools and is an explicit maintenance operation:

```sh
python scripts/generate-large-reference.py --libavif /path/to/avif.dll
```

That command writes this fixture directory and the large consumer's generated
source. It does not alter the older fixture sets. Codec/version changes can
change the encoded streams and must be reviewed along with their new evidence.
