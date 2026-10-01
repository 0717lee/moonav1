# Long AV1 container references

This corpus remuxes the existing licensed Big Buck Bunny AV1 stream from
`../av1-realvideo/bbb_8bit_512x288.obu`. It uses FFmpeg stream copy for all
video artifacts, so no video is re-encoded. The source is the 512×288,
8-bit 4:2:0, 706-presentation sequence documented by
`../av1-realvideo/README.md`; its CC BY 3.0 attribution and exact source hash
are copied into `manifest.json`. The immutable dav1d native planes remain in
`../av1-realvideo/bbb_8bit_512x288.reference.yuv`. This directory stores its
hash and one CRC32 per native frame rather than copying the 156 MB planes.

The generated files are:

- `bbb_long_8bit_512x288.ivf`: the complete long IVF stream.
- `bbb_long_8bit_512x288.faststart.mp4`: ordinary MP4 with `moov` before
  `mdat` and a 2.5-second edit-list presentation offset.
- `bbb_long_8bit_512x288.moov-tail.mp4`: ordinary MP4 with the index after
  media data and the same edit-list offset. A streaming first pass may finish
  with replay required; the manifest preserves the raw media timeline.
- `bbb_long_8bit_512x288.fragmented.mp4`: 29 `moof` fragments, with the
  2.5-second offset carried by patched `tfdt` base decode times.
- `bbb_long_8bit_512x288.webm`: long WebM with bounded one-second cluster
  targets.
- `bbb_long_8bit_512x288.multitrack.mp4`: interleaved MP4 with a synthetic
  440 Hz AAC track listed before the AV1 track. The audio is generated locally
  by FFmpeg's `lavfi` sine source and has no external media provenance; the
  AV1 track must be selected by codec identity.

Each artifact has a saved ffprobe JSON record. Packet records include stream
identity, PTS/DTS/duration, size, file position, flags, ffprobe's payload
SHA-256, and an independently computed CRC32. MP4 structure records include
top-level box order, edit-list entries, fragment count, and `tfdt` values.
`manifest.json` repeats the selected AV1 stream identity, timing arrays,
payload hashes/CRCs, full-file hash/size, exact source/tool/command records,
and the one-to-one packet-to-native-frame mapping. The packet timing arrays
are the raw media timeline; MP4 display-timeline probes are retained next to
the raw records so edit application remains explicit.

The corpus-level stream policy records `max_frames=768` (above the 706-frame
corpus), `max_input_bytes=65536`, `max_chunk_bytes=32768`, and the largest
selected AV1 packet bound. The compressed cap is materially below every full
artifact, while still admitting the largest packet plus initialization data.
The frame lifetime policy permits retaining returned native frames across
later frames, reset, and MP4 replay; every returned frame owns independent
planes. These values are metadata for the bounded stream consumer and do not
change the existing MoonBit tests.

```sh
python scripts/generate-long-container-reference.py
python scripts/generate-long-container-reference.py --check
```

`--check` is read-only: it does not run FFmpeg, write a temporary file, or
rewrite any fixture. It reopens the source and all artifacts, reruns ffprobe,
recomputes packet payload hashes and CRCs from ffprobe's data dump, validates
MP4 box structure and edit/fragment records, and checks the native mapping.
Generation refuses to run if the fixture directory contains an unknown file,
so it cannot overwrite an unrelated reference. No MoonBit consumer harness is
embedded here; the manifest is the handoff contract for the bounded stream
consumer.
