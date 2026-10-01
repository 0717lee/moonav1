///|
/// File containers carrying AV1 low-overhead temporal units.
pub(all) enum Av1ContainerFormat {
  Ivf
  Mp4
  WebM
} derive(Eq, Debug)

///|
/// One encoded temporal unit in container/decode order. Timestamps and
/// duration use the enclosing track's timescale. Unknown timing/sync fields
/// remain None instead of being inferred from presentation order.
/// The payload is owned and may be passed to the existing AV1 video decoder.
pub struct Av1Packet {
  data : Array[Byte]
  presentation_timestamp : Int64?
  decode_timestamp : Int64?
  duration : Int64?
  sync_sample : Bool?
}

///|
/// An ISO BMFF movie edit. duration uses movie_timescale; media_time uses
/// the track timescale and -1 denotes an empty edit. media_rate is signed
/// 16.16 fixed-point (65536 means normal playback). Demuxing retains edits
/// separately so that encoded preroll/reference packets are never discarded.
pub struct Av1TrackEdit {
  duration : Int64
  media_time : Int64
  media_rate : Int
}

///|
/// Selected AV1 video track. codec_initialization contains low-overhead OBUs,
/// without the four-byte av1C record header; prepend it to the first packet
/// when initializing a fresh AV1 decoder. Buffers do not alias the input.
/// max_frames in the demux policy limits packet count, not decoded pictures.
pub struct Av1DemuxedTrack {
  format : Av1ContainerFormat
  track_id : Int64
  width : Int
  height : Int
  timescale : Int64
  movie_timescale : Int64?
  edits : Array[Av1TrackEdit]
  codec_initialization : Array[Byte]
  packets : Array[Av1Packet]
}

///|
fn av1_demux_validate_input(
  data : Array[Byte],
  limits : DecodeLimits,
) -> Result[Unit, DecodeError] {
  if !decode_input_allowed(0, Some(limits)) {
    return Err(decode_error(InvalidData, "demux", "Invalid resource limits"))
  }
  if data.length() > limits.max_input_bytes {
    return Err(
      decode_error(LimitExceeded, "demux", "Container exceeds max_input_bytes"),
    )
  }
  Ok(())
}

