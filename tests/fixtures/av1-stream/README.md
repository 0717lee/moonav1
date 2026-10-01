# HD and reordered sequence references

These original integer scenes extend the earlier [larger corpus](../av1-large-images/README.md).
They reuse its deterministic scene recipe and preserve every earlier artifact.
They are synthetic gradients, textured patches and motion, not photographs.

| Case | Format | Presentations | Additional coverage |
| --- | --- | --- | --- |
| `still_12bit_1280x720` | 1280×720, 12-bit 4:2:0 | 1 | HD raw AV1 and static AVIF |
| `reorder_10bit_320x180` | 320×180, 10-bit 4:2:0 | 32 | Inter references, hidden pictures, show-existing and partial bottom rows |

The video has one key picture and 31 inter pictures, including four hidden
pictures. Four show-existing headers present stored pictures in display order.
There are 32 temporal units and 32 presentations (1.28 seconds at 25 fps).
The fourth temporal unit is the unmodified five-byte show-existing input used
to isolate native output preparation in the benchmark.

## Independent pixels and source records

[The generator](../../../scripts/generate-stream-reference.py) uses FFmpeg
9.0.1 and libaom `3.14.1-147-gec0dedc1a2`, one encoder thread, CPU-used 6 and
CRF 32. The still uses a reduced still header; the video uses 16-frame lookahead
and otherwise default coding-tool settings. The AVIF remux preserves the AV1
payload. [The manifest](manifest.json) records commands, tool versions, actual
header fields, presentation evidence and artifact hashes.

dav1d 1.2.1 supplies every native reference sample. libavif 0.11.1 independently
decodes the static AVIF, checking both planes and metadata. Expected pixels
are the lossy stream's decoded samples, not the encoder input. References are
frame-major, then Y/U/V, with tight rows of little-endian uint16 values at the
original precision. Actual CICP is `(2, 2, 1)`, limited range. Requested encoder
flags are not substituted for the signaled metadata.

The consumer checks all 4,147,200 native samples across the 33 presentations
with zero tolerance. Its generated source expands only the requested frame;
32,768-sample source chunks keep individual functions below compiler limits.
Chunking is lossless serialization, not sampled verification or hash comparison.

```sh
python scripts/generate-stream-reference.py --check
python scripts/generate-stream-reference.py --check --redecode --libavif /path/to/avif.dll
moon run benchmarks/stream --release --target js -- --verify-only
moon test benchmarks/stream --target wasm-gc
```

`--check` never writes saved files. `--embed-only` refreshes consumer source
from the saved reference bytes. Initial generation requires `--libavif` and
refuses to overwrite an existing manifest. Ordinary Moon tests need no external
codec. These references add HD and a longer reordered sequence; they do not
establish 4K, photographic, sustained long-video or malformed-input coverage.
