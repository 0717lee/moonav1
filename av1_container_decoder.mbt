///|
/// A presentation and its original container time, expressed in timescale
/// ticks. packet_index identifies the encoded sample; packets without a
/// presentation are consumed but do not produce a frame.
pub struct Av1ContainerFrame {
  packet_index : Int
  timestamp : Int64?
  duration : Int64?
  timescale : Int64
  frame : Av1NativeFrame
}

///|
/// Result classification for a timestamp seek. `Next` means the selected
/// presentation is the first one in container decode order whose known PTS is
/// later than the request; it does not assert that the media has a gap.
pub(all) enum Av1ContainerSeekOutcome {
  Exact
  Next
  End
  UnknownTimestamp
} derive(Eq, Debug)

///|
/// A timestamp seek result. `frame` is present for `Exact`, `Next` and
/// `UnknownTimestamp`; `End` has no frame. Timestamps use the track's raw
/// media timescale. MP4 edit lists are applied only through the explicit
/// `Av1PresentationTimeline` API.
pub struct Av1ContainerSeekResult {
  requested_timestamp : Int64
  outcome : Av1ContainerSeekOutcome
  frame : Av1ContainerFrame?
}

///|
/// Owned compressed packets with lazy pixel reconstruction. Container tables
/// are checked at construction, while AV1 syntax/entropy failures may occur
/// later. Such failures remain sticky until reset(). Existing frames survive
/// advancing, reset and destruction of this session.
pub struct Av1ContainerDecoder {
  priv track : Av1DemuxedTrack
  priv limits : DecodeLimits
  priv mut decoder : Av1VideoDecoder
  priv mut next_index : Int
  priv mut failure : DecodeError?
  // A true entry means the packet was decoded successfully by a fresh AV1
  // decoder and is safe as a random-access start. A candidate is decoded
  // again when selected so that the fresh decoder state is restored without
  // sharing mutable reference slots between seeks.
  priv verified_random_access : Array[Bool]
}

///|
pub fn Av1ContainerDecoder::new(
  data : Array[Byte],
  format? : Av1ContainerFormat? = None,
  track_id? : Int64? = None,
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[Av1ContainerDecoder, DecodeError] {
  let track = match av1_demux(data, format~, track_id~, limits~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    track,
    limits,
    decoder: av1_video_decoder(),
    next_index: 0,
    failure: None,
    verified_random_access: Array::make(track.packets.length(), false),
  })
}

///|
pub fn Av1ContainerDecoder::format(
  self : Av1ContainerDecoder,
) -> Av1ContainerFormat {
  self.track.format
}

///|
pub fn Av1ContainerDecoder::timescale(self : Av1ContainerDecoder) -> Int64 {
  self.track.timescale
}

///|
/// Return the explicit presentation mapping for this track. The decoder's
/// default `next_frame`/`seek_timestamp` APIs continue to expose raw media
/// timestamps; callers opt into MP4 edits through this value.
pub fn Av1ContainerDecoder::presentation_timeline(
  self : Av1ContainerDecoder,
) -> Result[Av1PresentationTimeline, DecodeError] {
  Av1PresentationTimeline::new(self.track)
}

///|
pub fn Av1ContainerDecoder::packet_count(self : Av1ContainerDecoder) -> Int {
  self.track.packets.length()
}

///|
/// Index of the next encoded packet, not a count of displayed pictures.
pub fn Av1ContainerDecoder::position(self : Av1ContainerDecoder) -> Int {
  self.next_index
}

///|
pub fn Av1ContainerDecoder::reset(self : Av1ContainerDecoder) -> Unit {
  self.decoder = av1_video_decoder()
  self.next_index = 0
  self.failure = None
}

///|
fn Av1ContainerDecoder::record_failure_at(
  self : Av1ContainerDecoder,
  index : Int,
  error : DecodeError,
) -> Result[Av1ContainerFrame?, DecodeError] {
  // An OBU offset is relative to a copied/assembled packet, not the file.
  let failure = {
    ..error,
    byte_offset: None,
    context: "container.packet/" + error.context,
    message: "Packet \{index}: \{error.message}",
  }
  self.failure = Some(failure)
  Err(failure)
}

