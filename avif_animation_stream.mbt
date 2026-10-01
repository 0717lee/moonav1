///|
priv struct GaTrackDecoder {
  track : GaAnimationTrack
  decoder : Av1VideoDecoder
  mut sequence_payload : Array[Byte]?
}

///|
fn ga_track_decoder(track : GaAnimationTrack) -> GaTrackDecoder {
  { track, decoder: av1_video_decoder(), sequence_payload: None, }
}

///|
fn ga_track_sample(
  data : Array[Byte],
  track : GaAnimationTrack,
  index : Int,
  limit : Int,
) -> Array[Byte]? {
  if index < 0 || index >= track.descriptor.frames.length() {
    return None
  }
  let timing = track.descriptor.frames[index]
  let sample = if index == 0 { track.config_obus.copy() } else { [] }
  if timing.offset < 0 ||
    timing.length < 0 ||
    timing.offset > data.length() - timing.length ||
    timing.length > limit - sample.length() {
    return None
  }
  for i in timing.offset..<(timing.offset + timing.length) {
    sample.push(data[i])
  }
  Some(sample)
}

///|
/// Shared by eager and incremental animation APIs; only returned-frame storage
/// differs. Both retain the same sequence/configuration and sample contracts.
fn ga_track_decode_one(
  cursor : GaTrackDecoder,
  data : Array[Byte],
  index : Int,
  budget : DecodeBudget?,
) -> Av1FramePlanes? {
  let track = cursor.track
  let timing = track.descriptor.frames[index]
  decode_context(budget, "animation.sample", Some(timing.offset))
  if timing.index != index ||
    timing.timescale != track.descriptor.timescale ||
    timing.duration <= 0 {
    return None
  }
  let limit = match budget {
    Some(value) => value.limits.max_input_bytes
    None => 0x7FFFFFFF
  }
  let sample = match ga_track_sample(data, track, index, limit) {
    Some(value) => value
    None => {
      decode_fail(
        budget,
        LimitExceeded,
        "Sample extents or assembled payload exceed the input boundary",
      )
      return None
    }
  }
  for payload in av1_obu_payloads(sample, 1) {
    match cursor.sequence_payload {
      None => cursor.sequence_payload = Some(payload)
      Some(previous) => if previous != payload { return None }
    }
  }
  let displayed = match
    av1_video_decode_temporal_unit_planes(
      cursor.decoder,
      sample,
      allow_monochrome=true,
      budget~,
    ) {
    Some(value) => value
    None => return None
  }
  decode_context(budget, "animation.sample", Some(timing.offset))
  if displayed.length() != 1 {
    return None
  }
  let frame = displayed[0]
  if track.config_width != 0 {
    let sequence = match cursor.decoder.sequence {
      Some(value) => value
      None => return None
    }
    if sequence.width != track.config_width ||
      sequence.height != track.config_height {
      return None
    }
  }
  if track.config_depth != 0 &&
    (
      frame.bit_depth != track.config_depth ||
      (frame.planes.length() == 1) != track.config_monochrome
    ) {
    return None
  }
  Some(frame)
}

