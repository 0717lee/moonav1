# AV1 MP4 demux

`av1_demux_mp4` reads an ISO Base Media File Format buffer and returns one
owned `Av1DemuxedTrack`. It selects the first video track whose sample entry is
`av01`, or the track identified by the optional `track_id` argument. Ordinary
sample tables (`stts`, `ctts`, `stsz`/`stz2`, `stsc`, `stco`/`co64`, and `stss`)
and common fragmented media (`tfhd`, `tfdt`, `trun`, and `trex` defaults) are
supported.

`ctts` and `trun` composition offsets are retained as generic ISO BMFF timing
extensions and contribute to raw PTS. The parser accepts them for this demux
API; that acceptance does not claim strict conformance to an AV1 binding or a
particular AOMedia random-access profile.

The retained [container fixture](https://github.com/0717lee/moonav1/blob/main/tests/fixtures/av1-containers/README.md)
contains both an ordinary MP4 and a fragmented MP4, each with eight copied
AV1 packets and eight presentations. The ordinary file keeps its edit metadata
separate from the raw media timeline; the fragmented file carries the same
2500-tick offset in its patched `tfdt` values.

Returned packets stay in decode order. `decode_timestamp`,
`presentation_timestamp`, and `duration` use the selected track's media
timescale and retain raw media values. MP4 packets always carry
`Some(presentation_timestamp)`; composition offsets from `ctts` and `trun`
are applied to that PTS. No movie edit is silently applied. The root
`Av1DemuxedTrack` also exposes `movie_timescale` and selected-track `edits` when
the file contains an edit list. An edit entry retains its movie duration,
raw-media start (`media_time`, with `-1` for an empty edit), and signed 16.16
unit rate. A caller can use the demuxed edit metadata to schedule presentation
while retaining coded preroll packets needed for AV1 references. The lazy
container decoder returns the raw media timeline and does not apply edits.

`codec_initialization` is the validated low-overhead OBU payload from the
`av1C` record, without the four-byte record header. It is prepended to the
first packet by `Av1ContainerDecoder` when a decoder is initialized.

The parser copies all sample bytes and checks every range against an `mdat`
box. `DecodeLimits.max_input_bytes`, `max_frames`, and `max_frame_pixels` are
enforced before allocation. Malformed box sizes, table count mismatches,
timestamp/offset overflow, truncated entries, and samples outside `mdat`
return a structured `DecodeError`.

Encrypted sample entries, external data references, sample-description
switches, non-unit edit rates, unsupported FullBox versions/flags, and
unsupported BMFF versions are reported as `Unsupported`. The implementation
keeps no runtime FFI or native dependency.

Fragmented files are accepted with explicit data bases, `default-base-is-moof`,
or a single-track implicit base. `duration-is-empty` and an implicit selected
track base that follows an unselected traf are rejected rather than guessing
sample bytes.

The AV1 sample-entry and `av1C` interpretation follows the
[AV1 Codec ISO Media File Format Binding v1.3.0](https://aomediacodec.github.io/av1-isobmff/v1.3.0.html),
especially its `AV1SampleEntry`, `AV1CodecConfigurationBox`, and AV1 sample
format definitions. Box and timing table layout follows ISO Base Media File
Format conventions.

This API demuxes MP4 bytes; IVF and WebM have separate demux entry points.

## Incremental MP4 and fMP4

Av1ContainerStream selects the MP4 backend when the input is hinted as
Mp4 or begins with an ISO BMFF signature. The backend parses complete
moov/moof metadata boxes while retaining only bounded sample descriptors.
mdat payloads are consumed by absolute file range, so a sample can be split
across feeds and is emitted as an owned Av1Packet as soon as its bytes are
available. The pending-byte metric covers the current compressed input and
retained compressed codec configuration. Expanded numeric sample descriptors,
allocator overhead, parser scratch copies, and already-emitted output are
excluded from that metric; `max_frames` bounds descriptor count separately. A
complete mdat is never retained.

Faststart files (metadata before media) can emit packets before finish().
Fragmented files use tfhd/tfdt/trun bases and preserve decode time across
moofs. Selected samples whose media ranges cannot be traversed in decode order
are rejected instead of being silently reordered.

When metadata is at the tail, the first pass consumes media without emitting
packets and ends with ReplayRequired. Call replay() and resend the exact
original bytes from offset zero; the retained metadata index is reused and
packets are then emitted while the media ranges are traversed. A tail pass
never retains or duplicates the skipped mdat bytes.