///|
fn Av1ContainerDecoder::record_seek_failure(
  self : Av1ContainerDecoder,
  index : Int,
  error : DecodeError,
) -> Result[Av1ContainerSeekResult, DecodeError] {
  let failure = {
    ..error,
    byte_offset: None,
    context: "container.packet/" + error.context,
    message: "Packet \{index}: \{error.message}",
  }
  self.failure = Some(failure)
  Err(failure)
}

///|
fn Av1ContainerDecoder::record_failure(
  self : Av1ContainerDecoder,
  error : DecodeError,
) -> Result[Av1ContainerFrame?, DecodeError] {
  self.record_failure_at(self.next_index, error)
}

///|
/// Assemble and decode one owned container packet. The caller supplies the
/// decoder and budget so seek candidate validation and replay can share one
/// mutable reference state and one DecodeLimits budget.
fn av1_container_decode_packet(
  track : Av1DemuxedTrack,
  limits : DecodeLimits,
  decoder : Av1VideoDecoder,
  index : Int,
  budget : DecodeBudget,
  fresh? : Bool = false,
) -> Result[Array[Av1FramePlanes], DecodeError] {
  if index < 0 || index >= track.packets.length() {
    return Err(
      decode_error(
        InvalidState,
        "container.seek",
        "Packet index is outside the track",
      ),
    )
  }
  // Failed random-access probes share work counters with fallback decoding,
  // but their diagnostic must not mask a later MissingReference/LimitExceeded.
  if budget.diagnostic is Some(trace) {
    trace.error = None
    trace.context = "container.packet"
    trace.byte_offset = None
  }
  let packet = track.packets[index]
  let prefix = if index == 0 || fresh { track.codec_initialization } else { [] }
  if packet.data.length() > limits.max_input_bytes ||
    prefix.length() > limits.max_input_bytes - packet.data.length() {
    return Err(
      decode_error(
        LimitExceeded,
        "payload",
        "Initialization and sample exceed max_input_bytes",
      ),
    )
  }
  let sample = if prefix.is_empty() {
    packet.data
  } else {
    Array::makei(prefix.length() + packet.data.length(), i => {
      if i < prefix.length() {
        prefix[i]
      } else {
        packet.data[i - prefix.length()]
      }
    })
  }
  match
    av1_video_decode_temporal_unit_planes(
      decoder,
      sample,
      allow_monochrome=true,
      budget=Some(budget),
    ) {
    Some(value) => Ok(value)
    None => Err(decode_failure(budget))
  }
}

///|
/// Try a sync-marked packet (or packet zero) with an independent decoder.
/// A syntax/reference rejection only disqualifies this candidate; a resource
/// limit aborts the seek because the same budget must cover every attempt.
fn Av1ContainerDecoder::check_random_access(
  self : Av1ContainerDecoder,
  index : Int,
  budget : DecodeBudget,
) -> Result[(Bool, Av1VideoDecoder?, Array[Av1FramePlanes]), DecodeError] {
  let probe = av1_video_decoder()
  let decoded = match
    av1_container_decode_packet(
      self.track,
      self.limits,
      probe,
      index,
      budget,
      fresh=true,
    ) {
    Ok(value) => value
    Err(error) => {
      if error.kind == LimitExceeded {
        return Err(error)
      }
      return Ok((false, None, []))
    }
  }
  // A metadata-only or hidden-only successful parse does not by itself prove
  // a usable independent reference state. Fall back to an earlier candidate.
  if decoded.length() != 1 {
    return Ok((false, None, []))
  }
  let standalone = probe.sequence
    is Some({ reduced_still_picture_header: true, .. })
  if !standalone {
    for slot in 0..<av1_num_ref_frames {
      if !probe.map.valid[slot] || probe.map.slots[slot] is None {
        return Ok((false, None, []))
      }
    }
  }
  self.verified_random_access[index] = true
  Ok((true, Some(probe), decoded))
}

