///|
/// Incremental WebM/Matroska demux state. The outer container stream owns the
/// input buffer; this state only retains validated initialization OBUs and
/// packets that have already been materialized from a laced block.
priv enum WebmStreamStage {
  WebmNeedEbml
  WebmNeedSegment
  WebmInSegment
  WebmInCluster
  WebmAfterSegment
  WebmDone
}

///|
priv enum WebmStreamProbe {
  WebmProbeWait
  WebmProbeReady(WebmElement)
}

///|
priv struct Av1WebmStreamState {
  limits : DecodeLimits
  requested_track : Int64?
  mut track : Av1DemuxedTrack?
  mut selected : WebmTrack?
  mut track_numbers : Array[Int64]
  mut timestamp_scale : Int64
  mut stage : WebmStreamStage
  mut saw_segment : Bool
  mut saw_info : Bool
  mut saw_tracks : Bool
  mut segment_start : Int64?
  mut segment_end : Int64?
  mut segment_unknown : Bool
  mut segment_elements : Int
  mut cluster_start : Int64?
  mut cluster_end : Int64?
  mut cluster_unknown : Bool
  mut cluster_timestamp : Int64?
  mut cluster_elements : Int
  mut queue : Array[Av1Packet]
  mut queue_at : Int
  mut packet_count : Int
}

///|
fn Av1WebmStreamState::new(
  track_id : Int64?,
  limits : DecodeLimits,
) -> Av1WebmStreamState {
  {
    limits,
    requested_track: track_id,
    track: None,
    selected: None,
    track_numbers: [],
    timestamp_scale: WEBM_DEFAULT_TIMESTAMP_SCALE,
    stage: WebmNeedEbml,
    saw_segment: false,
    saw_info: false,
    saw_tracks: false,
    segment_start: None,
    segment_end: None,
    segment_unknown: false,
    segment_elements: 0,
    cluster_start: None,
    cluster_end: None,
    cluster_unknown: false,
    cluster_timestamp: None,
    cluster_elements: 0,
    queue: [],
    queue_at: 0,
    packet_count: 0,
  }
}

///|
fn webm_stream_rebase(
  input : ContainerStreamInput,
  error : DecodeError,
) -> DecodeError {
  { ..error, byte_offset: error.byte_offset.map(at => input.base_offset + at), }
}

///|
fn webm_stream_error(
  input : ContainerStreamInput,
  kind : DecodeErrorKind,
  context : String,
  message : String,
  at : Int,
) -> DecodeError {
  {
    kind,
    context,
    message,
    byte_offset: Some(input.base_offset + at.to_int64()),
  }
}

///|
/// Probe an EBML element. `complete` controls whether the payload must already
/// be present. Container masters are probed from their header and consumed a
/// header at a time; metadata and block payloads require a complete element.
fn webm_stream_probe_element(
  input : ContainerStreamInput,
  parent_end : Int64?,
  complete : Bool,
) -> Result[WebmStreamProbe, DecodeError] {
  let data = input.bytes
  let p = input.start
  let physical_end = p + input.available()
  if p >= physical_end {
    return Ok(WebmProbeWait)
  }
  let parent_local : Int? = match parent_end {
    None => None
    Some(value) => {
      if value < input.base_offset {
        return Err(
          webm_stream_error(
            input,
            InvalidState,
            "webm.stream",
            "Logical parent precedes input offset",
            p,
          ),
        )
      }
      let delta = value - input.base_offset
      if delta > 2147483647L {
        return Err(
          webm_stream_error(
            input,
            LimitExceeded,
            "webm.stream",
            "Logical element boundary exceeds Int",
            p,
          ),
        )
      }
      Some(delta.to_int())
    }
  }
  let id_width = webm_vint_width(data[p].to_int())
  if id_width == 0 {
    return Err(
      webm_stream_error(input, InvalidData, "ebml/id", "Invalid EBML ID", p),
    )
  }
  if id_width > physical_end - p {
    return Ok(WebmProbeWait)
  }
  let id = match webm_read_vint(data, p, physical_end, id=true) {
    Ok(value) => value
    Err(error) => return Err(webm_stream_rebase(input, error))
  }
  let size_at = p + id.width
  if size_at >= physical_end {
    return Ok(WebmProbeWait)
  }
  let size_width = webm_vint_width(data[size_at].to_int())
  if size_width == 0 {
    return Err(
      webm_stream_error(
        input,
        InvalidData,
        "ebml/vint",
        "Invalid EBML size",
        size_at,
      ),
    )
  }
  if size_width > physical_end - size_at {
    return Ok(WebmProbeWait)
  }
  let size = match webm_read_vint(data, size_at, physical_end, size_mode=true) {
    Ok(value) => value
    Err(error) => return Err(webm_stream_rebase(input, error))
  }
  let payload = size_at + size.width
  let end = if size.unknown {
    match parent_local {
      Some(value) => value
      None => physical_end
    }
  } else {
    if size.value > (2147483647 - payload).to_int64() {
      return Err(
        webm_stream_error(
          input,
          LimitExceeded,
          "ebml/element",
          "Element exceeds the addressable input bound",
          p,
        ),
      )
    }
    let value = payload + size.value.to_int()
    match parent_local {
      Some(bound) if value > bound =>
        return Err(
          webm_stream_error(
            input,
            TruncatedInput,
            "ebml/element",
            "Element exceeds its logical parent",
            p,
          ),
        )
      _ => value
    }
  }
  if end < payload {
    return Err(
      webm_stream_error(
        input,
        InvalidData,
        "ebml/element",
        "Element end precedes payload",
        p,
      ),
    )
  }
  if complete && end > physical_end {
    return Ok(WebmProbeWait)
  }
  if !complete {
    return Ok(
      WebmProbeReady({
        id: id.value,
        start: p,
        payload,
        end,
        unknown: size.unknown,
      }),
    )
  }
  match webm_read_element(data, p, physical_end) {
    Ok(value) => Ok(WebmProbeReady(value))
    Err(error) => Err(webm_stream_rebase(input, error))
  }
}

