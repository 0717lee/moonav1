# AV1 container demux references

`reorder_prefix8_10bit_320x180.obu` is a byte-for-byte prefix of the existing
`tests/fixtures/av1-stream/reorder_10bit_320x180.obu`. It ends after eight
packets, so the sequence header and all references needed by those packets
remain intact. The original trace records hidden coded frames and
show-existing presentations inside temporal-unit packets; each container still
has eight packets and eight presentations. Those decoder events are not extra
container pictures, so this corpus must not count them as extra pictures.
Native frame CRCs reuse the existing immutable dav1d `.reference.yuv` file and
do not regenerate or modify that corpus.

The generator remuxes this prefix with FFmpeg into ordinary IVF, ordinary MP4,
fragmented MP4, and WebM. The four files use a 2500-tick
presentation offset. FFmpeg's `empty_moov` fragmented MP4 muxer normalizes its
initial `tfdt` to zero, so the generator applies one deterministic post-remux
operation: add 2500 to every `tfdt` base decode time. The manifest records the
exact FFmpeg commands, packet sizes, timestamps, data SHA-256 values and final
file hashes. Packet payloads are read with `ffprobe -show_packets -show_data`,
checked against ffprobe's SHA-256 and then checked with an independent CRC32.
`ffprobe` is rerun by the read-only check to confirm the saved records.
The generated MoonBit tests compare demuxed packet CRCs and media timing,
then consume all eight presentations through `Av1ContainerDecoder`, checking
native CRCs, packet indices, reset behavior, and returned-frame ownership.
Packet CRCs use a local ISO-HDLC implementation in the generated test so
validation does not depend on the private checksum helper used by existing
whitebox fixtures. A separate CFR OBU is produced by FFmpeg with
`av1_metadata=tick_rate=50:num_ticks_per_picture=2`; its sequence metadata and
native output exercise the equal-picture-interval and UVLC regression path.

```sh
python scripts/generate-container-reference.py
python scripts/generate-container-reference.py --check
```

The check does not run FFmpeg or write a temporary output. It reopens the
existing files, compares their hashes and ffprobe packet records, validates the
native reference CRCs against the unchanged AV1 stream corpus, and checks the
generated `container_reference_test.mbt` source. The MoonBit source embeds only
the small eight-packet prefix, its CFR variant, and four remuxed files; it does not embed the
multi-megabyte native reference planes.

For ordinary MP4 the primary ffprobe record is collected with
`-ignore_editlist 1`, so packet PTS/DTS are the raw media timeline consumed by
the demuxer. A display-timeline ffprobe record is retained separately and
shows the 2500-tick edit-list offset. Fragmented MP4 has no edit list; its
patched `tfdt` directly carries the offset.

The source sequence is project-owned synthetic material and has no external
media license. FFmpeg and ffprobe version strings are retained in
`manifest.json`; no external decoder or host container API is used by the
library tests.