///|
fn Av1ContainerDecoder::previous_candidate(
  self : Av1ContainerDecoder,
  before : Int,
) -> Int? {
  let mut index = before
  while index >= 0 {
    if index == 0 ||
      self.track.packets[index].sync_sample == Some(true) ||
      self.verified_random_access[index] {
      return Some(index)
    }
    index -= 1
  }
  None
}

///|
fn av1_container_frame(
  track : Av1DemuxedTrack,
  index : Int,
  planes : Av1FramePlanes,
) -> Av1ContainerFrame {
  let packet = track.packets[index]
  {
    packet_index: index,
    timestamp: packet.presentation_timestamp,
    duration: packet.duration,
    timescale: track.timescale,
    frame: av1_frame_to_native(planes),
  }
}

///|
fn av1_container_seek_result(
  requested : Int64,
  track : Av1DemuxedTrack,
  index : Int,
  planes : Av1FramePlanes,
) -> Av1ContainerSeekResult {
  let timestamp = track.packets[index].presentation_timestamp
  let outcome = match timestamp {
    Some(value) => if value == requested { Exact } else { Next }
    None => UnknownTimestamp
  }
  {
    requested_timestamp: requested,
    outcome,
    frame: Some(av1_container_frame(track, index, planes)),
  }
}

///|
/// Scan from a clean reference state in decode order. This path is required
/// for unknown or non-monotone packet timing; sorting PTS values would change
/// the AV1 dependency order and would misclassify a known non-monotone track.
fn Av1ContainerDecoder::seek_from_start(
  self : Av1ContainerDecoder,
  requested : Int64,
  budget : DecodeBudget,
) -> Result[Av1ContainerSeekResult, DecodeError] {
  self.decoder = av1_video_decoder()
  self.next_index = 0
  while self.next_index < self.track.packets.length() {
    let index = self.next_index
    let displayed = match
      av1_container_decode_packet(
        self.track,
        self.limits,
        self.decoder,
        index,
        budget,
      ) {
      Ok(value) => value
      Err(error) => return self.record_seek_failure(index, error)
    }
    self.next_index = index + 1
    if displayed.length() > 1 {
      return self.record_seek_failure(
        index,
        decode_error(
          InvalidData,
          "presentation",
          "A container sample has multiple selected presentations",
        ),
      )
    }
    if displayed.length() == 1 {
      let timestamp = self.track.packets[index].presentation_timestamp
      match timestamp {
        None =>
          return Ok({
            requested_timestamp: requested,
            outcome: UnknownTimestamp,
            frame: Some(av1_container_frame(self.track, index, displayed[0])),
          })
        Some(value) =>
          if value >= requested {
            return Ok(
              av1_container_seek_result(
                requested,
                self.track,
                index,
                displayed[0],
              ),
            )
          }
      }
    }
  }
  Ok({ requested_timestamp: requested, outcome: End, frame: None, })
}

