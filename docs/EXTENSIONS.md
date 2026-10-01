# Caller APIs

The following additive APIs retain the existing unary `Option` entry points.
They use the same MoonBit reconstruction core and preserve the documented
native pixel and color conventions.

## Diagnosing a rejected input

`av1_decode_native_result`, `av1_decode_result`, `av1_decode_rgba16_result`,
`av1_video_decode_temporal_unit_native_result`, `avif_container_parse_result`,
`avif_decode_native_result`, `avif_decode_rgba_result` and
`avif_decode_rgba16_result` return `Result[T, DecodeError]`. All accept a labelled
`limits` policy; omission uses `DecodeLimits::default()`.

`DecodeError` provides `kind`, `context`, `message` and optional `byte_offset`.
Kinds distinguish invalid syntax/data, truncated input, explicitly unsupported
features, missing sequence/reference state, resource limits, invalid session
state, invalid output buffers and input with no presentation. An opaque entropy
failure remains `InvalidData`; it does not imply a diagnosed unsupported tool.
Messages and context are explanatory text, not stable machine identifiers.
Match `kind` for program logic.

Offsets identify a checked byte or the start of the failing payload, not an
exact entropy bit. Stream offsets are absolute `Int64` positions. Errors in
assembled AVIF item payloads or av1C prefixes may have no file offset. Successful
hidden-only video input returns `Ok([])`; a first-picture convenience API returns
`NoPresentation` when it has no displayed picture. An error in an AV1 video
operation can follow reference updates: discard that decoder, as with `None`
from the original API.

## Arbitrary AV1 byte chunks

`Av1StreamDecoder::new()` returns an owned session. `feed(chunk)` copies the
supplied bytes and returns an `Av1StreamBatch` with owned native frames and a
status: `NeedMoreInput`, `FramesReady` or `Finished`. Always consume `frames`,
including the batch returned by `finish()`.

Temporal delimiter OBUs close the previous temporal unit. Complete pictures
can wait for this boundary so that spatial-layer selection retains its existing
meaning. For input framed by an external demuxer, call `end_temporal_unit()` at
the actual boundary. Call `finish()` only at end of input; an incomplete header
or payload then becomes `TruncatedInput`. A terminal OBU without an explicit
size also needs an external boundary or end of input. This adapter accepts raw
low-overhead AV1 OBUs, not MP4, IVF or WebM container bytes.

`finish()` is idempotent; feeding after it is `InvalidState`. Errors are sticky
until `reset()`, which clears sequence/reference state and resets offsets.
Previously returned pixels remain owned and valid. `pending_bytes()` reports
retained compressed input, including up to 16 lookahead header bytes.
`max_input_bytes` bounds each supplied chunk and each complete temporal unit.
The reconstruction budget is shared by all units completed during one call.
Choose chunk sizes and work limits together: a feed containing many units can
exceed the per-call picture budget. A failed feed does not return its partial
batch; reset before reuse.

## AVIF metadata and display geometry

`avif_metadata(bytes)` reads the primary item's associated metadata without
decoding pixels. `AvifAnimationDecoder::metadata()` reads the selected picture
track's metadata and returns an independent copy. `AvifMetadata` contains owned
ICC, Exif and XMP byte buffers, optional pixel aspect ratio, the item/track ID,
and transform properties in association order.

Metadata extraction keeps ICC and XMP bytes opaque for callers to process.
XMP is not parsed as XML.
Exif omits the item's four-byte TIFF-offset field, and `exif_tiff_offset` locates
TIFF within the returned bytes. Item metadata follows `cdsc` associations to the
primary image; track `meta` descriptions belong to their track. Unsupported
protection or encoded XMP content returns `Unsupported`. Unknown essential
primary-item properties are rejected by this metadata API.

