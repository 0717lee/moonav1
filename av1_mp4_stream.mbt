///|
/// Incremental ISO BMFF/fMP4 demux for the shared container stream.
///
/// The state keeps metadata and bounded sample descriptors only. Media payload
/// bytes remain in ContainerStreamInput until a complete selected sample is
/// available, then are copied into an owned packet and consumed immediately.
priv struct Mp4StreamBoxHeader {
  typ : Int
  header : Int
  size : Int64?
}

///|
priv struct Mp4StreamMdat {
  end : Int64?
}

///|
/// A finite or size-zero non-media top-level box being discarded. Padding and
/// unknown boxes are streamed through the input buffer instead of being
/// assembled as one retained unit.
priv struct Mp4StreamSkip {
  end : Int64?
}

///|
priv struct Av1Mp4StreamState {
  limits : DecodeLimits
  requested_track_id : Int64?
  mut track : Av1DemuxedTrack?
  mut mp4_track : Mp4Track?
  mut trex : Mp4Trex?
  mut descriptors : Array[Mp4Sample]
  mut next_sample : Int
  mut sample_count : Int
  mut last_sample : Mp4Sample?
  mut fragment_state : Mp4FragmentState
  mut current_mdat : Mp4StreamMdat?
  mut current_skip : Mp4StreamSkip?
  mut parsed_moov : Bool
  mut saw_mdat : Bool
  mut saw_selected_moof : Bool
  mut table_samples : Bool
  mut fragment_samples : Bool
  mut media_before_metadata : Bool
  mut replay_available : Bool
  mut replay_mode : Bool
  mut consumed_through : Int64
}

///|
fn Av1Mp4StreamState::new(
  track_id : Int64?,
  limits : DecodeLimits,
) -> Av1Mp4StreamState {
  {
    limits,
    requested_track_id: track_id,
    track: None,
    mp4_track: None,
    trex: None,
    descriptors: [],
    next_sample: 0,
    sample_count: 0,
    last_sample: None,
    fragment_state: { next_decode_time: 0L, },
    current_mdat: None,
    current_skip: None,
    parsed_moov: false,
    saw_mdat: false,
    saw_selected_moof: false,
    table_samples: false,
    fragment_samples: false,
    media_before_metadata: false,
    replay_available: false,
    replay_mode: false,
    consumed_through: 0L,
  }
}

///|
/// Logical retained compressed bytes. Expanded numeric sample descriptors,
/// allocator overhead, parser scratch copies and already-emitted output are
/// intentionally excluded; max_frames bounds descriptors independently.
fn Av1Mp4StreamState::retained_bytes(self : Av1Mp4StreamState) -> Int {
  match self.track {
    Some(track) => track.codec_initialization.length()
    None => 0
  }
}

///|
fn mp4_stream_header(
  input : ContainerStreamInput,
  eof : Bool,
) -> Result[Mp4StreamBoxHeader?, DecodeError] {
  let available = input.available()
  if available < 8 {
    if eof && available != 0 {
      return Err(
        decode_error(TruncatedInput, "mp4.stream", "Incomplete MP4 box header"),
      )
    }
    return Ok(None)
  }
  let data = input.bytes
  let p = input.start
  let size32 = mp4_u32_wide(data, p, p + 8) catch {
    Mp4Error::Diagnostic(error) => return Err(error)
  }
  let typ = mp4_bits32(data, p + 4, p + 8) catch {
    Mp4Error::Diagnostic(error) => return Err(error)
  }
  if size32 == 1L {
    if available < 16 {
      if eof {
        return Err(
          decode_error(
            TruncatedInput,
            "mp4.stream",
            "Incomplete 64-bit MP4 box header",
          ),
        )
      }
      return Ok(None)
    }
    let size = mp4_u64(data, p + 8, p + 16) catch {
      Mp4Error::Diagnostic(error) => return Err(error)
    }
    if size < 16L {
      return Err(
        decode_error(InvalidData, "mp4.stream", "Invalid 64-bit MP4 box size"),
      )
    }
    return Ok(Some({ typ, header: 16, size: Some(size), }))
  }
  if size32 == 0L {
    if eof {
      return Ok(Some({ typ, header: 8, size: Some(available.to_int64()), }))
    }
    return Ok(Some({ typ, header: 8, size: None, }))
  }
  if size32 < 8L {
    return Err(decode_error(InvalidData, "mp4.stream", "Invalid MP4 box size"))
  }
  Ok(Some({ typ, header: 8, size: Some(size32), }))
}