///|
fn Av1WebmStreamState::retained_bytes(self : Av1WebmStreamState) -> Int {
  let mut out = match self.track {
    Some(value) => value.codec_initialization.length()
    None => 0
  }
  for i in self.queue_at..<self.queue.length() {
    let length = self.queue[i].data.length()
    if out > 2147483647 - length {
      return 2147483647
    }
    out += length
  }
  out
}

///|
fn Av1WebmStreamState::webm_stream_take_packet(
  self : Av1WebmStreamState,
) -> Av1Packet? {
  if self.queue_at >= self.queue.length() {
    return None
  }
  let packet = self.queue[self.queue_at]
  self.queue_at += 1
  if self.queue_at == self.queue.length() {
    self.queue = []
    self.queue_at = 0
  }
  Some(packet)
}

///|
fn Av1WebmStreamState::webm_stream_track_is_known(
  self : Av1WebmStreamState,
  number : Int64,
) -> Bool {
  for value in self.track_numbers {
    if value == number {
      return true
    }
  }
  false
}

///|
/// Locate the copied CodecPrivate payload so AV1C diagnostics can be rebased
/// from the standalone configuration array back to the stream input.
fn webm_stream_codec_private_offset(
  data : Array[Byte],
  tracks_element : WebmElement,
  number : Int64,
) -> Int {
  let entries : Array[WebmElement] = []
  match webm_element_children(data, tracks_element, entries, 1) {
    Err(_) => return tracks_element.start
    Ok(_) => ()
  }
  for entry in entries {
    if entry.id != WEBM_TRACK_ENTRY {
      continue
    }
    let children : Array[WebmElement] = []
    match webm_element_children(data, entry, children, 2) {
      Err(_) => continue
      Ok(_) => ()
    }
    let mut track_number : Int64? = None
    let mut codec_offset : Int? = None
    for child in children {
      if child.id == WEBM_TRACK_NUMBER {
        track_number = match webm_uint(data, child.payload, child.end) {
          Ok(value) => Some(value)
          Err(_) => None
        }
      } else if child.id == WEBM_CODEC_PRIVATE {
        codec_offset = Some(child.payload)
      }
    }
    if track_number == Some(number) {
      match codec_offset {
        Some(value) => return value
        None => return tracks_element.start
      }
    }
  }
  tracks_element.start
}