`display_size(width, height)`, `apply_rgba8(image)` and `apply_rgba16(image)`
explicitly apply the transform chain. Crops use exact rational `clap` values;
an integer crop is copied without resampling. Fractional raster origins/sizes
return `Unsupported`, while the original metadata remains readable. Rotation
uses anticlockwise quarter turns, and HEIF mirror mode 0 swaps top/bottom while
mode 1 swaps left/right. Channel values and alpha move together, unchanged.
Every result owns a new buffer, including an empty transform chain.

Ordinary decode APIs keep the stored raster orientation. These methods do not
automatically apply Exif orientation, pixel-aspect resampling, ICC conversion
or HDR tone mapping. Definitions follow the
[libavif 0.11.1 public metadata contract](https://github.com/AOMediaCodec/libavif/blob/v0.11.1/include/avif/avif.h).

## MP4, IVF and WebM video

`av1_demux` and the format-specific demuxers return owned AV1 packets and
original media timing. `Av1ContainerDecoder` combines these with lazy native
pixel reconstruction. Unknown timestamps remain optional; MP4 movie edits
remain separate from raw media PTS/DTS. See [VIDEO_CONTAINERS.md](VIDEO_CONTAINERS.md)
for packet ownership, limits, reset and scheduling contracts.

## Lazy AVIF animation

`AvifAnimationDecoder::new(bytes)` validates the container, sample envelopes,
constant sequence configuration and aligned color/alpha timelines. It copies
compressed input once and retains decoder references rather than all displayed
images. Entropy and pixel validity are checked as samples are consumed, so a
later error can follow previously delivered valid frames.

`next_frame()` returns `Ok(Some(frame))`, or `Ok(None)` at the end. `position()`
is the next sample index; `frame_count()` and `frame_timing(index)` describe the
track without decoding the remaining images. Timing uses exact primary-track
units and preserves variable durations.

`is_keyframe(index)` and `nearest_keyframe(index)` conservatively identify
independent sample boundaries shared by color and alpha. Only a selected,
shown key picture that is the sole coded picture of its sample qualifies.
`None` means seeking must replay from sample zero. `seek_frame(index)` returns
that frame and positions the next read at `index + 1`. Its entire replay shares
one reconstruction budget. A key-sample seek initializes sequence state before
decoding, including when that sample omits a repeated sequence header.

Each `next_frame()` has a fresh budget shared by color and alpha. The input-byte
limit covers the complete owned container; the per-operation frame limit does
not limit the animation's total length. A decode/seek failure is sticky until
`reset()`. Invalid index queries leave a healthy session unchanged. `reset()`
returns to sample zero. All returned frames survive advancing, seeking and
resetting; mutating them cannot alter reference pictures.

## Caller-owned output buffers

| Method | Stride and offset units | Values written |
| --- | --- | --- |
| `Av1NativeFrame::copy_plane_into(plane, dst, row_bytes, packing, offset=...)` | Bytes | Native Y/U/V (or G/B/R for matrix 0), retaining range and precision |
| Native frame/image `to_rgba16_into(dst, row_stride, offset=...)` | UInt16 channels | Straight RGBA UNORM16 |
| `Image16::copy_bytes_into(dst, row_bytes, big_endian=..., offset=...)` | Bytes | Serialized RGBA UNORM16 |

`PixelPacking::U8` requires 8-bit samples. `U16LE`/`U16BE` store unshifted
samples; `High16LE`/`High16BE` left-align native bits in a 16-bit word. These are
individual plane writes, not an interleaved NV12/P010 image layout. Serialized
RGBA16 retains the full UNORM16 channel values.

Rows may have padding. Prefixes, row padding and suffixes remain untouched.
Invalid dimensions, sample values, offsets, strides and capacities are checked
before writing. A later numerical color-conversion failure may leave partial
output; inspect the result before using it. Reuse removes the returned output
allocation, while normal decoder/reference allocations and validation remain.
It does not promise a zero-allocation decoder or a speedup on every backend.

The RGBA16 precision contract remains independent RGB error at most one UNORM16
step, with exact alpha. Some libavif premultiplied paths quantize before removing
premultiplication; saved references retain those separately, as explained in
[RGBA16.md](RGBA16.md).