///|
fn mp4_stream_add(a : Int64, b : Int64) -> Result[Int64, DecodeError] {
  if b < 0L || a < 0L || a > mp4_i64_max - b {
    Err(decode_error(InvalidData, "mp4.stream", "MP4 file offset overflows"))
  } else {
    Ok(a + b)
  }
}

///|
fn Av1Mp4StreamState::mp4_stream_append_samples(
  self : Av1Mp4StreamState,
  samples : Array[Mp4Sample],
  fragment : Bool,
) -> Result[Unit, DecodeError] {
  if samples.length() == 0 {
    return Ok(())
  }
  if fragment && self.table_samples {
    return Err(
      decode_error(
        Unsupported,
        "mp4.stream",
        "Mixed ordinary and fragmented samples are unsupported",
      ),
    )
  }
  if !fragment && self.fragment_samples {
    return Err(
      decode_error(
        Unsupported,
        "mp4.stream",
        "Mixed ordinary and fragmented samples are unsupported",
      ),
    )
  }
  let mut previous = if self.descriptors.length() != 0 {
    let item = self.descriptors[self.descriptors.length() - 1]
    Some(item)
  } else {
    self.last_sample
  }
  for sample in samples {
    if self.sample_count >= self.limits.max_frames {
      return Err(
        decode_error(
          LimitExceeded,
          "mp4.stream",
          "MP4 sample count exceeds max_frames",
        ),
      )
    }
    if sample.size <= 0 {
      return Err(
        decode_error(
          InvalidData,
          "mp4.stream",
          "MP4 sample has an empty payload",
        ),
      )
    }
    if sample.size > self.limits.max_input_bytes {
      return Err(
        decode_error(
          LimitExceeded,
          "mp4.stream",
          "MP4 sample exceeds max_input_bytes",
        ),
      )
    }
    if sample.offset < self.consumed_through &&
      !(self.media_before_metadata && !self.replay_mode) {
      return Err(
        decode_error(
          InvalidData,
          "mp4.stream",
          "Sample offsets precede consumed media",
        ),
      )
    }
    match previous {
      Some(last) => {
        let last_end = match mp4_stream_add(last.offset, last.size.to_int64()) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if sample.offset < last.offset || sample.offset < last_end {
          return Err(
            decode_error(
              Unsupported,
              "mp4.stream",
              "Selected sample offsets are not decode-order compatible",
            ),
          )
        }
      }
      None => ()
    }
    self.descriptors.push(sample)
    self.sample_count += 1
    previous = Some(sample)
  }
  if fragment {
    self.fragment_samples = true
    self.saw_selected_moof = true
  } else {
    self.table_samples = true
  }
  Ok(())
}

///|
fn Av1Mp4StreamState::mp4_stream_parse_moov(
  self : Av1Mp4StreamState,
  data : Array[Byte],
) -> Result[Unit, DecodeError] {
  let (parsed, trex) = mp4_parse_moov_metadata(
    data,
    self.requested_track_id,
    self.limits,
  ) catch {
    Mp4Error::Diagnostic(error) => return Err(error)
  }
  let mut table_descriptors : Array[Mp4Sample] = []
  if parsed.has_sample_tables {
    let boxes = match mp4_boxes(data) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match mp4_child(boxes, -1, mp4_moov) {
      Some(_) => ()
      None =>
        return Err(
          decode_error(
            InvalidData,
            "mp4.stream",
            "MP4 metadata has no moov box",
          ),
        )
    }
    table_descriptors = mp4_table_sample_descriptors(
      data,
      boxes,
      parsed,
      self.limits,
    ) catch {
      Mp4Error::Diagnostic(error) => return Err(error)
    }
  }
  let public_track : Av1DemuxedTrack = {
    format: Mp4,
    track_id: parsed.id,
    width: parsed.width,
    height: parsed.height,
    timescale: parsed.timescale,
    movie_timescale: parsed.movie_timescale,
    edits: Array::makei(parsed.edits.length(), i => parsed.edits[i]),
    // Internal views share this owned configuration; track_info copies it at
    // the public boundary. Retain and charge the compressed bytes only once.
    codec_initialization: parsed.av1c,
    packets: [],
  }
  self.mp4_track = Some(parsed)
  self.trex = trex
  self.track = Some(public_track)
  self.parsed_moov = true
  match self.mp4_stream_append_samples(table_descriptors, false) {
    Err(error) => Err(error)
    Ok(_) => Ok(())
  }
}