///|
fn ga_track_index(
  data : Array[Byte],
  track : GaAnimationTrack,
  limit : Int,
) -> Result[(Av1SequenceInfo, Array[Byte], Array[Bool]), DecodeError] {
  let mut sequence : Av1SequenceInfo? = None
  let mut header : Array[Byte]? = None
  let keys : Array[Bool] = []
  let mut time = 0
  for i in 0..<track.descriptor.frames.length() {
    let timing = track.descriptor.frames[i]
    if timing.index != i ||
      timing.timescale != track.descriptor.timescale ||
      timing.timestamp != time ||
      timing.duration <= 0 ||
      timing.duration > 0x7FFFFFFF - time {
      return Err(
        decode_error(
          InvalidData,
          "animation.timing",
          "Track timestamps/durations are not contiguous",
        ),
      )
    }
    time += timing.duration
    let sample = match ga_track_sample(data, track, i, limit) {
      Some(value) => value
      None =>
        return Err(
          decode_error(
            LimitExceeded,
            "animation.sample",
            "Sample exceeds the supplied bytes or policy",
            offset=Some(timing.offset),
          ),
        )
    }
    let packets = match av1_obu_packets_checked(sample, limit~) {
      Ok(value) => value
      Err(error) =>
        return Err({
          ..error,
          byte_offset: None,
          context: "animation/" + error.context,
        })
    }
    let mut frames = 0
    let mut key = false
    for packet in packets {
      if packet.kind == 1 {
        match header {
          Some(previous) =>
            if previous != packet.payload {
              return Err(
                decode_error(
                  InvalidData,
                  "animation.sequence",
                  "Sequence header changes within a track",
                ),
              )
            }
          None => {
            header = Some(packet.payload)
            sequence = av1_parse_sequence_payload(packet.payload)
            if sequence is None {
              return Err(
                decode_error(
                  InvalidData,
                  "animation.sequence",
                  "Invalid sequence header",
                ),
              )
            }
          }
        }
      }
      if packet.kind == 3 || packet.kind == 6 {
        let seq = match sequence {
          Some(value) => value
          None =>
            return Err(
              decode_error(
                MissingSequence,
                "animation.sequence",
                "Track has no initial sequence header",
              ),
            )
        }
        if !av1_obu_selected(packet, seq) {
          continue
        }
        if packet.payload.is_empty() {
          return Err(
            decode_error(
              TruncatedInput,
              "animation.sample",
              "Empty frame header",
            ),
          )
        }
        frames += 1
        let first = packet.payload[0].to_int()
        key = seq.reduced_still_picture_header ||
          ((first & 128) == 0 && ((first >> 5) & 3) == 0 && (first & 16) != 0)
      }
    }
    // Conservative random access: exactly one selected, shown key picture.
    // Multi-picture units remain decodable sequentially or by replay from zero.
    keys.push(frames == 1 && key)
  }
  match (sequence, header) {
    (Some(seq), Some(payload)) => Ok((seq, payload, keys))
    _ =>
      Err(
        decode_error(
          MissingSequence,
          "animation.sequence",
          "Track has no sequence header",
        ),
      )
  }
}

///|
/// A lazy, independently owned AVIF animation session. Container/timing and
/// OBU envelopes are checked at construction; entropy/pixels are checked only
/// when consumed. Returned pictures survive next_frame(), seek_frame(), reset().
pub struct AvifAnimationDecoder {
  priv data : Array[Byte]
  priv limits : DecodeLimits
  priv mut color : GaTrackDecoder
  priv mut alpha : GaTrackDecoder?
  priv color_sequence : Av1SequenceInfo
  priv color_header : Array[Byte]
  priv alpha_sequence : Av1SequenceInfo?
  priv alpha_header : Array[Byte]?
  priv keys : Array[Bool]
  priv metadata_value : AvifMetadata
  priv mut next_index : Int
  priv mut failure : DecodeError?
}

