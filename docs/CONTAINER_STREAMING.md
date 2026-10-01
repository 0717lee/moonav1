# Incremental AV1 containers

`Av1ContainerStream` demuxes IVF, MP4/fMP4 and WebM/Matroska byte chunks.
`Av1ContainerStreamDecoder` connects that parser to the pure MoonBit native
8/10/12-bit decoder. Both accept an optional format hint, track ID and
`DecodeLimits`; neither performs file, network or host-codec I/O.

Use `feed(chunk)` while bytes arrive and `finish()` only at actual EOF.
An empty feed does not signal EOF. The returned batch has owned `packets` or
`frames` and one status:

| Status | Caller action |
| --- | --- |
| `NeedMoreInput` | Supply another chunk; no complete selected output is available yet |
| `Ready` | Consume the batch, then continue feeding |
| `ReplayRequired` | Tail MP4 metadata is complete; call `replay()` and resend the same file from byte zero |
| `Finished` | Consume the last batch; no further input is needed |

`finish()` is idempotent after a terminal status and returns an empty batch on
later calls. Parser and reconstruction errors are sticky until `reset()`.
Lifecycle misuse, such as feeding after `ReplayRequired`, returns
`InvalidState` without destroying a healthy retained index. `reset()` clears
input, metadata, counts, failures and AV1 reference state, while preserving
the constructor's format, track and resource policy.

## Ownership and limits

Input chunks may be changed or released after `feed` returns. Returned packet
payloads, frame planes and metadata arrays do not alias caller input or decoder
reference state. They remain valid after subsequent feeds, replay and reset.
The caller controls how many output batches it retains.

`max_input_bytes` bounds each supplied chunk and the logical pending compressed
bytes: unconsumed input, retained codec configuration and queued packet payloads.
An entire file can exceed this cap. `pending_bytes()` reports the current
amount; `peak_pending_bytes()` is its high-water mark since reset, including
both passes of an MP4 replay. `bytes_received()` and `packet_count()` on the
demux stream restart for each replay pass.

This is not an exact process-heap limit. Expanded numeric descriptors, array
capacity, temporary parser copies, AV1 reference pictures and already-returned
output are additional. `max_frames` separately bounds the stream's total
selected packet count and expanded sample descriptors. `max_frame_pixels`
bounds declared and decoded dimensions. Every decoder `feed` or `finish`
shares one reconstruction budget across its packets, including hidden pictures
and show-existing operations. Its `max_total_pixels` and `max_frames` work
limits restart on the next call. A smaller chunk can therefore lower work per
call; callers must still choose a packet limit large enough for the file.

Each retained metadata unit or encoded packet must fit the compressed cap.
IVF records include their 12-byte record header. MP4 `moov`/`moof` metadata and
WebM headers, `Info`, `Tracks`, blocks and finite skipped elements are complete
bounded units; selected media is released as packets become available. A large
MP4 `mdat` and a WebM Cluster do not require whole-body buffering. A sample
plus codec initialization must also fit when first initializing AV1 decoding.

## Format behavior

IVF preserves its `scale/rate` time base and checked signed Int64 PTS. Its
declared packet count, when nonzero, must match at EOF.

MP4 traverses selected sample offsets in decode order. Faststart and ordinary
fMP4 can produce packets before EOF. A tail `moov` requires two passes: media
is discarded on the first pass, the bounded index is retained, and the same
source is replayed to supply payloads. A non-seekable host must arrange that
replay itself or provide metadata before media. Numeric descriptors are bounded
by `max_frames`; compressed media is not spooled. Size-zero metadata is parsed
at EOF under the same cap. Unsupported sample-order/base combinations are
reported explicitly; see [MP4](MP4.md).

WebM requires `Info` and `Tracks` before Cluster data and Cluster Timestamp
before a selected block. It does not retain an unbounded backlog for reordered
metadata. Finite and unknown-size Clusters support early output; unknown
Clusters stop at a known Segment sibling. Lacing, CodecDelay and missing times
retain the [WebM contract](WEBM.md). The current EBML parser uses signed-Int
local element endpoints; a finite declared span beyond that bound returns
`LimitExceeded`. Replay is not used for WebM.

Packets remain in decode order. Known timestamps and duration remain in raw
media ticks, with unknown values preserved as `None`. Hidden pictures update
references without a returned frame; at most one selected presentation per
container packet is supported. Use the whole-file cursor's
[checked seeking and explicit movie timeline](CONTAINER_TIMELINE.md) when random
access is needed. The incremental reader does not invent a file seek operation.

## Executable evidence

The [public example](../examples/containers/main.mbt) decodes the same IVF input
through complete-file and chunked APIs, and seeks to its presentation timestamp.
It runs on all three supported backends.

```sh
moon run examples/containers --target js
moon test av1_container_stream_wbtest.mbt av1_mp4_stream_wbtest.mbt av1_webm_stream_wbtest.mbt --target js
```

The regressions cover split headers, early output, tail-index MP4 replay,
resource limits, reset, error states and buffer ownership. The separate
[container corpus](https://github.com/0717lee/moonav1/blob/main/tests/fixtures/av1-containers/README.md) checks complete-file
packet timing and pixel CRCs against ffprobe and dav1d.