///|
fn Av1Mp4StreamState::mp4_stream_parse_moof(
  self : Av1Mp4StreamState,
  data : Array[Byte],
  file_offset : Int64,
) -> Result[Unit, DecodeError] {
  let track = match self.mp4_track {
    Some(value) => value
    None => return Ok(())
  }
  let boxes = match mp4_boxes(data) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let moof = match mp4_child(boxes, -1, mp4_moof) {
    Some(value) => value
    None =>
      return Err(
        decode_error(InvalidData, "mp4.stream", "MP4 fragment has no moof box"),
      )
  }
  let samples : Array[Mp4Sample] = []
  let local_state = self.fragment_state
  mp4_fragment_moof_samples(
    data,
    boxes,
    moof,
    track,
    self.trex,
    local_state,
    file_offset,
    self.limits,
    samples,
  ) catch {
    Mp4Error::Diagnostic(error) => return Err(error)
  }
  self.fragment_state = local_state
  self.mp4_stream_append_samples(samples, true)
}

///|
fn Av1Mp4StreamState::mp4_stream_step_skip(
  self : Av1Mp4StreamState,
  input : ContainerStreamInput,
  eof : Bool,
) -> Result[ContainerStreamStep, DecodeError] {
  let skip = match self.current_skip {
    Some(value) => value
    None =>
      return Err(
        decode_error(InvalidState, "mp4.stream", "Missing skipped-box state"),
      )
  }
  let pos = input.offset()
  match skip.end {
    Some(end) if pos >= end => {
      self.current_skip = None
      return self.step(input, eof)
    }
    _ => ()
  }
  let available = input.available()
  match skip.end {
    Some(end) => {
      let remaining = end - pos
      if available == 0 {
        if eof {
          return Err(
            decode_error(TruncatedInput, "mp4.stream", "Truncated MP4 box"),
          )
        }
        return Ok(Wait)
      }
      let amount = if remaining < available.to_int64() {
        remaining.to_int()
      } else {
        available
      }
      input.consume(amount)
      if amount.to_int64() == remaining {
        self.current_skip = None
      }
      Ok(Progress)
    }
    None => {
      if available > 0 {
        input.consume(available)
        return Ok(Progress)
      }
      if eof {
        self.current_skip = None
        return self.step(input, eof)
      }
      Ok(Wait)
    }
  }
}