///|
/// Seek on a track whose packet timestamps are all known and nondecreasing.
/// The target is located in packet order, then replay begins at the nearest
/// independently decoded sync candidate. Every candidate probe and replay
/// operation consumes the supplied single budget.
fn Av1ContainerDecoder::seek_ascending(
  self : Av1ContainerDecoder,
  requested : Int64,
  budget : DecodeBudget,
) -> Result[Av1ContainerSeekResult, DecodeError] {
  let mut target = self.track.packets.length()
  for index in 0..<self.track.packets.length() {
    match self.track.packets[index].presentation_timestamp {
      Some(value) =>
        if value >= requested {
          target = index
          break
        }
      None => return self.seek_from_start(requested, budget)
    }
  }
  if target == self.track.packets.length() {
    self.decoder = av1_video_decoder()
    self.next_index = self.track.packets.length()
    return Ok({ requested_timestamp: requested, outcome: End, frame: None, })
  }
  let mut candidate = self.previous_candidate(target)
  let mut accepted : (Int, Av1VideoDecoder, Array[Av1FramePlanes])? = None
  while candidate is Some(index) {
    let checked = match self.check_random_access(index, budget) {
      Ok(value) => value
      Err(error) => return self.record_seek_failure(index, error)
    }
    if checked.0 {
      accepted = Some((index, checked.1.unwrap(), checked.2))
      break
    }
    candidate = self.previous_candidate(index - 1)
  }
  let (start, decoder, first) = match accepted {
    Some(value) => value
    None =>
      // Packet zero is always the final fallback. A failure here is replayed
      // through the normal path so its diagnostic becomes sticky and exact.
      return self.seek_from_start(requested, budget)
  }
  self.decoder = decoder
  self.next_index = start
  let mut displayed = first
  let mut index = start
  while index < self.track.packets.length() {
    if index != start {
      displayed = match
        av1_container_decode_packet(
          self.track,
          self.limits,
          self.decoder,
          index,
          budget,
        ) {
        Ok(value) => value
        Err(error) => return self.record_seek_failure(index, error)
      }
    }
    self.next_index = index + 1
    if displayed.length() > 1 {
      return self.record_seek_failure(
        index,
        decode_error(
          InvalidData,
          "presentation",
          "A container sample has multiple selected presentations",
        ),
      )
    }
    if displayed.length() == 1 {
      let timestamp = self.track.packets[index].presentation_timestamp
      match timestamp {
        Some(value) =>
          if value >= requested {
            return Ok(
              av1_container_seek_result(
                requested,
                self.track,
                index,
                displayed[0],
              ),
            )
          }
        None => return self.seek_from_start(requested, budget)
      }
    }
    index += 1
  }
  Ok({ requested_timestamp: requested, outcome: End, frame: None, })
}

///|
/// Seek to the first selected presentation encountered in container decode
/// order whose known raw-media PTS is at least `requested_timestamp`.
/// `Exact` reports equality, `Next` reports a later PTS, `End` reports that no
/// selected picture qualifies, and `UnknownTimestamp` reports the first
/// selected picture that has no timestamp and therefore cannot be compared.
pub fn Av1ContainerDecoder::seek_timestamp(
  self : Av1ContainerDecoder,
  requested_timestamp : Int64,
) -> Result[Av1ContainerSeekResult, DecodeError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  let budget = match decode_checked_budget(0, self.limits) {
    Ok(value) => value
    Err(error) => return self.record_seek_failure(self.next_index, error)
  }
  let mut previous : Int64? = None
  let mut ascending = true
  for packet in self.track.packets {
    match packet.presentation_timestamp {
      Some(value) => {
        match previous {
          Some(prior) => if value < prior { ascending = false }
          None => ()
        }
        previous = Some(value)
      }
      None => {
        ascending = false
        break
      }
    }
  }
  if ascending {
    self.seek_ascending(requested_timestamp, budget)
  } else {
    self.seek_from_start(requested_timestamp, budget)
  }
}

///|
/// Read the next displayed picture. Hidden-only packets share this call's
/// work budget with the eventual displayed picture. Timestamps stay in the
/// demuxer's media timeline; container presentation edits are not implicit.
pub fn Av1ContainerDecoder::next_frame(
  self : Av1ContainerDecoder,
) -> Result[Av1ContainerFrame?, DecodeError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.next_index == self.track.packets.length() {
    return Ok(None)
  }
  let budget = match decode_checked_budget(0, self.limits) {
    Ok(value) => value
    Err(error) => return self.record_failure(error)
  }
  while self.next_index < self.track.packets.length() {
    let index = self.next_index
    let displayed = match
      av1_container_decode_packet(
        self.track,
        self.limits,
        self.decoder,
        index,
        budget,
      ) {
      Ok(value) => value
      Err(error) => return self.record_failure_at(index, error)
    }
    if displayed.length() > 1 {
      return self.record_failure_at(
        index,
        decode_error(
          InvalidData,
          "presentation",
          "A container sample has multiple selected presentations",
        ),
      )
    }
    let packet_index = index
    self.next_index = index + 1
    if displayed.length() == 1 {
      return Ok(
        Some({
          packet_index,
          timestamp: self.track.packets[index].presentation_timestamp,
          duration: self.track.packets[index].duration,
          timescale: self.track.timescale,
          frame: av1_frame_to_native(displayed[0]),
        }),
      )
    }
  }
  Ok(None)
}
