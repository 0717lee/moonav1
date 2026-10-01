# AV1 WebM/Matroska demux

`av1_demux_webm` reads a WebM or Matroska byte array and returns an owned
`Av1DemuxedTrack`. The selected track is a Matroska `TrackNumber`; when no
track is supplied, the first video `TrackEntry` whose `CodecID` is exactly
`V_AV1` is selected.

The result has `timescale = 1_000_000_000`, so every known timestamp and
duration is in nanoseconds. A packet whose timing cannot be derived has
`presentation_timestamp = None`; this is distinct from a timestamp of zero.
Packet data is copied from the input. `codec_initialization`
is the validated AV1 initialization OBU sequence from the `av1C`
`CodecPrivate` record, without the four-byte record header.

The retained [container fixture](https://github.com/0717lee/moonav1/blob/main/tests/fixtures/av1-containers/README.md)
is an FFmpeg-produced WebM with eight copied AV1 packets and eight
presentations. Its packet payload hashes are checked from `ffprobe` data, while
the native output is compared with the immutable dav1d reference; hidden coded
frames and show-existing events remain inside temporal units.

## Container model

The implementation follows the EBML VINT rules and the Matroska element
hierarchy. It accepts a finite or unknown-sized `Segment` and finite or
unknown-sized `Cluster` elements. An unknown-sized Cluster ends at the next
known Segment-level sibling (including the next Cluster) or the end of the
Segment; global `Void` and CRC elements do not end it. Nested unknown-sized
elements are rejected because their boundary cannot be recovered safely
without a complete schema-level walk.

EBML header declarations use RFC defaults when omitted: version/read version
1, maximum ID length 4, maximum size length 8, and DocType version/read
version 1. The DocType remains required, and a declared DocTypeReadVersion
above DocTypeVersion is rejected.

After a finite Segment, only finite global Void or CRC elements are accepted;
additional Segment elements are unsupported and other trailing bytes are
invalid. An unknown-sized Segment consumes the remainder of the input.

The parser reads `Info\TimestampScale` (default `1_000_000`), `Tracks`,
`TrackEntry\Video\PixelWidth/PixelHeight`, `DefaultDuration`, `CodecDelay`,
`FlagLacing`, and `CodecPrivate`. Track and pixel limits are applied before
packet buffers are assembled. `ContentEncodings` and non-unit
`TrackTimestampScale` are reported as unsupported instead of being ignored.
The TrackEntry pixel dimensions must equal the AV1 Sequence Header's maximum
frame dimensions carried by `CodecPrivate`.

For each `SimpleBlock` or `BlockGroup\Block`, the block timecode is decoded as
a signed 16-bit integer and added to the Cluster timestamp. The product with
`TimestampScale` is checked for `Int64` overflow. `CodecDelay`, when present,
is subtracted from a known presentation timestamp as required by Matroska. The
container does not carry a decode timestamp, so `Av1Packet.decode_timestamp`
remains `None`; CodecDelay is not treated as DTS.

`SimpleBlock` keyframe flags become `sync_sample`. A BlockGroup without a
`ReferenceBlock` is a random-access packet; any `ReferenceBlock`, including
the value zero used by intra-only AV1 frames, marks the packet as dependent.
The AV1-specific requirement that a keyframe contain a Sequence Header OBU
and a keyframe Frame OBU remains the decoder's responsibility.

Xiph, fixed-size, and EBML lacing are decoded with explicit frame bounds.
Lacing must contain at least two frames and is rejected when the track's
`FlagLacing` is false. When `DefaultDuration` is available, laced frame PTS
values advance by that duration. A `BlockDuration` is retained even when
`DefaultDuration` exists, with the final frame receiving the exact remainder;
contradictory totals are rejected. If neither source
supplies an exact per-frame duration, only the first laced frame retains the
Block timestamp; later frame PTS values and durations remain unknown.

## Limits and failures

`max_input_bytes` applies to the complete container. `max_frames` counts
selected packet frames after lacing expansion. `max_frame_pixels` is checked
against the selected TrackEntry's luma dimensions. Malformed VINTs, duplicate
required fields, invalid block flags, unknown track references, truncated
elements, invalid lacing, arithmetic overflow, unsupported compression or
encryption, and missing AV1 initialization data return a classified
`DecodeError`.

The demuxer does not call a filesystem, browser codec, FFmpeg, libaom, dav1d,
or libavif. It only exposes encoded AV1 temporal units; use
`Av1StreamDecoder` or the video decoder to consume the packet payloads.

## Incremental container stream

`Av1ContainerStream` accepts WebM input in arbitrary byte chunks. It consumes
complete EBML headers, `Info`, `Tracks`, and block elements as soon as their
declared bytes arrive, so a finite or unknown-sized `Cluster` does not have to
be buffered through its end before packets become available. Packet payloads
are copied before the source chunk is released. Laced frames are queued as
owned packets and count toward `max_frames`. Queued payloads count toward
`max_input_bytes` until delivered in a returned batch; output retained by the
caller is outside that pending-input metric. See the shared
[ownership and resource contract](CONTAINER_STREAMING.md).

The streaming path keeps the batch parser's track selection, AV1 `CodecPrivate`
validation, dimension checks, lacing rules, timestamp scaling, `CodecDelay`,
`ReferenceBlock`, duplicate singleton checks, and finite-segment tail rules.
It requires `Info` and `Tracks` before the first `Cluster`, and requires a
Cluster `Timestamp` before each selected block. A block arriving before its
timestamp returns `Unsupported`; the stream never guesses a default cluster
timestamp or retains an unbounded block backlog. Unknown-sized Clusters end at
the next known Segment-level sibling (`Void` and CRC remain inside the
Cluster), while unknown-sized nested elements are rejected. Replay is not used
for WebM.

## Normative references

The element IDs, timestamp formula, Block/BlockGroup structure, lacing modes,
and ReferenceBlock random-access rules are taken from the current Matroska
specification:

- [Matroska codec mappings, including `V_AV1`](https://www.matroska.org/technical/codec_specs.html#v_av1)
- [Matroska element definitions](https://www.matroska.org/technical/elements.html)
- [Matroska notes: Block structure, lacing, and timestamps](https://www.matroska.org/technical/notes.html)
- [Matroska specification](https://ietf-wg-cellar.github.io/matroska-specification/)
- [EBML specification](https://github.com/ietf-wg-cellar/ebml-specification/blob/master/specification.markdown)
- [AV1 Codec ISO Media File Format Binding, `av1C`](https://aomediacodec.github.io/av1-isobmff/v1.3.0.html#av1codecconfigurationbox)
- [libvpx project documentation](https://chromium.googlesource.com/webm/libvpx/+/refs/heads/main/README)
