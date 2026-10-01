# Real film sequence

The source is a 30-second mirrored excerpt of **Big Buck Bunny**:
(c) copyright 2008, Blender Foundation / www.bigbuckbunny.org.
The film is licensed under **Creative Commons Attribution 3.0**, as recorded by
the [original project](https://peach.blender.org/about/). The
[source mirror](https://raw.githubusercontent.com/chintan9/Big-Buck-Bunny/master/BigBuckBunny1080p30s.mp4)
and its exact SHA-256 are recorded in `manifest.json`; the downloaded source is
retained alongside derived inputs.

The generator selects video, scales 1920×1080 to 512×288 with Lanczos, removes
audio, and encodes 8-bit 4:2:0 AV1 with a 120-picture key interval and 16-picture
lookahead. The actual output contains **706 presentations** (about 29.4 seconds
at the assigned 24 Hz), 44 hidden coded pictures and 39 show-existing pictures.
These counts come from the resulting bitstream, not the source container's
declared frame count or the encoder's requested maximum. The AVIF animation is
remuxed from the same encoded AV1 payloads.

dav1d 1.2.1 supplies frame-major native Y/U/V references. libavif 0.11.1 decodes
the AVIF independently and must match every byte, including presentation order.
Each full decoder pass compares **156,155,904 native samples**. No native pixel
tolerance is used. Original inputs and expected pixels are preserved while bugs
exposed by this corpus are fixed.

The first failing region exposed three shared-chroma cases: inter luma missing
from a later CfL owner, an unaligned inter chroma residual origin, and a shared
group containing an intra neighbour. A later picture exposed the even/odd MI
selection in motion-variation eligibility. The independent decoder checks odd
MI positions, as does the actual OBMC blending path; inspecting even positions
consumed an extra entropy symbol and corrupted subsequent decoding. Primary
references are dav1d's
[reconstruction](https://github.com/videolan/dav1d/blob/1.2.1/src/recon_tmpl.c)
and [block syntax](https://github.com/videolan/dav1d/blob/1.2.1/src/decode.c).
The initial strict failure and reduced-region evidence remain in
`benchmarks/results/extensions-cfl-before.json`.

```sh
python scripts/generate-real-video-reference.py --check --redecode --dav1d <dav1d> --libavif <libavif-0.11.1-library>
python scripts/check-file-fixtures.py --manifest tests/fixtures/av1-realvideo/manifest.json --extensions --output benchmarks/results/extensions-realvideo.json
```

`--extensions` verifies temporal-unit Result decoding, arbitrary byte chunks,
and lazy AVIF animation. Animation verification includes reset, backward/forward
seeks, EOF and returned-frame ownership, with full native comparisons. Zero
`peak_slot_samples` in opaque stream/animation modes means reference slots are
not exposed to the harness; it is not a zero-memory claim. The raw decoder mode
continues to check its eight reference slots explicitly.