///|
fn Av1WebmStreamState::webm_stream_parse_tracks(
  self : Av1WebmStreamState,
  input : ContainerStreamInput,
  element : WebmElement,
) -> Result[Unit, DecodeError] {
  let tracks = match webm_parse_tracks(input.bytes, element) {
    Ok(value) => value
    Err(error) => return Err(webm_stream_rebase(input, error))
  }
  let selected = match self.requested_track {
    Some(number) =>
      match webm_find_track(tracks, number) {
        Some(value) => value
        None =>
          return Err(
            webm_stream_error(
              input,
              InvalidData,
              "tracks",
              "Requested TrackNumber was not found",
              element.start,
            ),
          )
      }
    None => {
      let mut found : WebmTrack? = None
      for value in tracks {
        if value.track_type == 1 && value.codec_av1 {
          found = Some(value)
          break
        }
      }
      match found {
        Some(value) => value
        None =>
          return Err(
            webm_stream_error(
              input,
              Unsupported,
              "tracks",
              "No AV1 video TrackEntry",
              element.start,
            ),
          )
      }
    }
  }
  if selected.track_type != 1 || !selected.codec_av1 {
    return Err(
      webm_stream_error(
        input,
        Unsupported,
        "tracks",
        "Selected track is not V_AV1 video",
        element.start,
      ),
    )
  }
  if selected.content_encoded {
    return Err(
      webm_stream_error(
        input,
        Unsupported,
        "tracks",
        "Compressed or encrypted TrackEntry is unsupported",
        element.start,
      ),
    )
  }
  if !selected.track_timestamp_scale_one {
    return Err(
      webm_stream_error(
        input,
        Unsupported,
        "tracks",
        "Non-unit TrackTimestampScale is unsupported",
        element.start,
      ),
    )
  }
  if selected.width <= 0 || selected.height <= 0 {
    return Err(
      webm_stream_error(
        input,
        InvalidData,
        "tracks/video",
        "V_AV1 track has no PixelWidth/PixelHeight",
        element.start,
      ),
    )
  }
  if selected.width > self.limits.max_frame_pixels / selected.height {
    return Err(
      webm_stream_error(
        input,
        LimitExceeded,
        "tracks/video",
        "Track dimensions exceed max_frame_pixels",
        element.start,
      ),
    )
  }
  let codec_private = match selected.codec_private {
    Some(value) => value
    None =>
      return Err(
        webm_stream_error(
          input,
          InvalidData,
          "tracks",
          "V_AV1 track has no CodecPrivate",
          element.start,
        ),
      )
  }
  let codec_private_start = webm_stream_codec_private_offset(
    input.bytes,
    element,
    selected.number,
  )
  let codec_initialization = match av1_demux_av1c(codec_private) {
    Ok(value) => value
    Err(error) => {
      let mapped = {
        ..error,
        byte_offset: match error.byte_offset {
          Some(at) =>
            Some(input.base_offset + codec_private_start.to_int64() + at)
          None => Some(input.base_offset + element.start.to_int64())
        },
      }
      return Err(mapped)
    }
  }
  let sequence = match av1_sequence_info(codec_initialization) {
    Some(value) => value
    None =>
      return Err(
        webm_stream_error(
          input,
          InvalidData,
          "tracks/video",
          "CodecPrivate has no usable sequence header",
          element.start,
        ),
      )
  }
  if selected.width != sequence.width || selected.height != sequence.height {
    return Err(
      webm_stream_error(
        input,
        InvalidData,
        "tracks/video",
        "Pixel dimensions do not match AV1 sequence maxima",
        element.start,
      ),
    )
  }
  self.track_numbers = []
  for value in tracks {
    self.track_numbers.push(value.number)
  }
  self.selected = Some({ ..selected, codec_private: None, })
  self.track = Some({
    format: WebM,
    track_id: selected.number,
    width: selected.width,
    height: selected.height,
    timescale: WEBM_NANOS,
    movie_timescale: None,
    edits: [],
    codec_initialization,
    packets: [],
  })
  Ok(())
}

