# AV1 video containers

`av1_demux(bytes)` detects IVF, MP4 or WebM/Matroska from the file header.
Use `format=Some(Ivf/Mp4/WebM)` to select explicitly, or call
`av1_demux_ivf`, `av1_demux_mp4` or `av1_demux_webm` directly. The input is a
complete file buffer. This is a container parser, not a network byte-stream
adapter. For chunked input, use the separate
[`Av1ContainerStream` / `Av1ContainerStreamDecoder` contract](CONTAINER_STREAMING.md).
Only AV1 video is selected; audio is not decoded.

The result owns its encoded packets and initialization OBUs. It does not
alias the supplied byte array. Packets stay in container decode order; sorting
by presentation timestamp before decoding would break AV1 references.

The independent [container corpus](https://github.com/0717lee/moonav1/blob/main/tests/fixtures/av1-containers/README.md)
contains actual FFmpeg-produced IVF, ordinary MP4, fragmented MP4 and WebM
files. Each file has eight temporal-unit packets and eight presentations. The
source trace includes hidden coded frames and show-existing events inside those
temporal units; they are decoder events, not extra container packets, so the
corpus must not count them as extra pictures. Packet payloads are extracted
with `ffprobe -show_packets -show_data`, checked against the reported SHA-256
and then checked again with an independent CRC32 in the generated tests. The
native expected output reuses the immutable original dav1d eight-frame CRC
reference. A companion CFR stream produced with FFmpeg's
`av1_metadata=tick_rate=50:num_ticks_per_picture=2` bitstream filter exercises
the equal-picture-interval and UVLC regression path.

| Field | Meaning |
| --- | --- |
| `track_id` | MP4 track ID, Matroska TrackNumber, or zero for IVF |
| `width`, `height` | Container-declared raster dimensions; decoded frames carry their own dimensions |
| `timescale` | Ticks per second for packet timing |
| `codec_initialization` | Validated av1C configuration OBUs with the four-byte record header removed; empty for IVF |
| `packets[].data` | One encoded AV1 temporal unit, copied from the container |
| `presentation_timestamp` | Original media PTS, or `None` when the container does not determine it |
| `decode_timestamp` | MP4 media DTS; `None` for IVF/WebM |
| `duration` | Known packet duration in track ticks, otherwise `None` |
| `sync_sample` | Container's sync flag if available, not an independently proven seek point |
| `movie_timescale`, `edits` | MP4 movie edit metadata, separate from raw media packet times |

IVF carries a rational time base `scale/rate`. The demuxer returns
`timescale=rate` and `PTS=stored_timestamp*scale`, checking signed Int64
overflow. It does not invent DTS, duration or keyframe flags. A nonzero
declared packet count must match the records; zero means unspecified.
Header extensions are skipped according to the declared header length.

MP4 PTS includes composition offsets; movie edits are retained separately so
that preroll/reference samples remain available. Edit duration uses movie
ticks, `media_time` uses media ticks (`-1` is an empty edit), and `media_rate`
is signed 16.16. WebM uses nanosecond ticks, including TimestampScale and
CodecDelay. Later frames of a lace can have unknown timing. See the detailed
[MP4](MP4.md) and [WebM](WEBM.md) support contracts.

## Decode one presentation at a time

```moonbit
let decoder = @moonav1.Av1ContainerDecoder::new(bytes).unwrap()
while decoder.next_frame().unwrap() is Some(presentation) {
  let pixels = presentation.frame.to_rgba16().unwrap()
  // Consume pixels and optional presentation.timestamp in presentation.timescale.
  ignore(pixels)
}
```

Construction checks container structure and copies compressed packets.
`next_frame()` reconstructs lazily, prepending initialization to the first
packet. Hidden pictures update references without producing a result. Each
returned `Av1ContainerFrame` contains the packet index, optional media PTS and
duration, timescale, and owned native 8/10/12-bit pixels. A packet may contain
hidden coded pictures plus at most one selected presentation. Multiple selected
presentations in a single packet are rejected. EOF is `Ok(None)` and is
idempotent; `position()` reports the next encoded packet index.

Errors are sticky until `reset()`. Reset reinitializes AV1 references and
replays from the first packet; it does not invalidate previously returned
frames. Entropy failures may occur after earlier valid frames were returned.
Packet errors identify their packet index in the message; their byte offset
is absent because copied initialization/sample bytes are not a contiguous file
range. This cursor returns the raw media timeline. Its `seek_timestamp` and
`presentation_timeline` methods provide [checked at-or-after seeking and
explicit movie-edit mapping](CONTAINER_TIMELINE.md).

`DecodeLimits.max_input_bytes` bounds the complete file; `max_frames` bounds
the number of selected encoded packets, including expanded lace frames.
`max_frame_pixels` bounds declared dimensions. Every `next_frame()` then has
a reconstruction budget shared by all hidden and displayed pictures consumed
in that call. Set a larger packet-count limit for long files; pixel work
remains bounded per call. Limits are work/input bounds, not exact heap limits.

The demuxers use the same pure MoonBit reconstruction core and no host media
fallback. [Independent container references](https://github.com/0717lee/moonav1/blob/main/tests/fixtures/av1-containers/README.md)
retain ffprobe packet/timing output and dav1d native-picture checks.

Primary format references include the [AV1 Codec ISO Media File Format
Binding](https://aomediacodec.github.io/av1-isobmff/v1.3.0.html), the
[Matroska specification](https://ietf-wg-cellar.github.io/matroska-specification/),
and the [libvpx project documentation](https://chromium.googlesource.com/webm/libvpx/+/refs/heads/main/README).