///|
fn Av1Mp4StreamState::mp4_stream_step_mdat(
  self : Av1Mp4StreamState,
  input : ContainerStreamInput,
  eof : Bool,
) -> Result[ContainerStreamStep, DecodeError] {
  let mdat = match self.current_mdat {
    Some(value) => value
    None =>
      return Err(decode_error(InvalidState, "mp4.stream", "Missing mdat state"))
  }
  let pos = input.offset()
  match mdat.end {
    Some(end) if pos >= end => {
      self.current_mdat = None
      return self.step(input, eof)
    }
    _ => ()
  }
  let available = input.available()
  if self.track is None || (self.media_before_metadata && !self.replay_mode) {
    self.media_before_metadata = true
    match mdat.end {
      Some(end) => {
        let remaining = end - pos
        if available == 0 {
          if eof {
            return Err(
              decode_error(
                TruncatedInput,
                "mp4.stream",
                "Truncated mdat payload",
              ),
            )
          }
          return Ok(Wait)
        }
        let amount = if remaining < available.to_int64() {
          remaining.to_int()
        } else {
          available
        }
        input.consume(amount)
        self.consumed_through = input.offset()
        if amount.to_int64() == remaining {
          self.current_mdat = None
        }
        Ok(Progress)
      }
      None => {
        if available > 0 {
          input.consume(available)
          self.consumed_through = input.offset()
          return Ok(Progress)
        }
        if eof {
          self.current_mdat = None
          return self.mp4_stream_finish(eof)
        }
        Ok(Wait)
      }
    }
  } else if self.next_sample >= self.descriptors.length() {
    match mdat.end {
      Some(end) => {
        let remaining = end - pos
        if available == 0 {
          if eof {
            return Err(
              decode_error(
                TruncatedInput,
                "mp4.stream",
                "Truncated mdat payload",
              ),
            )
          }
          return Ok(Wait)
        }
        let amount = if remaining < available.to_int64() {
          remaining.to_int()
        } else {
          available
        }
        input.consume(amount)
        self.consumed_through = input.offset()
        if amount.to_int64() == remaining {
          self.current_mdat = None
        }
        Ok(Progress)
      }
      None => {
        if available > 0 {
          input.consume(available)
          self.consumed_through = input.offset()
          return Ok(Progress)
        }
        if eof {
          self.current_mdat = None
          return self.mp4_stream_finish(eof)
        }
        Ok(Wait)
      }
    }
  } else {
    let sample = self.descriptors[self.next_sample]
    if sample.offset < pos {
      return Err(
        decode_error(
          InvalidData,
          "mp4.stream",
          "Sample range was passed before its mdat payload",
        ),
      )
    }
    match mdat.end {
      Some(end) if sample.offset >= end => {
        let remaining = end - pos
        if available == 0 {
          if eof {
            return Err(
              decode_error(
                TruncatedInput,
                "mp4.stream",
                "Truncated mdat payload",
              ),
            )
          }
          return Ok(Wait)
        }
        let amount = if remaining < available.to_int64() {
          remaining.to_int()
        } else {
          available
        }
        input.consume(amount)
        self.consumed_through = input.offset()
        if amount.to_int64() == remaining {
          self.current_mdat = None
        }
        return Ok(Progress)
      }
      _ => ()
    }
    let sample_end = match
      mp4_stream_add(sample.offset, sample.size.to_int64()) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if mdat.end is None && eof {
      let eof_end = match mp4_stream_add(pos, available.to_int64()) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if sample.offset >= eof_end || sample_end > eof_end {
        return Err(
          decode_error(
            InvalidData,
            "mp4.stream",
            "Sample range is outside the size-zero mdat",
          ),
        )
      }
    }
    match mdat.end {
      Some(end) if sample.offset < pos || sample_end > end =>
        return Err(
          decode_error(
            InvalidData,
            "mp4.stream",
            "Sample range is outside its mdat box",
          ),
        )
      _ => ()
    }
    if sample.offset > pos {
      let gap = sample.offset - pos
      if available == 0 {
        if eof {
          return Err(
            decode_error(
              TruncatedInput,
              "mp4.stream",
              "Sample offset exceeds available input",
            ),
          )
        }
        return Ok(Wait)
      }
      let amount = if gap < available.to_int64() {
        gap.to_int()
      } else {
        available
      }
      input.consume(amount)
      self.consumed_through = input.offset()
      return Ok(Progress)
    }
    if sample.size > self.limits.max_input_bytes {
      return Err(
        decode_error(
          LimitExceeded,
          "mp4.stream",
          "Sample payload exceeds max_input_bytes",
        ),
      )
    }
    if available < sample.size {
      if eof {
        return Err(
          decode_error(
            TruncatedInput,
            "mp4.stream",
            "Truncated MP4 sample payload",
          ),
        )
      }
      return Ok(Wait)
    }
    let packet : Av1Packet = {
      data: Array::makei(sample.size, i => input.bytes[input.start + i]),
      presentation_timestamp: Some(sample.pts),
      decode_timestamp: Some(sample.dts),
      duration: Some(sample.duration),
      sync_sample: sample.sync,
    }
    input.consume(sample.size)
    self.consumed_through = input.offset()
    self.next_sample += 1
    if self.fragment_samples {
      // Fragment descriptors are only needed until their payload is emitted.
      // Keep the last one as a scalar ordering guard for the next moof.
      self.last_sample = Some(sample)
      let remaining = self.descriptors.length() - self.next_sample
      self.descriptors = Array::makei(remaining, i => {
        self.descriptors[self.next_sample + i]
      })
      self.next_sample = 0
    }
    Ok(Packet(packet))
  }
}

///|
fn Av1Mp4StreamState::mp4_stream_finish(
  self : Av1Mp4StreamState,
  eof : Bool,
) -> Result[ContainerStreamStep, DecodeError] {
  if self.current_mdat is Some(_) {
    if eof {
      return Err(
        decode_error(TruncatedInput, "mp4.stream", "Truncated mdat payload"),
      )
    }
    return Ok(Wait)
  }
  if !eof {
    return Ok(Wait)
  }
  if self.track is None {
    return Err(decode_error(InvalidData, "mp4.stream", "MP4 has no moov box"))
  }
  if self.replay_available && self.media_before_metadata && !self.replay_mode {
    return Ok(ReplayRequired)
  }
  if self.next_sample < self.descriptors.length() {
    return Err(
      decode_error(
        InvalidData,
        "mp4.stream",
        "Selected MP4 sample range is outside every mdat box",
      ),
    )
  }
  if !self.saw_mdat {
    return Err(decode_error(InvalidData, "mp4.stream", "MP4 has no mdat box"))
  }
  let has_tables = match self.mp4_track {
    Some(value) => value.has_sample_tables
    None => false
  }
  if !has_tables && !self.saw_selected_moof {
    return Err(
      decode_error(
        InvalidData,
        "mp4.stream",
        "Selected fragmented track has no samples",
      ),
    )
  }
  Ok(End)
}