///|
fn webm_stream_parse_group(
  data : Array[Byte],
  child : WebmElement,
  tracks : Array[Int64],
  selected : WebmTrack,
) -> Result[(WebmBlock?, Int64?, Bool), DecodeError] {
  if child.unknown {
    return Err(
      webm_error(
        Unsupported,
        "cluster/blockgroup",
        "Unknown-sized BlockGroup",
        child.start,
      ),
    )
  }
  let group_children : Array[WebmElement] = []
  match webm_element_children(data, child, group_children, 3) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let mut block : WebmBlock? = None
  let mut saw_block = false
  let mut duration : Int64? = None
  let mut reference = false
  let mut reference_zero = false
  let mut unsupported_extra = false
  for item in group_children {
    if item.id == WEBM_BLOCK {
      if saw_block {
        return Err(
          webm_error(
            InvalidData,
            "cluster/blockgroup",
            "Duplicate Block",
            item.start,
          ),
        )
      }
      saw_block = true
      let block_track = match
        webm_block_track_number(data, item.payload, item.end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !tracks.contains(block_track) {
        return Err(
          webm_error(
            InvalidData,
            "block",
            "Block references an unknown track",
            item.start,
          ),
        )
      }
      if block_track == selected.number {
        block = Some(
          match
            webm_block_track(
              data,
              item.payload,
              item.end,
              [selected],
              block_group=true,
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          },
        )
      }
    } else if item.id == WEBM_BLOCK_DURATION {
      if duration is Some(_) {
        return Err(
          webm_error(
            InvalidData,
            "cluster/blockgroup",
            "Duplicate BlockDuration",
            item.start,
          ),
        )
      }
      duration = Some(
        match webm_uint(data, item.payload, item.end) {
          Ok(value) => value
          Err(error) => return Err(error)
        },
      )
    } else if item.id == WEBM_REFERENCE_BLOCK {
      if item.end <= item.payload || item.end - item.payload > 8 {
        return Err(
          webm_error(
            InvalidData,
            "cluster/blockgroup",
            "Invalid ReferenceBlock integer",
            item.start,
          ),
        )
      }
      let mut zero = true
      for position in item.payload..<item.end {
        if data[position].to_int() != 0 {
          zero = false
        }
      }
      if reference_zero || (zero && reference) {
        return Err(
          webm_error(
            InvalidData,
            "cluster/blockgroup",
            "ReferenceBlock zero must be the only reference",
            item.start,
          ),
        )
      }
      if zero {
        reference_zero = true
      }
      reference = true
    } else if item.id == WEBM_CODEC_STATE ||
      item.id == WEBM_DISCARD_PADDING ||
      item.id == WEBM_BLOCK_ADDITIONS {
      unsupported_extra = true
    }
  }
  if !saw_block {
    return Err(
      webm_error(
        InvalidData,
        "cluster/blockgroup",
        "BlockGroup has no Block",
        child.start,
      ),
    )
  }
  let value = match block {
    Some(value) => value
    None => return Ok((None, duration, reference))
  }
  if unsupported_extra {
    return Err(
      webm_error(
        Unsupported,
        "cluster/blockgroup",
        "Unsupported BlockGroup payload",
        child.start,
      ),
    )
  }
  Ok((Some(value), duration, reference))
}

///|
fn Av1WebmStreamState::enqueue_block(
  self : Av1WebmStreamState,
  input : ContainerStreamInput,
  block : WebmBlock,
  duration_ticks : Int64?,
  reference : Bool,
  is_block_group : Bool,
) -> Result[Unit, DecodeError] {
  let selected = match self.selected {
    Some(value) => value
    None =>
      return Err(
        webm_stream_error(
          input,
          InvalidState,
          "webm.stream",
          "Selected track is unavailable while parsing a block",
          block.frames[0].start,
        ),
      )
  }
  let cluster_time = match self.cluster_timestamp {
    Some(value) => value
    None =>
      return Err(
        webm_stream_error(
          input,
          Unsupported,
          "cluster",
          "Streaming requires Cluster Timestamp before selected blocks",
          block.frames[0].start,
        ),
      )
  }
  let frame_count = block.frames.length()
  if frame_count > self.limits.max_frames - self.packet_count {
    return Err(
      webm_stream_error(
        input,
        LimitExceeded,
        "webm",
        "Packet count exceeds max_frames",
        block.frames[0].start,
      ),
    )
  }
  let base_ticks = match
    webm_i64_add(cluster_time, block.timecode, block.frames[0].start) {
    Ok(value) => value
    Err(error) => return Err(webm_stream_rebase(input, error))
  }
  for i in 0..<frame_count {
    let frame = block.frames[i]
    let timing = match
      webm_laced_timing(
        duration_ticks,
        selected.default_duration,
        self.timestamp_scale,
        frame_count,
        i,
        frame.start,
      ) {
      Ok(value) => value
      Err(error) => return Err(webm_stream_rebase(input, error))
    }
    let timestamp_base = match
      webm_scale_ticks(base_ticks, self.timestamp_scale, frame.start) {
      Ok(value) => value
      Err(error) => return Err(webm_stream_rebase(input, error))
    }
    let timestamp_unshifted : Int64? = match timing.1 {
      Some(offset) =>
        Some(
          match webm_i64_add(timestamp_base, offset, frame.start) {
            Ok(value) => value
            Err(error) => return Err(webm_stream_rebase(input, error))
          },
        )
      None => None
    }
    let timestamp = match timestamp_unshifted {
      Some(value) =>
        match selected.codec_delay {
          Some(delay) =>
            Some(
              match webm_i64_sub(value, delay, frame.start) {
                Ok(result) => result
                Err(error) => return Err(webm_stream_rebase(input, error))
              },
            )
          None => Some(value)
        }
      None => None
    }
    self.queue.push({
      data: webm_copy(input.bytes, frame.start, frame.end),
      presentation_timestamp: timestamp,
      decode_timestamp: None,
      duration: timing.0,
      sync_sample: Some(
        if reference {
          false
        } else if is_block_group {
          true
        } else {
          block.keyframe
        },
      ),
    })
    self.packet_count += 1
  }
  Ok(())
}

///|
fn Av1WebmStreamState::finish_cluster(
  self : Av1WebmStreamState,
  input : ContainerStreamInput,
) -> Result[Unit, DecodeError] {
  if self.cluster_timestamp is None {
    let at = match self.cluster_start {
      Some(value) => value
      None => input.offset()
    }
    return Err({
      kind: InvalidData,
      context: "cluster",
      message: "Cluster has no Timestamp",
      byte_offset: Some(at),
    })
  }
  self.cluster_end = None
  self.cluster_unknown = false
  self.cluster_start = None
  self.cluster_timestamp = None
  self.stage = WebmInSegment
  Ok(())
}

///|
fn Av1WebmStreamState::finish_segment(
  self : Av1WebmStreamState,
) -> Result[Unit, DecodeError] {
  if !self.saw_info || !self.saw_tracks {
    let at = match self.segment_start {
      Some(value) => value
      None => 0L
    }
    return Err({
      kind: InvalidData,
      context: "segment",
      message: "Segment lacks Info or Tracks",
      byte_offset: Some(at),
    })
  }
  self.stage = if self.segment_unknown { WebmDone } else { WebmAfterSegment }
  Ok(())
}

///|
fn Av1WebmStreamState::step_ebml(
  self : Av1WebmStreamState,
  input : ContainerStreamInput,
  eof : Bool,
) -> Result[ContainerStreamStep, DecodeError] {
  match webm_stream_probe_element(input, None, true) {
    Err(error) => Err(error)
    Ok(WebmProbeWait) =>
      if eof {
        Err(
          webm_stream_error(
            input,
            TruncatedInput,
            "ebml",
            "Incomplete EBML header",
            input.start,
          ),
        )
      } else {
        Ok(Wait)
      }
    Ok(WebmProbeReady(element)) => {
      if element.id != WEBM_EBML {
        return Err(
          webm_stream_error(
            input,
            InvalidData,
            "webm",
            "Input does not start with EBML",
            element.start,
          ),
        )
      }
      if element.unknown {
        return Err(
          webm_stream_error(
            input,
            InvalidData,
            "ebml",
            "EBML header cannot be unknown-sized",
            element.start,
          ),
        )
      }
      match webm_parse_ebml_header(input.bytes, element) {
        Err(error) => Err(webm_stream_rebase(input, error))
        Ok(_) => {
          input.consume(element.end - element.start)
          self.stage = WebmNeedSegment
          Ok(Progress)
        }
      }
    }
  }
}

///|
fn Av1WebmStreamState::step_segment_header(
  self : Av1WebmStreamState,
  input : ContainerStreamInput,
  eof : Bool,
) -> Result[ContainerStreamStep, DecodeError] {
  match webm_stream_probe_element(input, None, false) {
    Err(error) => Err(error)
    Ok(WebmProbeWait) =>
      if eof {
        Err(
          webm_stream_error(
            input,
            TruncatedInput,
            "webm",
            "Missing Segment element",
            input.start,
          ),
        )
      } else {
        Ok(Wait)
      }
    Ok(WebmProbeReady(element)) =>
      if element.id == WEBM_SEGMENT {
        if self.saw_segment {
          return Err(
            webm_stream_error(
              input,
              InvalidData,
              "webm",
              "Duplicate Segment element",
              element.start,
            ),
          )
        }
        self.saw_segment = true
        self.segment_start = Some(input.base_offset + element.start.to_int64())
        self.segment_unknown = element.unknown
        self.segment_elements = 0
        self.segment_end = if element.unknown {
          None
        } else {
          Some(input.base_offset + element.end.to_int64())
        }
        input.consume(element.payload - element.start)
        self.stage = WebmInSegment
        Ok(Progress)
      } else if element.id == WEBM_VOID || element.id == WEBM_CRC32 {
        if element.unknown {
          Err(
            webm_stream_error(
              input,
              Unsupported,
              "webm",
              "Unknown-sized root Void/CRC",
              element.start,
            ),
          )
        } else {
          // Root globals may occur before Segment, but require their complete
          // finite payload before consumption.
          let full = match webm_stream_probe_element(input, None, true) {
            Err(error) => return Err(error)
            Ok(WebmProbeWait) =>
              return if eof {
                Err(
                  webm_stream_error(
                    input,
                    TruncatedInput,
                    "webm",
                    "Truncated root Void/CRC",
                    element.start,
                  ),
                )
              } else {
                Ok(Wait)
              }
            Ok(WebmProbeReady(value)) => value
          }
          input.consume(full.end - full.start)
          Ok(Progress)
        }
      } else {
        Err(
          webm_stream_error(
            input,
            InvalidData,
            "webm",
            "Missing Segment element",
            element.start,
          ),
        )
      }
  }
}

///|
fn Av1WebmStreamState::step_segment(
  self : Av1WebmStreamState,
  input : ContainerStreamInput,
  eof : Bool,
) -> Result[ContainerStreamStep, DecodeError] {
  let current = input.offset()
  match self.segment_end {
    Some(end) if current > end =>
      return Err(
        webm_stream_error(
          input,
          InvalidData,
          "segment",
          "Input passed Segment boundary",
          input.start,
        ),
      )
    Some(end) if current == end =>
      return match self.finish_segment() {
        Err(error) => return Err(error)
        Ok(_) => return self.step(input, eof)
      }
    _ => ()
  }
  if input.available() == 0 {
    if eof {
      match self.segment_end {
        Some(end) if current < end =>
          Err(
            webm_stream_error(
              input,
              TruncatedInput,
              "segment",
              "Truncated finite Segment",
              input.start,
            ),
          )
        _ =>
          match self.finish_segment() {
            Err(error) => Err(error)
            Ok(_) => self.step(input, eof)
          }
      }
    } else {
      Ok(Wait)
    }
  } else {
    let header = match
      webm_stream_probe_element(input, self.segment_end, false) {
      Err(error) => return Err(error)
      Ok(WebmProbeWait) =>
        return if eof {
          Err(
            webm_stream_error(
              input,
              TruncatedInput,
              "segment",
              "Truncated Segment child header",
              input.start,
            ),
          )
        } else {
          Ok(Wait)
        }
      Ok(WebmProbeReady(value)) => value
    }
    let element = if header.id == WEBM_CLUSTER {
      header
    } else {
      match webm_stream_probe_element(input, self.segment_end, true) {
        Err(error) => return Err(error)
        Ok(WebmProbeWait) =>
          return if eof {
            Err(
              webm_stream_error(
                input,
                TruncatedInput,
                "segment",
                "Truncated Segment child",
                header.start,
              ),
            )
          } else {
            Ok(Wait)
          }
        Ok(WebmProbeReady(value)) => value
      }
    }
    if element.unknown && element.id != WEBM_CLUSTER {
      return Err(
        webm_stream_error(
          input,
          Unsupported,
          "segment",
          "Unknown-sized non-Cluster element",
          element.start,
        ),
      )
    }
    if self.segment_elements >= WEBM_MAX_ELEMENTS {
      return Err(
        webm_stream_error(
          input,
          LimitExceeded,
          "segment",
          "Segment element count exceeds parser bound",
          element.start,
        ),
      )
    }
    self.segment_elements += 1
    if element.id == WEBM_INFO {
      if self.saw_info {
        return Err(
          webm_stream_error(
            input,
            InvalidData,
            "segment",
            "Duplicate Info element",
            element.start,
          ),
        )
      }
      if element.unknown {
        return Err(
          webm_stream_error(
            input,
            Unsupported,
            "info",
            "Unknown-sized Info element",
            element.start,
          ),
        )
      }
      self.timestamp_scale = match webm_parse_info(input.bytes, element) {
        Ok(value) => value
        Err(error) => return Err(webm_stream_rebase(input, error))
      }
      self.saw_info = true
      input.consume(element.end - element.start)
      Ok(Progress)
    } else if element.id == WEBM_TRACKS {
      if self.saw_tracks {
        return Err(
          webm_stream_error(
            input,
            InvalidData,
            "segment",
            "Duplicate Tracks element",
            element.start,
          ),
        )
      }
      if element.unknown {
        return Err(
          webm_stream_error(
            input,
            Unsupported,
            "tracks",
            "Unknown-sized Tracks element",
            element.start,
          ),
        )
      }
      match self.webm_stream_parse_tracks(input, element) {
        Err(error) => Err(error)
        Ok(_) => {
          self.saw_tracks = true
          input.consume(element.end - element.start)
          Ok(Progress)
        }
      }
    } else if element.id == WEBM_CLUSTER {
      if self.track is None || !self.saw_info || !self.saw_tracks {
        return Err(
          webm_stream_error(
            input,
            Unsupported,
            "segment",
            "Streaming requires Info and Tracks before Cluster data",
            element.start,
          ),
        )
      }
      self.cluster_start = Some(input.base_offset + element.start.to_int64())
      self.cluster_unknown = element.unknown
      self.cluster_elements = 0
      self.cluster_end = if element.unknown {
        None
      } else {
        Some(input.base_offset + element.end.to_int64())
      }
      self.cluster_timestamp = None
      input.consume(element.payload - element.start)
      self.stage = WebmInCluster
      Ok(Progress)
    } else if element.id == WEBM_SEGMENT {
      Err(
        webm_stream_error(
          input,
          Unsupported,
          "segment",
          "Nested Segment element is unsupported",
          element.start,
        ),
      )
    } else {
      input.consume(element.end - element.start)
      Ok(Progress)
    }
  }
}

///|
fn Av1WebmStreamState::step_cluster(
  self : Av1WebmStreamState,
  input : ContainerStreamInput,
  eof : Bool,
) -> Result[ContainerStreamStep, DecodeError] {
  let current = input.offset()
  let logical_end = match self.cluster_end {
    Some(value) => Some(value)
    None => self.segment_end
  }
  match logical_end {
    Some(end) if current > end =>
      return Err(
        webm_stream_error(
          input,
          InvalidData,
          "cluster",
          "Input passed Cluster boundary",
          input.start,
        ),
      )
    Some(end) if current == end =>
      return match self.finish_cluster(input) {
        Err(error) => Err(error)
        Ok(_) => self.step(input, eof)
      }
    _ => ()
  }
  if input.available() == 0 {
    if eof && self.cluster_unknown {
      match self.finish_cluster(input) {
        Err(error) => Err(error)
        Ok(_) => self.step(input, eof)
      }
    } else if eof {
      Err(
        webm_stream_error(
          input,
          TruncatedInput,
          "cluster",
          "Truncated Cluster",
          input.start,
        ),
      )
    } else {
      Ok(Wait)
    }
  } else {
    // The header-only probe lets an unknown-sized Cluster stop immediately at
    // the next Segment-level sibling, without buffering that sibling payload.
    let header = match webm_stream_probe_element(input, logical_end, false) {
      Err(error) => return Err(error)
      Ok(WebmProbeWait) =>
        return if eof {
          Err(
            webm_stream_error(
              input,
              TruncatedInput,
              "cluster",
              "Truncated Cluster child header",
              input.start,
            ),
          )
        } else {
          Ok(Wait)
        }
      Ok(WebmProbeReady(value)) => value
    }
    if self.cluster_unknown &&
      webm_segment_child_id(header.id) &&
      header.id != WEBM_VOID &&
      header.id != WEBM_CRC32 {
      match self.finish_cluster(input) {
        Err(error) => Err(error)
        Ok(_) => self.step(input, eof)
      }
    } else {
      if self.cluster_elements >= WEBM_MAX_ELEMENTS {
        return Err(
          webm_stream_error(
            input,
            LimitExceeded,
            "cluster",
            "Cluster element count exceeds parser bound",
            header.start,
          ),
        )
      }
      if header.unknown {
        return Err(
          webm_stream_error(
            input,
            Unsupported,
            "cluster",
            "Unknown-sized nested element",
            header.start,
          ),
        )
      }
      let element = match webm_stream_probe_element(input, logical_end, true) {
        Err(error) => return Err(error)
        Ok(WebmProbeWait) =>
          return if eof {
            Err(
              webm_stream_error(
                input,
                TruncatedInput,
                "cluster",
                "Truncated Cluster child",
                header.start,
              ),
            )
          } else {
            Ok(Wait)
          }
        Ok(WebmProbeReady(value)) => value
      }
      self.cluster_elements += 1
      if element.id == WEBM_CLUSTER_TIMESTAMP {
        if self.cluster_timestamp is Some(_) {
          return Err(
            webm_stream_error(
              input,
              InvalidData,
              "cluster",
              "Duplicate Cluster Timestamp",
              element.start,
            ),
          )
        }
        self.cluster_timestamp = Some(
          match webm_uint(input.bytes, element.payload, element.end) {
            Ok(value) => value
            Err(error) => return Err(webm_stream_rebase(input, error))
          },
        )
      } else if element.id == WEBM_SIMPLE_BLOCK {
        let block_track = match
          webm_block_track_number(input.bytes, element.payload, element.end) {
          Ok(value) => value
          Err(error) => return Err(webm_stream_rebase(input, error))
        }
        if !self.webm_stream_track_is_known(block_track) {
          return Err(
            webm_stream_error(
              input,
              InvalidData,
              "block",
              "Block references an unknown track",
              element.start,
            ),
          )
        }
        if self.selected is Some(selected) && block_track == selected.number {
          let block = match
            webm_block_track(input.bytes, element.payload, element.end, [
              selected,
            ]) {
            Ok(value) => value
            Err(error) => return Err(webm_stream_rebase(input, error))
          }
          match self.enqueue_block(input, block, None, false, false) {
            Err(error) => return Err(error)
            Ok(_) => ()
          }
        }
      } else if element.id == WEBM_BLOCK_GROUP {
        let selected = match self.selected {
          Some(value) => value
          None =>
            return Err(
              webm_stream_error(
                input,
                InvalidState,
                "webm.stream",
                "Missing selected track",
                element.start,
              ),
            )
        }
        let parsed = match
          webm_stream_parse_group(
            input.bytes,
            element,
            self.track_numbers,
            selected,
          ) {
          Ok(value) => value
          Err(error) => return Err(webm_stream_rebase(input, error))
        }
        match parsed.0 {
          Some(block) =>
            match self.enqueue_block(input, block, parsed.1, parsed.2, true) {
              Err(error) => return Err(error)
              Ok(_) => ()
            }
          None => ()
        }
      }
      input.consume(element.end - element.start)
      Ok(Progress)
    }
  }
}

///|
fn Av1WebmStreamState::step_after_segment(
  self : Av1WebmStreamState,
  input : ContainerStreamInput,
  eof : Bool,
) -> Result[ContainerStreamStep, DecodeError] {
  if input.available() == 0 {
    if eof {
      self.stage = WebmDone
      return Ok(End)
    }
    return Ok(Wait)
  }
  match webm_stream_probe_element(input, None, true) {
    Err(error) => Err(error)
    Ok(WebmProbeWait) =>
      if eof {
        Err(
          webm_stream_error(
            input,
            TruncatedInput,
            "webm",
            "Truncated trailing global element",
            input.start,
          ),
        )
      } else {
        Ok(Wait)
      }
    Ok(WebmProbeReady(element)) => {
      if element.unknown {
        return Err(
          webm_stream_error(
            input,
            Unsupported,
            "webm",
            "Unknown-sized root Void/CRC",
            element.start,
          ),
        )
      }
      if element.id == WEBM_VOID || element.id == WEBM_CRC32 {
        input.consume(element.end - element.start)
        Ok(Progress)
      } else if element.id == WEBM_SEGMENT {
        Err(
          webm_stream_error(
            input,
            Unsupported,
            "webm",
            "Multiple Segment elements are unsupported",
            element.start,
          ),
        )
      } else {
        Err(
          webm_stream_error(
            input,
            InvalidData,
            "webm",
            "Unexpected non-global data after Segment",
            element.start,
          ),
        )
      }
    }
  }
}

///|
fn Av1WebmStreamState::step(
  self : Av1WebmStreamState,
  input : ContainerStreamInput,
  eof : Bool,
) -> Result[ContainerStreamStep, DecodeError] {
  match self.webm_stream_take_packet() {
    Some(packet) => return Ok(Packet(packet))
    None => ()
  }
  match self.stage {
    WebmNeedEbml => self.step_ebml(input, eof)
    WebmNeedSegment => self.step_segment_header(input, eof)
    WebmInSegment => self.step_segment(input, eof)
    WebmInCluster => self.step_cluster(input, eof)
    WebmAfterSegment => self.step_after_segment(input, eof)
    WebmDone => Ok(End)
  }
}