///|
/// Shared MP4/WebM av1C configuration validation. The returned bytes are
/// initialization OBUs, not an Annex B length-prefixed stream.
fn av1_demux_av1c(data : Array[Byte]) -> Result[Array[Byte], DecodeError] {
  if data.length() < 4 {
    return Err(decode_error(TruncatedInput, "av1C", "Incomplete configuration"))
  }
  let marker_version = data[0].to_int()
  if (marker_version & 128) == 0 {
    return Err(decode_error(InvalidData, "av1C", "Missing marker bit"))
  }
  if (marker_version & 127) != 1 {
    return Err(decode_error(Unsupported, "av1C", "Unsupported record version"))
  }
  let profile = data[1].to_int() >> 5
  let level = data[1].to_int() & 31
  let flags = data[2].to_int()
  let high = (flags & 64) != 0
  let twelve = (flags & 32) != 0
  let mono = (flags & 16) != 0
  let sx = (flags & 8) != 0
  let sy = (flags & 4) != 0
  let position = flags & 3
  let delay = data[3].to_int()
  if profile > 2 {
    return Err(decode_error(Unsupported, "av1C", "Unsupported AV1 profile"))
  }
  if (level > 23 && level != 31) ||
    (level <= 7 && (flags & 128) != 0) ||
    (delay & 224) != 0 ||
    ((delay & 16) == 0 && (delay & 15) != 0) ||
    (twelve && (!high || profile != 2)) ||
    (sy && !sx) ||
    position == 3 ||
    ((!sx || !sy) && position != 0) ||
    (mono && (!sx || !sy || position != 0 || profile == 1)) ||
    (!mono && profile == 0 && (!sx || !sy)) ||
    (profile == 1 && (sx || sy)) ||
    (!mono && profile == 2 && !twelve && (!sx || sy)) {
    return Err(
      decode_error(InvalidData, "av1C", "Inconsistent configuration fields"),
    )
  }
  let obus = Array::makei(data.length() - 4, i => data[i + 4])
  let mut pos = 0
  let mut sequence_seen = false
  while pos < obus.length() {
    if (obus[pos].to_int() & 2) == 0 {
      return Err(
        decode_error(
          InvalidData,
          "av1C",
          "Configuration OBU requires a size field",
        ),
      )
    }
    let span = match av1_read_obu_span(obus, pos, true, obus.length()) {
      Ok(Some(value)) => value
      Err(error) =>
        return Err({
          ..error,
          context: "av1C/" + error.context,
          byte_offset: error.byte_offset.map(at => at + 4L),
        })
      Ok(None) =>
        return Err(decode_error(TruncatedInput, "av1C", "Incomplete OBU"))
    }
    if span.kind == 1 {
      if sequence_seen || pos != 0 {
        return Err(
          decode_error(
            InvalidData,
            "av1C",
            "Sequence header must occur once and first",
          ),
        )
      }
      sequence_seen = true
      let payload = Array::makei(span.end - span.payload_offset, i => {
        obus[span.payload_offset + i]
      })
      let details : Av1SequenceDetails = {
        level: 0,
        tier: 0,
        chroma_sample_position: 0,
      }
      let sequence = match
        av1_parse_sequence_payload_details(payload, Some(details)) {
        Some(value) => value
        None =>
          return Err(
            decode_error(InvalidData, "av1C", "Invalid sequence header"),
          )
      }
      let depth = if twelve { 12 } else if high { 10 } else { 8 }
      if details.level != level ||
        details.tier != flags >> 7 ||
        details.chroma_sample_position != position ||
        sequence.profile != profile ||
        sequence.bit_depth != depth ||
        sequence.monochrome != mono ||
        sequence.subsampling_x != sx ||
        sequence.subsampling_y != sy {
        return Err(
          decode_error(
            InvalidData,
            "av1C",
            "Record and sequence color configuration differ",
          ),
        )
      }
    } else if span.kind != 5 && span.kind != 15 {
      return Err(
        decode_error(
          InvalidData,
          "av1C",
          "Configuration contains a non-configuration OBU",
        ),
      )
    }
    pos = span.end
  }
  Ok(obus)
}

///|
/// Detect IVF, ISO BMFF or EBML from their file headers, or use an explicit
/// format. Only AV1 video tracks are selected. Parsing does not decode pixels.
pub fn av1_demux(
  data : Array[Byte],
  format? : Av1ContainerFormat? = None,
  track_id? : Int64? = None,
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[Av1DemuxedTrack, DecodeError] {
  match av1_demux_validate_input(data, limits) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let selected = match format {
    Some(value) => value
    None => {
      if data.length() < 4 {
        return Err(
          decode_error(TruncatedInput, "demux", "Incomplete file signature"),
        )
      }
      if data[0] == b'D' &&
        data[1] == b'K' &&
        data[2] == b'I' &&
        data[3] == b'F' {
        Ivf
      } else if data[0] == 0x1A &&
        data[1] == 0x45 &&
        data[2] == 0xDF &&
        data[3] == 0xA3 {
        WebM
      } else {
        if data.length() < 8 {
          return Err(
            decode_error(TruncatedInput, "demux", "Incomplete container header"),
          )
        }
        let kind = (data[4].to_int() << 24) |
          (data[5].to_int() << 16) |
          (data[6].to_int() << 8) |
          data[7].to_int()
        match kind {
          // ftyp, styp, moov, moof, mdat, free, skip, wide, uuid
          0x66747970
          | 0x73747970
          | 0x6D6F6F76
          | 0x6D6F6F66
          | 0x6D646174
          | 0x66726565
          | 0x736B6970
          | 0x77696465
          | 0x75756964 => Mp4
          _ =>
            return Err(
              decode_error(Unsupported, "demux", "Unrecognized video container"),
            )
        }
      }
    }
  }
  match selected {
    Ivf => {
      if track_id is Some(id) && id != 0L {
        return Err(
          decode_error(InvalidData, "ivf.track", "IVF has only track zero"),
        )
      }
      av1_demux_ivf(data, limits~)
    }
    Mp4 => av1_demux_mp4(data, track_id~, limits~)
    WebM => av1_demux_webm(data, track_id~, limits~)
  }
}