///|
fn Av1Mp4StreamState::step(
  self : Av1Mp4StreamState,
  input : ContainerStreamInput,
  eof : Bool,
) -> Result[ContainerStreamStep, DecodeError] {
  if self.current_skip is Some(_) {
    return self.mp4_stream_step_skip(input, eof)
  }
  if self.current_mdat is Some(_) {
    return self.mp4_stream_step_mdat(input, eof)
  }
  if input.available() == 0 {
    return self.mp4_stream_finish(eof)
  }
  let header = match mp4_stream_header(input, eof) {
    Err(error) => return Err(error)
    Ok(None) => return Ok(Wait)
    Ok(Some(value)) => value
  }
  let box_start = input.offset()
  let size = match header.size {
    Some(value) => value
    None => {
      if header.typ == mp4_moov || header.typ == mp4_moof {
        // A size-zero metadata box extends to EOF. Keep it under the usual
        // input cap, then parse its bounded body when finish supplies EOF.
        return Ok(Wait)
      }
      if header.typ != mp4_mdat {
        input.consume(header.header)
        self.current_skip = Some({ end: None, })
        return Ok(Progress)
      }
      input.consume(header.header)
      self.saw_mdat = true
      self.current_mdat = Some({ end: None, })
      if self.track is None {
        self.media_before_metadata = true
      }
      return Ok(Progress)
    }
  }
  if header.typ == mp4_mdat {
    let end = match mp4_stream_add(box_start, size) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    input.consume(header.header)
    self.saw_mdat = true
    self.current_mdat = Some({ end: Some(end), })
    if self.track is None {
      self.media_before_metadata = true
    }
    return Ok(Progress)
  }
  if header.typ != mp4_moov && header.typ != mp4_moof {
    let end = match mp4_stream_add(box_start, size) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    input.consume(header.header)
    self.current_skip = Some({ end: Some(end), })
    return Ok(Progress)
  }
  if size > self.limits.max_input_bytes.to_int64() {
    return Err(
      decode_error(
        LimitExceeded,
        "mp4.stream",
        "MP4 metadata box exceeds max_input_bytes",
      ),
    )
  }
  let size_i = size.to_int()
  if input.available() < size_i {
    return Ok(Wait)
  }
  if header.typ == mp4_moov {
    if self.replay_mode {
      input.consume(size_i)
      return Ok(Progress)
    }
    if self.parsed_moov {
      return Err(
        decode_error(
          InvalidData,
          "mp4.stream",
          "MP4 contains multiple moov boxes",
        ),
      )
    }
    let data = Array::makei(size_i, i => input.bytes[input.start + i])
    match self.mp4_stream_parse_moov(data) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    input.consume(size_i)
    if self.media_before_metadata {
      self.replay_available = true
    }
    return Ok(Progress)
  }
  if header.typ == mp4_moof {
    if self.track is None || (self.media_before_metadata && !self.replay_mode) {
      self.media_before_metadata = true
      input.consume(size_i)
      return Ok(Progress)
    }
    let data = Array::makei(size_i, i => input.bytes[input.start + i])
    match self.mp4_stream_parse_moof(data, box_start) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    input.consume(size_i)
    return Ok(Progress)
  }
  input.consume(size_i)
  Ok(Progress)
}

///|
/// The outer stream calls this only after a completed metadata-only tail pass.
/// The parsed track metadata and ordinary table descriptors are retained;
/// fragmented descriptors are rebuilt from moofs as the original file is
/// replayed from offset zero.
fn Av1Mp4StreamState::replay(
  self : Av1Mp4StreamState,
) -> Result[Av1Mp4StreamState, DecodeError] {
  if !self.replay_available {
    return Err(
      decode_error(
        InvalidState,
        "mp4.stream",
        "No completed MP4 replay request",
      ),
    )
  }
  self.replay_available = false
  self.replay_mode = true
  self.current_mdat = None
  self.current_skip = None
  self.next_sample = 0
  self.saw_mdat = false
  self.saw_selected_moof = false
  self.media_before_metadata = false
  self.consumed_through = 0L
  self.fragment_state.next_decode_time = 0L
  if self.fragment_samples {
    self.descriptors = []
    self.sample_count = 0
    self.last_sample = None
    self.fragment_samples = false
    self.table_samples = false
  }
  Ok(self)
}