///|
pub fn AvifAnimationDecoder::new(
  data : Array[Byte],
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[AvifAnimationDecoder, DecodeError] {
  let budget = match decode_checked_budget(data.length(), limits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (color, alpha) = match
    ga_animation_tracks(data, diagnostic=budget.diagnostic) {
    Some(value) => value
    None => return Err(decode_failure(budget))
  }
  if color.descriptor.frames.is_empty() || color.descriptor.timescale <= 0 {
    return Err(
      decode_error(
        InvalidData,
        "animation.timing",
        "Empty track or invalid timescale",
      ),
    )
  }
  let (color_sequence, color_header, keys) = match
    ga_track_index(data, color, limits.max_input_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut alpha_sequence : Av1SequenceInfo? = None
  let mut alpha_header : Array[Byte]? = None
  if alpha is Some(track) {
    if track.descriptor.frames.length() != keys.length() {
      return Err(
        decode_error(
          InvalidData,
          "animation.alpha",
          "Color and alpha frame counts differ",
        ),
      )
    }
    let (seq, payload, alpha_keys) = match
      ga_track_index(data, track, limits.max_input_bytes) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    alpha_sequence = Some(seq)
    alpha_header = Some(payload)
    for i in 0..<keys.length() {
      let c = color.descriptor.frames[i]
      let a = track.descriptor.frames[i]
      if a.timestamp.to_int64() * c.timescale.to_int64() !=
        c.timestamp.to_int64() * a.timescale.to_int64() ||
        a.duration.to_int64() * c.timescale.to_int64() !=
        c.duration.to_int64() * a.timescale.to_int64() {
        return Err(
          decode_error(
            InvalidData,
            "animation.alpha",
            "Color and alpha timelines do not align exactly",
          ),
        )
      }
      keys[i] = keys[i] && alpha_keys[i]
    }
  }
  let metadata_value = match
    avif_track_metadata(data, color, limits.max_input_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    data: data.copy(),
    limits,
    color: ga_track_decoder(color),
    alpha: alpha.map(ga_track_decoder),
    color_sequence,
    color_header,
    alpha_sequence,
    alpha_header,
    keys,
    metadata_value,
    next_index: 0,
    failure: None,
  })
}

///|
pub fn AvifAnimationDecoder::frame_count(self : AvifAnimationDecoder) -> Int {
  self.keys.length()
}

///|
pub fn AvifAnimationDecoder::position(self : AvifAnimationDecoder) -> Int {
  self.next_index
}

///|
pub fn AvifAnimationDecoder::metadata(
  self : AvifAnimationDecoder,
) -> AvifMetadata {
  avif_metadata_copy(self.metadata_value)
}

///|
pub fn AvifAnimationDecoder::frame_timing(
  self : AvifAnimationDecoder,
  index : Int,
) -> Result[AvifAnimationFrame, DecodeError] {
  if index < 0 || index >= self.keys.length() {
    return Err(
      decode_error(
        InvalidData,
        "animation.index",
        "Frame index is outside the track",
      ),
    )
  }
  Ok(self.color.track.descriptor.frames[index])
}

///|
pub fn AvifAnimationDecoder::is_keyframe(
  self : AvifAnimationDecoder,
  index : Int,
) -> Result[Bool, DecodeError] {
  match self.frame_timing(index) {
    Err(error) => Err(error)
    Ok(_) => Ok(self.keys[index])
  }
}

///|
/// Nearest conservatively indexed independent sample, shared by color/alpha.
/// None means seeking must replay from sample zero to preserve dependencies.
pub fn AvifAnimationDecoder::nearest_keyframe(
  self : AvifAnimationDecoder,
  index : Int,
) -> Result[Int?, DecodeError] {
  match self.frame_timing(index) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  for i = index; i >= 0; i = i - 1 {
    if self.keys[i] {
      return Ok(Some(i))
    }
  }
  Ok(None)
}

///|
fn AvifAnimationDecoder::reset_to(
  self : AvifAnimationDecoder,
  index : Int,
) -> Unit {
  self.color = ga_track_decoder(self.color.track)
  self.alpha = self.alpha.map(cursor => ga_track_decoder(cursor.track))
  if index > 0 {
    self.color.decoder.sequence = Some(self.color_sequence)
    self.color.sequence_payload = Some(self.color_header)
    if self.alpha is Some(cursor) {
      cursor.decoder.sequence = self.alpha_sequence
      cursor.sequence_payload = self.alpha_header
    }
  }
  self.next_index = index
  self.failure = None
}

///|
pub fn AvifAnimationDecoder::reset(self : AvifAnimationDecoder) -> Unit {
  self.reset_to(0)
}

///|
fn animation_decode_error(
  cursor : GaTrackDecoder,
  index : Int,
  budget : DecodeBudget,
  role : String,
) -> DecodeError {
  let error = decode_failure(budget)
  let prefix = if index == 0 { cursor.track.config_obus.length() } else { 0 }
  let at = cursor.track.descriptor.frames[index].offset.to_int64()
  let byte_offset = if error.context == "animation.sample" {
    error.byte_offset
  } else {
    match error.byte_offset {
      Some(offset) if offset >= prefix.to_int64() =>
        Some(at + offset - prefix.to_int64())
      _ => None
    }
  }
  {
    ..error,
    byte_offset,
    context: "animation." + role + "/" + error.context,
    message: "Sample \{index}: \{error.message}",
  }
}

///|
fn AvifAnimationDecoder::read_planes(
  self : AvifAnimationDecoder,
  index : Int,
  budget : DecodeBudget,
) -> Result[(Av1FramePlanes, Av1FramePlanes?, Bool), DecodeError] {
  let decoded = match
    ga_track_decode_one(self.color, self.data, index, Some(budget)) {
    Some(value) => value
    None =>
      return Err(animation_decode_error(self.color, index, budget, "color"))
  }
  let track = self.color.track
  let color = av1_frame_apply_nclx(
    decoded,
    track.nclx_primaries,
    track.nclx_transfer,
    track.nclx_matrix,
    track.nclx_full_range,
  )
  let mut alpha : Av1FramePlanes? = None
  let mut premultiplied = false
  if self.alpha is Some(cursor) {
    let plane = match
      ga_track_decode_one(cursor, self.data, index, Some(budget)) {
      Some(value) => value
      None => return Err(animation_decode_error(cursor, index, budget, "alpha"))
    }
    if plane.width != color.width ||
      plane.height != color.height ||
      plane.bit_depth != color.bit_depth ||
      plane.planes.length() != 1 {
      return Err(
        decode_error(
          InvalidData,
          "animation.alpha",
          "Alpha geometry or depth does not match color",
          offset=Some(cursor.track.descriptor.frames[index].offset),
        ),
      )
    }
    alpha = Some(plane)
    premultiplied = track.premultiplied_by.contains(cursor.track.id)
  }
  Ok((color, alpha, premultiplied))
}

///|
fn animation_native_frame(
  timing : AvifAnimationFrame,
  planes : (Av1FramePlanes, Av1FramePlanes?, Bool),
) -> AvifNativeAnimationFrame {
  let (color, alpha, premultiplied) = planes
  {
    index: timing.index,
    timestamp: timing.timestamp,
    duration: timing.duration,
    timescale: timing.timescale,
    image: {
      color: av1_frame_to_native(color),
      alpha: alpha.map(av1_frame_to_native),
      premultiplied,
    },
  }
}

///|
/// Ok(None) is end of sequence. A later corrupt sample can fail after earlier
/// frames were delivered; failure remains sticky until reset(). Work limits
/// apply to this operation, shared by the color and alpha reconstruction.
pub fn AvifAnimationDecoder::next_frame(
  self : AvifAnimationDecoder,
) -> Result[AvifNativeAnimationFrame?, DecodeError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.next_index == self.keys.length() {
    return Ok(None)
  }
  let budget = match decode_checked_budget(0, self.limits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match self.read_planes(self.next_index, budget) {
    Err(error) => {
      self.failure = Some(error)
      Err(error)
    }
    Ok(planes) => {
      let frame = animation_native_frame(
        self.color.track.descriptor.frames[self.next_index],
        planes,
      )
      self.next_index += 1
      Ok(Some(frame))
    }
  }
}

///|
/// Decode from the nearest common independent key sample (or zero). All replay
/// work counts against one operation budget. The next read returns index + 1.
pub fn AvifAnimationDecoder::seek_frame(
  self : AvifAnimationDecoder,
  index : Int,
) -> Result[AvifNativeAnimationFrame, DecodeError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  let start = match self.nearest_keyframe(index) {
    Err(error) => return Err(error)
    Ok(Some(value)) => value
    Ok(None) => 0
  }
  self.reset_to(start)
  let budget = match decode_checked_budget(0, self.limits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for i in start..<=index {
    match self.read_planes(i, budget) {
      Err(error) => {
        self.failure = Some(error)
        return Err(error)
      }
      Ok(planes) => {
        self.next_index = i + 1
        if i == index {
          return Ok(
            animation_native_frame(
              self.color.track.descriptor.frames[i],
              planes,
            ),
          )
        }
      }
    }
  }
  Err(
    decode_error(InvalidState, "animation.seek", "No target frame was decoded"),
  )
}
