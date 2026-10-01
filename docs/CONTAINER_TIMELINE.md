# Container presentation timeline and seeking

`Av1ContainerDecoder` keeps the demuxed packet order and the raw media
timescale. `next_frame()` returns the next selected AV1 presentation and
`seek_timestamp(requested)` returns the first selected presentation encountered
in container decode order whose known packet PTS is at least the request:

- `Exact` means the PTS equals the request.
- `Next` means the PTS is later than the request. This is an at-or-after seek;
  `Next` does not claim that the stream contains a gap.
- `End` means no selected presentation at or after the request was found.
- `UnknownTimestamp` means the first selected presentation encountered for the
  seek has no PTS, so it cannot be compared with the request. The result still
  carries that decoded frame.

The result's `frame` is owned in the same way as a frame from `next_frame()`.
After `Exact`, `Next` or `UnknownTimestamp`, the decoder position is after the
returned packet, so `next_frame()` continues in normal decode order. `End`
leaves the position at packet EOF. `reset()` clears AV1 reference state and
sticky decode failures.

Seeking never sorts packet timestamps. If every packet has a known,
nondecreasing PTS, a seek may use container sync marks as candidate starts.
Every candidate is validated by decoding its actual AV1 payload with a fresh
decoder and requiring one selected presentation. Metadata-only and hidden-only
packets are conservatively excluded as starts; a sync flag by itself is not trusted. If a candidate cannot decode,
the implementation falls back to an earlier candidate. All candidate probes
and preroll packets share one `DecodeLimits` budget for that seek. Hidden
frames and show-existing operations therefore preserve the same reference
state and consume the same budget as ordinary sequential reads.

For non-reduced sequences, a candidate must also initialize all eight reference
slots from the fresh state. A displayed intra-only packet that leaves older
references missing is therefore not promoted to a seek point.

If a PTS is missing or known PTS values are nonmonotone, seeking performs a
conservative scan from packet zero in decode order. An unknown PTS is never
used to hide a known nonmonotone ordering.

## Explicit MP4 edits

`Av1ContainerDecoder::presentation_timeline()` and
`Av1PresentationTimeline::new(track)` expose MP4 presentation edits separately
from the decoder cursor. An empty edit list means raw media timing; the API
does not synthesize a default edit merely because `mvhd` has a movie
timescale.

`map_movie_time(movie_tick)` returns `Av1PresentationPoint::Empty` inside an
empty edit, `Media(Av1RationalTime)` inside a media edit, and `End` after the
last edit. Edit intervals are half-open, so an exact boundary belongs to the
next edit. Repeated media segments remain separate and are evaluated in their
stored order.
Movie ticks must be nonnegative, including the no-edit mapping. Negative raw
media PTS remains available directly from the decoder; it is not a valid movie
presentation tick for this mapping operation.

Media timestamps are represented as an exact rational with a positive
denominator. Mapping uses checked `Int64` multiplication and addition; no
rounding is performed at an edit boundary. Overflow is returned as a
`DecodeError`. The current MP4 demuxer emits unit-rate edits (`65536` in
signed 16.16 form), and the timeline accepts that rate while reporting other
rates as unsupported.
