///|
/// Pure MoonBit ISO Base Media File Format demux for AV1 `av01` tracks.
///
/// The parser deliberately keeps the public result small: samples are returned
/// in decode order, with raw media timestamps in the track timescale. The
/// container parser owns every returned byte buffer, so callers can release
/// the input after this function returns.
let mp4_moov : Int = 0x6D6F6F76

///|
let mp4_mvhd : Int = 0x6D766864

///|
let mp4_trak : Int = 0x7472616B

///|
let mp4_tkhd_box : Int = 0x746B6864

///|
let mp4_mdia : Int = 0x6D646961

///|
let mp4_mdhd : Int = 0x6D646864

///|
let mp4_hdlr : Int = 0x68646C72

///|
let mp4_minf : Int = 0x6D696E66

///|
let mp4_dinf : Int = 0x64696E66

///|
let mp4_dref : Int = 0x64726566

///|
let mp4_stbl : Int = 0x7374626C

///|
let mp4_stsd : Int = 0x73747364

///|
let mp4_stts : Int = 0x73747473

///|
let mp4_ctts : Int = 0x63747473

///|
let mp4_stsc : Int = 0x73747363

///|
let mp4_stsz : Int = 0x7374737A

///|
let mp4_stz2 : Int = 0x73747A32

///|
let mp4_stco : Int = 0x7374636F

///|
let mp4_co64 : Int = 0x636F3634

///|
let mp4_stss : Int = 0x73747373

///|
let mp4_av01 : Int = 0x61763031

///|
let mp4_av1c : Int = 0x61763143

///|
let mp4_mdat : Int = 0x6D646174

///|
let mp4_edts : Int = 0x65647473

///|
let mp4_elst : Int = 0x656C7374

///|
let mp4_mvex : Int = 0x6D766578

///|
let mp4_trex : Int = 0x74726578

///|
let mp4_moof : Int = 0x6D6F6F66

///|
let mp4_traf : Int = 0x74726166

///|
let mp4_tfhd : Int = 0x74666864

///|
let mp4_tfdt_box : Int = 0x74666474

///|
let mp4_trun : Int = 0x7472756E

///|
let mp4_vide : Int = 0x76696465

///|
let mp4_url : Int = 0x75726C20

///|
let mp4_urn : Int = 0x75726E20

///|
let mp4_sinf : Int = 0x73696E66

///|
let mp4_i64_max : Int64 = 9223372036854775807L

///|
let mp4_i64_min : Int64 = -9223372036854775807L - 1L

///|
priv struct Mp4Box {
  typ : Int
  start : Int
  payload : Int
  end : Int
  parent : Int
}

///|
priv struct Mp4Mdat {
  start : Int
  end : Int
}

///|
priv struct Mp4StscEntry {
  first_chunk : Int64
  samples_per_chunk : Int64
  description_index : Int
}

///|
priv struct Mp4TimingEntry {
  count : Int64
  value : Int64
}

///|
priv struct Mp4Track {
  id : Int64
  width : Int
  height : Int
  timescale : Int64
  av1c : Array[Byte]
  stbl_box : Int
  has_sample_tables : Bool
  movie_timescale : Int64?
  edits : Array[Av1TrackEdit]
}

///|
priv struct Mp4Trex {
  track_id : Int64
  description_index : Int
  duration : Int64
  size : Int
  flags : Int
}

///|
priv struct Mp4Tfhd {
  track_id : Int64
  flags : Int
  base_offset : Int64?
  description_index : Int
  duration : Int64?
  size : Int?
  sample_flags : Int?
}

///|
priv struct Mp4FragmentState {
  mut next_decode_time : Int64
}

///|
priv struct Mp4Sample {
  offset : Int64
  size : Int
  dts : Int64
  pts : Int64
  duration : Int64
  sync : Bool?
}

///|
priv suberror Mp4Error {
  Diagnostic(DecodeError)
}

///|
fn mp4_error(
  kind : DecodeErrorKind,
  message : String,
  offset? : Int? = None,
) -> Mp4Error {
  Mp4Error::Diagnostic(decode_error(kind, "mp4", message, offset~))
}

///|
fn mp4_u8(data : Array[Byte], p : Int, end : Int) -> Int raise Mp4Error {
  if p < 0 || p >= end || p >= data.length() {
    raise mp4_error(TruncatedInput, "MP4 field is truncated", offset=Some(p))
  }
  data[p].to_int()
}

///|
fn mp4_u16(data : Array[Byte], p : Int, end : Int) -> Int raise Mp4Error {
  mp4_u8(data, p, end) * 256 + mp4_u8(data, p + 1, end)
}

///|
fn mp4_bits32(data : Array[Byte], p : Int, end : Int) -> Int raise Mp4Error {
  mp4_u8(data, p, end) * 16777216 +
  mp4_u8(data, p + 1, end) * 65536 +
  mp4_u8(data, p + 2, end) * 256 +
  mp4_u8(data, p + 3, end)
}

///|
fn mp4_u32_wide(data : Array[Byte], p : Int, end : Int) -> Int64 raise Mp4Error {
  let bits = mp4_bits32(data, p, end).to_int64()
  if bits < 0L {
    bits + 4294967296L
  } else {
    bits
  }
}

///|
fn mp4_u32(data : Array[Byte], p : Int, end : Int) -> Int raise Mp4Error {
  let value = mp4_bits32(data, p, end)
  if value < 0 {
    raise mp4_error(
      LimitExceeded,
      "MP4 size or count exceeds addressable Int",
      offset=Some(p),
    )
  }
  value
}

///|
fn mp4_i32(data : Array[Byte], p : Int, end : Int) -> Int64 raise Mp4Error {
  mp4_bits32(data, p, end).to_int64()
}

///|
fn mp4_i16(data : Array[Byte], p : Int, end : Int) -> Int raise Mp4Error {
  let n = mp4_u16(data, p, end)
  if n >= 32768 {
    n - 65536
  } else {
    n
  }
}

///|
fn mp4_i64(data : Array[Byte], p : Int, end : Int) -> Int64 raise Mp4Error {
  let hi = mp4_bits32(data, p, end).to_int64()
  (hi << 32) | mp4_u32_wide(data, p + 4, end)
}

///|
fn mp4_u64(data : Array[Byte], p : Int, end : Int) -> Int64 raise Mp4Error {
  let hi = mp4_u32_wide(data, p, end)
  let lo = mp4_u32_wide(data, p + 4, end)
  if hi > 2147483647L {
    raise mp4_error(
      Unsupported,
      "64-bit MP4 value exceeds supported range",
      offset=Some(p),
    )
  }
  (hi << 32) | lo
}

///|
fn mp4_add(a : Int64, b : Int64) -> Int64 raise Mp4Error {
  if (b > 0L && a > mp4_i64_max - b) || (b < 0L && a < mp4_i64_min - b) {
    raise mp4_error(InvalidData, "MP4 integer arithmetic overflows")
  }
  a + b
}

///|
fn mp4_copy(
  data : Array[Byte],
  from : Int,
  to : Int,
) -> Array[Byte] raise Mp4Error {
  if from < 0 || to < from || to > data.length() {
    raise mp4_error(
      TruncatedInput,
      "MP4 payload is outside the input",
      offset=Some(from),
    )
  }
  Array::makei(to - from, i => data[from + i])
}

///|
fn mp4_index(boxes : Array[Mp4Box], start : Int) -> Int {
  for i in 0..<boxes.length() {
    if boxes[i].start == start {
      return i
    }
  }
  -1
}

///|
fn mp4_child(boxes : Array[Mp4Box], parent : Int, typ : Int) -> Mp4Box? {
  for box in boxes {
    if box.parent == parent && box.typ == typ {
      return Some(box)
    }
  }
  None
}

///|
fn mp4_children(
  boxes : Array[Mp4Box],
  parent : Int,
  typ : Int,
) -> Array[Mp4Box] {
  let out : Array[Mp4Box] = []
  for box in boxes {
    if box.parent == parent && box.typ == typ {
      out.push(box)
    }
  }
  out
}

///|
fn mp4_is_container(typ : Int) -> Bool {
  typ == mp4_moov ||
  typ == mp4_trak ||
  typ == mp4_mdia ||
  typ == mp4_minf ||
  typ == mp4_dinf ||
  typ == mp4_stbl ||
  typ == mp4_mvex ||
  typ == mp4_moof ||
  typ == mp4_traf ||
  typ == mp4_edts ||
  typ == mp4_av01
}

///|
fn mp4_is_fullbox_children(typ : Int) -> Bool {
  typ == mp4_stsd || typ == mp4_dref
}

///|
fn mp4_walk(
  data : Array[Byte],
  from : Int,
  to : Int,
  parent : Int,
  boxes : Array[Mp4Box],
  depth : Int,
) -> Unit raise Mp4Error {
  if depth > 64 {
    raise mp4_error(
      LimitExceeded,
      "MP4 box nesting exceeds 64 levels",
      offset=Some(from),
    )
  }
  let mut p = from
  while p < to {
    if to - p < 8 {
      raise mp4_error(
        TruncatedInput,
        "Incomplete MP4 box header",
        offset=Some(p),
      )
    }
    let size32 = mp4_u32(data, p, to)
    let typ = mp4_bits32(data, p + 4, to)
    let mut header = 8
    let mut size = size32.to_int64()
    if size32 == 1 {
      header = 16
      size = mp4_u64(data, p + 8, to)
    } else if size32 == 0 {
      size = (to - p).to_int64()
    }
    if size < header.to_int64() || size > (to - p).to_int64() {
      raise mp4_error(
        InvalidData,
        "MP4 box size is outside its parent",
        offset=Some(p),
      )
    }
    let size_i = size.to_int()
    let end = p + size_i
    let payload = p + header
    if boxes.length() >= 65536 {
      raise mp4_error(LimitExceeded, "MP4 exceeds 65536 boxes", offset=Some(p))
    }
    let index = boxes.length()
    boxes.push({ typ, start: p, payload, end, parent, })
    if mp4_is_container(typ) || mp4_is_fullbox_children(typ) {
      let child_from = if mp4_is_fullbox_children(typ) {
        payload + 8
      } else if typ == mp4_av01 {
        p + 86
      } else {
        payload
      }
      if child_from > end {
        raise mp4_error(
          TruncatedInput,
          "MP4 container header is truncated",
          offset=Some(payload),
        )
      }
      mp4_walk(data, child_from, end, index, boxes, depth + 1)
    }
    p = end
  }
}

///|
fn mp4_boxes(data : Array[Byte]) -> Result[Array[Mp4Box], DecodeError] {
  try {
    let out : Array[Mp4Box] = []
    mp4_walk(data, 0, data.length(), -1, out, 0)
    Ok(out)
  } catch {
    Mp4Error::Diagnostic(error) => Err(error)
  }
}

///|
fn mp4_fullbox(data : Array[Byte], box : Mp4Box) -> (Int, Int) raise Mp4Error {
  let version = mp4_u8(data, box.payload, box.end)
  let flags = mp4_bits32(data, box.payload, box.end) & 0xFFFFFF
  (version, flags)
}

///|
fn mp4_validate_mdat(
  samples : Array[Mp4Sample],
  data : Array[Byte],
  mdats : Array[Mp4Mdat],
) -> Unit raise Mp4Error {
  for sample in samples {
    if sample.offset < 0 {
      raise mp4_error(InvalidData, "Negative MP4 sample offset")
    }
    let mut found = false
    for mdat in mdats {
      let start = mdat.start.to_int64()
      let end = mdat.end.to_int64()
      if sample.offset >= start &&
        sample.offset <= end &&
        sample.size.to_int64() <= end - sample.offset {
        found = true
        break
      }
    }
    if !found {
      raise mp4_error(InvalidData, "MP4 sample range is outside an mdat box")
    }
    if sample.offset > data.length().to_int64() - sample.size.to_int64() {
      raise mp4_error(TruncatedInput, "MP4 sample range exceeds the input")
    }
  }
}

///|
fn mp4_find_mdat(boxes : Array[Mp4Box]) -> Array[Mp4Mdat] {
  let out : Array[Mp4Mdat] = []
  for box in boxes {
    if box.parent == -1 && box.typ == mp4_mdat {
      out.push({ start: box.payload, end: box.end, })
    }
  }
  out
}

///|
fn mp4_parse_tkhd(
  data : Array[Byte],
  box : Mp4Box,
) -> (Int64, Int, Int) raise Mp4Error {
  let version = mp4_u8(data, box.payload, box.end)
  if version > 1 {
    raise mp4_error(Unsupported, "Unsupported tkhd version")
  }
  let id_at = if version == 0 { box.payload + 12 } else { box.payload + 20 }
  let geometry_at = if version == 0 {
    box.payload + 76
  } else {
    box.payload + 88
  }
  let id = mp4_u32_wide(data, id_at, box.end)
  let width_fixed = mp4_u32_wide(data, geometry_at, box.end)
  let height_fixed = mp4_u32_wide(data, geometry_at + 4, box.end)
  let width = (width_fixed / 65536L).to_int()
  let height = (height_fixed / 65536L).to_int()
  if id <= 0L {
    raise mp4_error(InvalidData, "MP4 track has invalid id")
  }
  (id, width, height)
}

///|
fn mp4_timescale(data : Array[Byte], box : Mp4Box) -> Int64 raise Mp4Error {
  let (version, flags) = mp4_fullbox(data, box)
  if version > 1 || flags != 0 {
    raise mp4_error(Unsupported, "Unsupported mdhd version")
  }
  let at = if version == 0 { box.payload + 12 } else { box.payload + 20 }
  let value = mp4_u32_wide(data, at, box.end)
  if value <= 0L {
    raise mp4_error(InvalidData, "MP4 track has no positive timescale")
  }
  value
}

///|
fn mp4_handler_is_video(
  data : Array[Byte],
  box : Mp4Box,
) -> Bool raise Mp4Error {
  let (version, flags) = mp4_fullbox(data, box)
  if version != 0 || flags != 0 {
    raise mp4_error(Unsupported, "Unsupported hdlr version")
  }
  mp4_u32(data, box.payload + 8, box.end) == mp4_vide
}

///|
fn mp4_check_data_reference(
  data : Array[Byte],
  boxes : Array[Mp4Box],
  stbl : Int,
) -> Unit raise Mp4Error {
  let minf = boxes[stbl].parent
  let dinf = match mp4_child(boxes, minf, mp4_dinf) {
    Some(value) => value
    None => return
  }
  let di = mp4_index(boxes, dinf.start)
  let dref = match mp4_child(boxes, di, mp4_dref) {
    Some(value) => value
    None => raise mp4_error(InvalidData, "dinf has no dref")
  }
  let (dref_version, dref_flags) = mp4_fullbox(data, dref)
  if dref_version != 0 || dref_flags != 0 {
    raise mp4_error(Unsupported, "Unsupported dref FullBox version or flags")
  }
  let count = mp4_u32(data, dref.payload + 4, dref.end)
  let entries = mp4_children(boxes, mp4_index(boxes, dref.start), mp4_url)
  let urns = mp4_children(boxes, mp4_index(boxes, dref.start), mp4_urn)
  if count != entries.length() + urns.length() || count != 1 {
    raise mp4_error(Unsupported, "Multiple or unsupported MP4 data references")
  }
  if entries.length() != 1 {
    raise mp4_error(Unsupported, "External MP4 data reference is unsupported")
  }
  let url = entries[0]
  let (version, flags) = mp4_fullbox(data, url)
  if version != 0 || flags != 1 {
    raise mp4_error(Unsupported, "External MP4 data reference is unsupported")
  }
}

///|
fn mp4_stsd_av1c(
  data : Array[Byte],
  boxes : Array[Mp4Box],
  stsd : Mp4Box,
) -> (Int, Int, Array[Byte])? raise Mp4Error {
  let (stsd_version, stsd_flags) = mp4_fullbox(data, stsd)
  if stsd_version != 0 || stsd_flags != 0 {
    raise mp4_error(Unsupported, "Unsupported stsd FullBox version or flags")
  }
  let entry_count = mp4_u32(data, stsd.payload + 4, stsd.end)
  let all_entries : Array[Mp4Box] = []
  let stsd_index = mp4_index(boxes, stsd.start)
  for box in boxes {
    if box.parent == stsd_index {
      all_entries.push(box)
    }
  }
  if entry_count != all_entries.length() {
    raise mp4_error(InvalidData, "stsd entry count does not match its boxes")
  }
  if all_entries.length() == 0 {
    return None
  }
  let mut has_av1 = false
  for entry in all_entries {
    if entry.typ == mp4_av01 {
      has_av1 = true
    }
  }
  if !has_av1 {
    return None
  }
  if all_entries.length() != 1 {
    raise mp4_error(Unsupported, "MP4 sample-entry switches are unsupported")
  }
  let entry = all_entries[0]
  if entry.end - entry.start < 86 {
    raise mp4_error(TruncatedInput, "av01 sample entry is truncated")
  }
  let data_reference = mp4_u16(data, entry.start + 14, entry.end)
  if data_reference != 1 {
    raise mp4_error(
      Unsupported,
      "av01 sample entry uses an external data reference",
    )
  }
  let width = mp4_u16(data, entry.start + 32, entry.end)
  let height = mp4_u16(data, entry.start + 34, entry.end)
  if width <= 0 || height <= 0 {
    raise mp4_error(InvalidData, "av01 sample entry has invalid dimensions")
  }
  if mp4_child(boxes, mp4_index(boxes, entry.start), mp4_sinf) is Some(_) {
    raise mp4_error(Unsupported, "Encrypted MP4 sample entries are unsupported")
  }
  let av1c_children = mp4_children(
    boxes,
    mp4_index(boxes, entry.start),
    mp4_av1c,
  )
  if av1c_children.length() != 1 {
    raise mp4_error(
      InvalidData,
      "av01 sample entry must contain exactly one av1C",
    )
  }
  let av1c_box = av1c_children[0]
  let record = mp4_copy(data, av1c_box.payload, av1c_box.end)
  let initialization = match av1_demux_av1c(record) {
    Ok(value) => value
    Err(error) => raise Mp4Error::Diagnostic(error)
  }
  match av1_sequence_info(initialization) {
    Some(sequence) =>
      if width != sequence.width || height != sequence.height {
        raise mp4_error(
          InvalidData,
          "av01 dimensions exceed the av1C sequence header",
        )
      }
    None => ()
  }
  Some((width, height, initialization))
}

///|
fn mp4_parse_movie_timescale(
  data : Array[Byte],
  boxes : Array[Mp4Box],
  moov : Mp4Box,
) -> Int64? raise Mp4Error {
  let mi = mp4_index(boxes, moov.start)
  let mvhd = match mp4_child(boxes, mi, mp4_mvhd) {
    Some(value) => value
    None => return None
  }
  let (version, flags) = mp4_fullbox(data, mvhd)
  if version > 1 || flags != 0 {
    raise mp4_error(Unsupported, "Unsupported mvhd version")
  }
  let at = if version == 0 { mvhd.payload + 12 } else { mvhd.payload + 20 }
  let timescale = mp4_u32_wide(data, at, mvhd.end)
  if timescale <= 0L {
    raise mp4_error(InvalidData, "Movie has no positive timescale")
  }
  Some(timescale)
}

///|
fn mp4_parse_edits(
  data : Array[Byte],
  boxes : Array[Mp4Box],
  trak_index : Int,
  movie_timescale : Int64?,
) -> (Int64?, Array[Av1TrackEdit]) raise Mp4Error {
  let out : Array[Av1TrackEdit] = []
  let edts = mp4_children(boxes, trak_index, mp4_edts)
  if edts.length() == 0 {
    return (movie_timescale, out)
  }
  if edts.length() != 1 {
    raise mp4_error(InvalidData, "Track contains multiple edit list containers")
  }
  let ei = mp4_index(boxes, edts[0].start)
  let elsts = mp4_children(boxes, ei, mp4_elst)
  if elsts.length() != 1 {
    raise mp4_error(
      InvalidData,
      "Track edit container does not contain one elst",
    )
  }
  let movie_scale = match movie_timescale {
    Some(value) => value
    None =>
      raise mp4_error(InvalidData, "Track edit list has no movie timescale")
  }
  let elst = elsts[0]
  let (version, flags) = mp4_fullbox(data, elst)
  if flags != 0 || version > 1 {
    raise mp4_error(Unsupported, "Unsupported elst version or flags")
  }
  let count = mp4_u32(data, elst.payload + 4, elst.end)
  let entry_width = if version == 0 { 12 } else { 20 }
  if count > (elst.end - elst.payload - 8) / entry_width {
    raise mp4_error(TruncatedInput, "elst entries are truncated")
  }
  let mut p = elst.payload + 8
  for _ in 0..<count {
    let duration = if version == 0 {
      mp4_u32_wide(data, p, elst.end)
    } else {
      mp4_u64(data, p, elst.end)
    }
    let media_time = if version == 0 {
      mp4_i32(data, p + 4, elst.end)
    } else {
      mp4_i64(data, p + 8, elst.end)
    }
    let rate_at = if version == 0 { p + 8 } else { p + 16 }
    let rate_integer = mp4_i16(data, rate_at, elst.end)
    let rate_fraction = mp4_i16(data, rate_at + 2, elst.end)
    if duration < 0L || media_time < -1L {
      raise mp4_error(
        InvalidData,
        "elst contains an invalid duration or media time",
      )
    }
    if rate_integer != 1 || rate_fraction != 0 {
      raise mp4_error(
        Unsupported,
        "Only unit-rate MP4 edit lists are supported",
      )
    }
    out.push({ duration, media_time, media_rate: 65536, })
    p += entry_width
  }
  if p != elst.end {
    raise mp4_error(InvalidData, "elst has trailing bytes")
  }
  (Some(movie_scale), out)
}

///|
fn mp4_parse_track(
  data : Array[Byte],
  boxes : Array[Mp4Box],
  trak : Mp4Box,
  movie_timescale : Int64?,
  requested_id : Int64?,
) -> Mp4Track? raise Mp4Error {
  let ti = mp4_index(boxes, trak.start)
  let tkhd = match mp4_child(boxes, ti, mp4_tkhd_box) {
    Some(value) => value
    None => raise mp4_error(InvalidData, "trak has no tkhd")
  }
  let (id, tk_width, tk_height) = mp4_parse_tkhd(data, tkhd)
  let mdia = match mp4_child(boxes, ti, mp4_mdia) {
    Some(value) => value
    None => raise mp4_error(InvalidData, "trak has no mdia")
  }
  let mi = mp4_index(boxes, mdia.start)
  let hdlr = match mp4_child(boxes, mi, mp4_hdlr) {
    Some(value) => value
    None => raise mp4_error(InvalidData, "mdia has no hdlr")
  }
  if !mp4_handler_is_video(data, hdlr) {
    return None
  }
  let mdhd = match mp4_child(boxes, mi, mp4_mdhd) {
    Some(value) => value
    None => raise mp4_error(InvalidData, "mdia has no mdhd")
  }
  let timescale = mp4_timescale(data, mdhd)
  let minf = match mp4_child(boxes, mi, mp4_minf) {
    Some(value) => value
    None => raise mp4_error(InvalidData, "mdia has no minf")
  }
  let mini = mp4_index(boxes, minf.start)
  let stbl = match mp4_child(boxes, mini, mp4_stbl) {
    Some(value) => value
    None => raise mp4_error(InvalidData, "minf has no stbl")
  }
  let si = mp4_index(boxes, stbl.start)
  let stsd = match mp4_child(boxes, si, mp4_stsd) {
    Some(value) => value
    None => raise mp4_error(InvalidData, "stbl has no stsd")
  }
  match mp4_stsd_av1c(data, boxes, stsd) {
    None => None
    Some((entry_width, entry_height, av1c)) => {
      mp4_check_data_reference(data, boxes, si)
      let (track_movie_timescale, edits) = match requested_id {
        Some(wanted) if wanted != id => (None, [])
        _ => mp4_parse_edits(data, boxes, ti, movie_timescale)
      }
      // tkhd is a presentation hint and may be zero in unusual files; the
      // coded sample entry dimensions are the dimensions returned to callers.
      let width = if entry_width > 0 { entry_width } else { tk_width }
      let height = if entry_height > 0 { entry_height } else { tk_height }
      let has_tables = mp4_child(boxes, si, mp4_stts) is Some(_) ||
        mp4_child(boxes, si, mp4_stsz) is Some(_) ||
        mp4_child(boxes, si, mp4_stz2) is Some(_)
      Some({
        id,
        width,
        height,
        timescale,
        av1c,
        stbl_box: si,
        has_sample_tables: has_tables,
        movie_timescale: track_movie_timescale,
        edits,
      })
    }
  }
}

///|
/// Parse only the metadata carried by one complete moov box. The returned
/// track owns all variable-size metadata; box indexes are scratch state and
/// are intentionally not retained by callers.
fn mp4_parse_moov_metadata(
  data : Array[Byte],
  requested_id : Int64?,
  limits : DecodeLimits,
) -> (Mp4Track, Mp4Trex?) raise Mp4Error {
  let boxes = match mp4_boxes(data) {
    Ok(value) => value
    Err(error) => raise Mp4Error::Diagnostic(error)
  }
  let moov = match mp4_child(boxes, -1, mp4_moov) {
    Some(value) => value
    None => raise mp4_error(InvalidData, "MP4 metadata has no moov box")
  }
  let movie_timescale = mp4_parse_movie_timescale(data, boxes, moov)
  let moovi = mp4_index(boxes, moov.start)
  let tracks = mp4_children(boxes, moovi, mp4_trak)
  let mut selected : Mp4Track? = None
  for trak in tracks {
    let candidate = mp4_parse_track(
      data, boxes, trak, movie_timescale, requested_id,
    )
    match candidate {
      None => ()
      Some(track) =>
        match requested_id {
          Some(wanted) =>
            if track.id == wanted {
              selected = Some(track)
              break
            }
          None => {
            selected = Some(track)
            break
          }
        }
    }
  }
  let track = match selected {
    Some(value) => value
    None => raise mp4_error(Unsupported, "No selected AV1 video track")
  }
  if track.height <= 0 || track.width > limits.max_frame_pixels / track.height {
    raise mp4_error(LimitExceeded, "Track dimensions exceed max_frame_pixels")
  }
  let trex = mp4_find_trex(data, boxes, moov, track.id)
  (track, trex)
}

///|
fn mp4_parse_timing_table(
  data : Array[Byte],
  box : Mp4Box,
  signed : Bool,
) -> Array[Mp4TimingEntry] raise Mp4Error {
  let (version, flags) = mp4_fullbox(data, box)
  if flags != 0 ||
    (signed && version != 0 && version != 1) ||
    (!signed && version != 0) {
    raise mp4_error(Unsupported, "Unsupported MP4 timing table version")
  }
  let count = mp4_u32(data, box.payload + 4, box.end)
  if count > (box.end - box.payload - 8) / 8 {
    raise mp4_error(
      TruncatedInput,
      "MP4 timing table count exceeds its payload",
    )
  }
  let entries : Array[Mp4TimingEntry] = []
  let mut p = box.payload + 8
  for _ in 0..<count {
    let n = mp4_u32_wide(data, p, box.end)
    let value = if signed && version == 1 {
      mp4_i32(data, p + 4, box.end)
    } else {
      mp4_u32_wide(data, p + 4, box.end)
    }
    if n <= 0L || (value < 0L && !signed) {
      raise mp4_error(
        InvalidData,
        "MP4 timing table contains an invalid entry",
        offset=Some(p),
      )
    }
    entries.push({ count: n, value, })
    p += 8
  }
  if p != box.end {
    raise mp4_error(InvalidData, "MP4 timing table has trailing bytes")
  }
  entries
}

///|
fn mp4_expand_sizes(
  data : Array[Byte],
  box : Mp4Box,
  max_count : Int,
) -> Array[Int] raise Mp4Error {
  let (version, flags) = mp4_fullbox(data, box)
  if version != 0 || flags != 0 {
    raise mp4_error(Unsupported, "Unsupported stsz version or flags")
  }
  let fixed = mp4_u32(data, box.payload + 4, box.end)
  let count = mp4_u32(data, box.payload + 8, box.end)
  if count > max_count {
    raise mp4_error(LimitExceeded, "MP4 sample count exceeds max_frames")
  }
  let sizes : Array[Int] = []
  if fixed != 0 {
    for _ in 0..<count {
      sizes.push(fixed)
    }
    if box.payload + 12 != box.end {
      raise mp4_error(InvalidData, "stsz has trailing bytes")
    }
  } else {
    let mut p = box.payload + 12
    for _ in 0..<count {
      sizes.push(mp4_u32(data, p, box.end))
      p += 4
    }
    if p != box.end {
      raise mp4_error(InvalidData, "stsz has trailing bytes")
    }
  }
  sizes
}

///|
fn mp4_expand_stz2(
  data : Array[Byte],
  box : Mp4Box,
  max_count : Int,
) -> Array[Int] raise Mp4Error {
  let (version, flags) = mp4_fullbox(data, box)
  if version != 0 || flags != 0 {
    raise mp4_error(Unsupported, "Unsupported stz2 version or flags")
  }
  let field_size = mp4_u8(data, box.payload + 7, box.end)
  if field_size != 4 && field_size != 8 && field_size != 16 {
    raise mp4_error(Unsupported, "Unsupported stz2 field size")
  }
  let count = mp4_u32(data, box.payload + 8, box.end)
  if count > max_count {
    raise mp4_error(LimitExceeded, "MP4 sample count exceeds max_frames")
  }
  let sizes : Array[Int] = []
  let mut p = box.payload + 12
  if field_size == 4 {
    let mut i = 0
    while i < count {
      let packed = mp4_u8(data, p, box.end)
      sizes.push(packed >> 4)
      i += 1
      if i < count {
        sizes.push(packed & 15)
        i += 1
      }
      p += 1
    }
  } else if field_size == 8 {
    for _ in 0..<count {
      sizes.push(mp4_u8(data, p, box.end))
      p += 1
    }
  } else {
    for _ in 0..<count {
      sizes.push(mp4_u16(data, p, box.end))
      p += 2
    }
  }
  if p != box.end {
    raise mp4_error(InvalidData, "stz2 has trailing bytes")
  }
  sizes
}

///|
fn mp4_expand_stts(
  data : Array[Byte],
  box : Mp4Box,
  sample_count : Int,
) -> Array[Mp4TimingEntry] raise Mp4Error {
  let entries = mp4_parse_timing_table(data, box, false)
  let mut total = 0L
  for entry in entries {
    total = mp4_add(total, entry.count)
  }
  if total != sample_count.to_int64() {
    raise mp4_error(InvalidData, "stts sample count does not match stsz")
  }
  entries
}

///|
fn mp4_expand_ctts(
  data : Array[Byte],
  box : Mp4Box,
  sample_count : Int,
) -> Array[Mp4TimingEntry] raise Mp4Error {
  let entries = mp4_parse_timing_table(data, box, true)
  let mut total = 0L
  for entry in entries {
    total = mp4_add(total, entry.count)
  }
  if total != sample_count.to_int64() {
    raise mp4_error(InvalidData, "ctts sample count does not match stsz")
  }
  entries
}

///|
fn mp4_parse_stsc(
  data : Array[Byte],
  box : Mp4Box,
) -> Array[Mp4StscEntry] raise Mp4Error {
  let (version, flags) = mp4_fullbox(data, box)
  if version != 0 || flags != 0 {
    raise mp4_error(Unsupported, "Unsupported stsc version or flags")
  }
  let count = mp4_u32(data, box.payload + 4, box.end)
  if count > (box.end - box.payload - 8) / 12 {
    raise mp4_error(TruncatedInput, "stsc count exceeds its payload")
  }
  let out : Array[Mp4StscEntry] = []
  let mut p = box.payload + 8
  let mut previous = 0L
  for _ in 0..<count {
    let first = mp4_u32_wide(data, p, box.end)
    let per = mp4_u32_wide(data, p + 4, box.end)
    let desc = mp4_u32(data, p + 8, box.end)
    if first <= previous || first <= 0L || per <= 0L || desc <= 0 {
      raise mp4_error(InvalidData, "Invalid stsc entry", offset=Some(p))
    }
    previous = first
    out.push({
      first_chunk: first,
      samples_per_chunk: per,
      description_index: desc,
    })
    p += 12
  }
  if p != box.end {
    raise mp4_error(InvalidData, "stsc has trailing bytes")
  }
  if out.length() > 0 && out[0].first_chunk != 1L {
    raise mp4_error(InvalidData, "stsc does not start at chunk one")
  }
  out
}

///|
fn mp4_parse_offsets(
  data : Array[Byte],
  box : Mp4Box,
) -> Array[Int64] raise Mp4Error {
  let (version, flags) = mp4_fullbox(data, box)
  if version != 0 || flags != 0 {
    raise mp4_error(
      Unsupported,
      "Unsupported chunk offset table version or flags",
    )
  }
  let count = mp4_u32(data, box.payload + 4, box.end)
  let out : Array[Int64] = []
  let mut p = box.payload + 8
  let entry_width = if box.typ == mp4_co64 { 8 } else { 4 }
  if count > (box.end - p) / entry_width {
    raise mp4_error(TruncatedInput, "Chunk offset count exceeds its payload")
  }
  for _ in 0..<count {
    out.push(
      if box.typ == mp4_co64 {
        mp4_u64(data, p, box.end)
      } else {
        mp4_u32_wide(data, p, box.end)
      },
    )
    p += if box.typ == mp4_co64 { 8 } else { 4 }
  }
  if p != box.end {
    raise mp4_error(InvalidData, "Chunk offset table has trailing bytes")
  }
  out
}

///|
fn mp4_parse_sync(
  data : Array[Byte],
  box : Mp4Box,
  count : Int,
) -> Array[Bool] raise Mp4Error {
  let (version, flags) = mp4_fullbox(data, box)
  if version != 0 || flags != 0 {
    raise mp4_error(Unsupported, "Unsupported stss version or flags")
  }
  let n = mp4_u32(data, box.payload + 4, box.end)
  if n > (box.end - box.payload - 8) / 4 {
    raise mp4_error(TruncatedInput, "stss count exceeds its payload")
  }
  let sync = Array::make(count, false)
  let mut p = box.payload + 8
  let mut previous = 0
  for _ in 0..<n {
    let sample = mp4_u32(data, p, box.end)
    if sample <= previous || sample <= 0 || sample > count {
      raise mp4_error(InvalidData, "Invalid stss sample number", offset=Some(p))
    }
    sync[sample - 1] = true
    previous = sample
    p += 4
  }
  if p != box.end {
    raise mp4_error(InvalidData, "stss has trailing bytes")
  }
  sync
}

///|
/// Expand an ordinary sample table into absolute sample descriptors. This
/// helper deliberately does not inspect mdat boxes: incremental demuxers can
/// retain the bounded table metadata while the media payload arrives later.
fn mp4_table_sample_descriptors(
  data : Array[Byte],
  boxes : Array[Mp4Box],
  track : Mp4Track,
  limits : DecodeLimits,
) -> Array[Mp4Sample] raise Mp4Error {
  let si = track.stbl_box
  let stsz = mp4_child(boxes, si, mp4_stsz)
  let stz2 = mp4_child(boxes, si, mp4_stz2)
  let sizes = match (stsz, stz2) {
    (Some(_), Some(_)) =>
      raise mp4_error(InvalidData, "stsz and stz2 both present")
    (Some(box), None) => mp4_expand_sizes(data, box, limits.max_frames)
    (None, Some(box)) => mp4_expand_stz2(data, box, limits.max_frames)
    (None, None) => return []
  }
  let count = sizes.length()
  if count == 0 {
    return []
  }
  let stts = match mp4_child(boxes, si, mp4_stts) {
    Some(value) => value
    None => raise mp4_error(InvalidData, "Non-empty stsz has no stts")
  }
  let stts_entries = mp4_expand_stts(data, stts, count)
  let ctts_entries = match mp4_child(boxes, si, mp4_ctts) {
    Some(value) => mp4_expand_ctts(data, value, count)
    None => []
  }
  let stsc = match mp4_child(boxes, si, mp4_stsc) {
    Some(value) => mp4_parse_stsc(data, value)
    None => raise mp4_error(InvalidData, "Non-empty stsz has no stsc")
  }
  let offset_box = match
    (mp4_child(boxes, si, mp4_stco), mp4_child(boxes, si, mp4_co64)) {
    (Some(_), Some(_)) =>
      raise mp4_error(InvalidData, "stco and co64 both present")
    (Some(value), None) => value
    (None, Some(value)) => value
    (None, None) =>
      raise mp4_error(InvalidData, "Non-empty stsz has no chunk offsets")
  }
  let offsets = mp4_parse_offsets(data, offset_box)
  if stsc.length() == 0 || offsets.length() == 0 {
    raise mp4_error(InvalidData, "MP4 sample table has no chunks")
  }
  let sample_offsets : Array[Int64] = []
  let mut sample_index = 0
  let mut entry_index = 0
  for chunk_zero in 0..<offsets.length() {
    let chunk = (chunk_zero + 1).to_int64()
    while entry_index + 1 < stsc.length() &&
          chunk >= stsc[entry_index + 1].first_chunk {
      entry_index += 1
    }
    let entry = stsc[entry_index]
    if entry.samples_per_chunk > (count - sample_index).to_int64() {
      raise mp4_error(InvalidData, "stsc expands beyond stsz")
    }
    if entry.description_index != 1 {
      raise mp4_error(
        Unsupported,
        "MP4 sample-description switches are unsupported",
      )
    }
    let mut off = offsets[chunk_zero]
    for _ in 0..<entry.samples_per_chunk.to_int() {
      if sample_index >= count {
        raise mp4_error(InvalidData, "stsc expands beyond stsz")
      }
      sample_offsets.push(off)
      off = mp4_add(off, sizes[sample_index].to_int64())
      sample_index += 1
    }
  }
  if sample_index != count {
    raise mp4_error(InvalidData, "stsc does not cover all stsz samples")
  }
  let sync = match mp4_child(boxes, si, mp4_stss) {
    Some(value) => mp4_parse_sync(data, value, count)
    None => Array::make(count, true)
  }
  let samples : Array[Mp4Sample] = []
  let mut dts = 0L
  let mut timing_index = 0
  let mut timing_left = if stts_entries.length() == 0 {
    0L
  } else {
    stts_entries[0].count
  }
  let mut ctts_index = 0
  let mut ctts_left = if ctts_entries.length() == 0 {
    0L
  } else {
    ctts_entries[0].count
  }
  for i in 0..<count {
    if timing_left == 0L {
      timing_index += 1
      timing_left = stts_entries[timing_index].count
    }
    let duration = stts_entries[timing_index].value
    timing_left -= 1L
    let ctts = if ctts_entries.length() == 0 {
      0L
    } else {
      if ctts_left == 0L {
        ctts_index += 1
        ctts_left = ctts_entries[ctts_index].count
      }
      let value = ctts_entries[ctts_index].value
      ctts_left -= 1L
      value
    }
    let pts = mp4_add(dts, ctts)
    if duration <= 0L || sizes[i] <= 0 {
      raise mp4_error(
        InvalidData,
        "MP4 sample has no positive duration or payload",
      )
    }
    samples.push({
      offset: sample_offsets[i],
      size: sizes[i],
      dts,
      pts,
      duration,
      sync: Some(sync[i]),
    })
    dts = mp4_add(dts, duration)
  }
  samples
}

///|
/// Complete-file ordinary-table expansion, retaining the original API and
/// validation behavior for the batch demuxer.
fn mp4_table_samples(
  data : Array[Byte],
  boxes : Array[Mp4Box],
  track : Mp4Track,
  limits : DecodeLimits,
  mdats : Array[Mp4Mdat],
) -> Array[Mp4Sample] raise Mp4Error {
  let samples = mp4_table_sample_descriptors(data, boxes, track, limits)
  mp4_validate_mdat(samples, data, mdats)
  samples
}

///|
fn mp4_parse_trex(data : Array[Byte], box : Mp4Box) -> Mp4Trex raise Mp4Error {
  let (version, flags) = mp4_fullbox(data, box)
  if version != 0 || flags != 0 || box.end - box.payload != 24 {
    raise mp4_error(InvalidData, "Invalid trex box")
  }
  {
    track_id: mp4_u32_wide(data, box.payload + 4, box.end),
    description_index: mp4_u32(data, box.payload + 8, box.end),
    duration: mp4_u32_wide(data, box.payload + 12, box.end),
    size: mp4_u32(data, box.payload + 16, box.end),
    flags: mp4_u32(data, box.payload + 20, box.end),
  }
}

///|
fn mp4_parse_tfhd(data : Array[Byte], box : Mp4Box) -> Mp4Tfhd raise Mp4Error {
  let (version, flags) = mp4_fullbox(data, box)
  if version != 0 || (flags & 0xFCFFC4) != 0 {
    raise mp4_error(Unsupported, "Unsupported tfhd flags")
  }
  if (flags & 0x010000) != 0 {
    raise mp4_error(Unsupported, "tfhd duration-is-empty is unsupported")
  }
  let mut p = box.payload + 4
  let track_id = mp4_u32_wide(data, p, box.end)
  p += 4
  let base = if (flags & 1) != 0 {
    let x = mp4_u64(data, p, box.end)
    p += 8
    Some(x)
  } else {
    None
  }
  let desc = if (flags & 2) != 0 {
    let x = mp4_u32(data, p, box.end)
    p += 4
    x
  } else {
    1
  }
  let duration = if (flags & 8) != 0 {
    let x = mp4_u32_wide(data, p, box.end)
    p += 4
    Some(x)
  } else {
    None
  }
  let size = if (flags & 16) != 0 {
    let x = mp4_u32(data, p, box.end)
    p += 4
    Some(x)
  } else {
    None
  }
  let sample_flags = if (flags & 32) != 0 {
    let x = mp4_u32(data, p, box.end)
    p += 4
    Some(x)
  } else {
    None
  }
  if p != box.end || desc <= 0 {
    raise mp4_error(InvalidData, "Invalid tfhd payload")
  }
  {
    track_id,
    flags,
    base_offset: base,
    description_index: desc,
    duration,
    size,
    sample_flags,
  }
}

///|
fn mp4_parse_tfdt(data : Array[Byte], box : Mp4Box) -> Int64 raise Mp4Error {
  let (version, flags) = mp4_fullbox(data, box)
  let expected = if version == 0 { 8 } else if version == 1 { 12 } else { -1 }
  if flags != 0 || box.end - box.payload != expected {
    raise mp4_error(InvalidData, "Invalid tfdt box")
  }
  if version == 0 {
    mp4_u32_wide(data, box.payload + 4, box.end)
  } else {
    mp4_u64(data, box.payload + 4, box.end)
  }
}

///|
fn mp4_sample_flags_sync(flags : Int) -> Bool {
  (flags & 0x10000) == 0
}

///|
fn mp4_parse_trun(
  data : Array[Byte],
  box : Mp4Box,
  tfhd : Mp4Tfhd,
  trex : Mp4Trex?,
  state : Mp4FragmentState,
  base : Int64,
  next_data_offset : Int64?,
  max_frames : Int,
  out : Array[Mp4Sample],
) -> Int64 raise Mp4Error {
  let (version, flags) = mp4_fullbox(data, box)
  if version > 1 || (flags & 0xFFF0FA) != 0 {
    raise mp4_error(Unsupported, "Unsupported trun flags")
  }
  let count = mp4_u32(data, box.payload + 4, box.end)
  if count > max_frames - out.length() {
    raise mp4_error(LimitExceeded, "MP4 sample count exceeds max_frames")
  }
  if count > data.length() {
    raise mp4_error(
      LimitExceeded,
      "MP4 fragment sample count exceeds the input bound",
    )
  }
  let mut p = box.payload + 8
  let data_offset = if (flags & 1) != 0 {
    let value = mp4_i32(data, p, box.end)
    p += 4
    Some(value)
  } else {
    None
  }
  let first_flags = if (flags & 4) != 0 {
    let value = mp4_u32(data, p, box.end)
    p += 4
    Some(value)
  } else {
    None
  }
  let mut sample_offset = match data_offset {
    Some(value) => mp4_add(base, value)
    None =>
      match next_data_offset {
        Some(value) => value
        None => base
      }
  }
  let mut dts = state.next_decode_time
  for i in 0..<count {
    let duration = if (flags & 0x100) != 0 {
      let value = mp4_u32_wide(data, p, box.end)
      p += 4
      value
    } else {
      match (tfhd.duration, trex) {
        (Some(value), _) => value
        (None, Some(value)) => value.duration
        _ => 0L
      }
    }
    let size = if (flags & 0x200) != 0 {
      let value = mp4_u32(data, p, box.end)
      p += 4
      value
    } else {
      match (tfhd.size, trex) {
        (Some(value), _) => value
        (None, Some(value)) => value.size
        _ => 0
      }
    }
    let sample_flags = if (flags & 0x400) != 0 {
      let value = mp4_u32(data, p, box.end)
      p += 4
      Some(value)
    } else if i == 0 && first_flags is Some(_) {
      first_flags
    } else {
      match (tfhd.sample_flags, trex) {
        (Some(value), _) => Some(value)
        (None, Some(value)) => Some(value.flags)
        _ => None
      }
    }
    let composition = if (flags & 0x800) != 0 {
      if version == 1 {
        mp4_i32(data, p, box.end)
      } else {
        mp4_u32_wide(data, p, box.end)
      }
    } else {
      0L
    }
    if (flags & 0x800) != 0 {
      p += 4
    }
    if duration <= 0L {
      raise mp4_error(InvalidData, "trun sample has no positive duration")
    }
    let pts = mp4_add(dts, composition)
    if size <= 0 || sample_offset < 0L {
      raise mp4_error(InvalidData, "trun sample value overflows")
    }
    out.push({
      offset: sample_offset,
      size,
      dts,
      pts,
      duration,
      sync: sample_flags.map(mp4_sample_flags_sync),
    })
    sample_offset = mp4_add(sample_offset, size.to_int64())
    dts = mp4_add(dts, duration)
  }
  if p != box.end {
    raise mp4_error(InvalidData, "trun has trailing bytes")
  }
  state.next_decode_time = dts
  sample_offset
}

///|
/// Expand one moof into absolute sample descriptors. `state` is shared by the
/// caller across moofs so omitted tfdt boxes continue the decode timeline.
/// `moof_file_offset` is absolute even when `data` is a scratch moof buffer.
fn mp4_fragment_moof_samples(
  data : Array[Byte],
  boxes : Array[Mp4Box],
  moof : Mp4Box,
  track : Mp4Track,
  trex : Mp4Trex?,
  state : Mp4FragmentState,
  moof_file_offset : Int64,
  limits : DecodeLimits,
  out : Array[Mp4Sample],
) -> Unit raise Mp4Error {
  let mi = mp4_index(boxes, moof.start)
  let trafs = mp4_children(boxes, mi, mp4_traf)
  let mut previous_traf_end : Int64? = None
  let mut prior_traf_seen = false
  for traf in trafs {
    let ti = mp4_index(boxes, traf.start)
    let tfhd_box = match mp4_child(boxes, ti, mp4_tfhd) {
      Some(value) => value
      None => raise mp4_error(InvalidData, "traf has no tfhd")
    }
    let tfhd = mp4_parse_tfhd(data, tfhd_box)
    let had_prior_traf = prior_traf_seen
    prior_traf_seen = true
    if tfhd.track_id != track.id {
      previous_traf_end = None
      continue
    }
    if tfhd.description_index != 1 {
      raise mp4_error(Unsupported, "Fragment switches sample descriptions")
    }
    let implicit_base = tfhd.base_offset is None && (tfhd.flags & 0x020000) == 0
    if implicit_base && had_prior_traf && previous_traf_end is None {
      raise mp4_error(
        Unsupported,
        "Implicit fragment base after an unselected traf is unsupported",
      )
    }
    let tfdt_box = mp4_child(boxes, ti, mp4_tfdt_box)
    match tfdt_box {
      Some(value) => state.next_decode_time = mp4_parse_tfdt(data, value)
      None => ()
    }
    let truns = mp4_children(boxes, ti, mp4_trun)
    if truns.length() == 0 {
      raise mp4_error(InvalidData, "traf has no trun")
    }
    // Explicit tfhd bases are already absolute file offsets. The
    // default-base-is-moof flag is absolute too; only the legacy implicit
    // base chains from the selected traf's preceding run.
    let base = match tfhd.base_offset {
      Some(value) => value
      None =>
        if (tfhd.flags & 0x020000) != 0 {
          moof_file_offset
        } else {
          match previous_traf_end {
            Some(value) => value
            None => moof_file_offset
          }
        }
    }
    let mut next_data_offset : Int64? = None
    for trun in truns {
      next_data_offset = Some(
        mp4_parse_trun(
          data,
          trun,
          tfhd,
          trex,
          state,
          base,
          next_data_offset,
          limits.max_frames,
          out,
        ),
      )
    }
    // next_data_offset is deliberately reset for every traf, while the
    // decode-time state above persists over all selected trafs/moofs.
    previous_traf_end = next_data_offset
  }
}

///|
fn mp4_fragment_samples(
  data : Array[Byte],
  boxes : Array[Mp4Box],
  moofs : Array[Mp4Box],
  track : Mp4Track,
  trex : Mp4Trex?,
  limits : DecodeLimits,
  mdats : Array[Mp4Mdat],
) -> Array[Mp4Sample] raise Mp4Error {
  let out : Array[Mp4Sample] = []
  let state = { next_decode_time: 0L, }
  for moof in moofs {
    mp4_fragment_moof_samples(
      data,
      boxes,
      moof,
      track,
      trex,
      state,
      moof.start.to_int64(),
      limits,
      out,
    )
  }
  if out.length() == 0 {
    raise mp4_error(InvalidData, "Selected fragmented track has no samples")
  }
  mp4_validate_mdat(out, data, mdats)
  out
}

///|
fn mp4_find_trex(
  data : Array[Byte],
  boxes : Array[Mp4Box],
  moov : Mp4Box,
  track_id : Int64,
) -> Mp4Trex? raise Mp4Error {
  let mi = mp4_index(boxes, moov.start)
  let mvex = match mp4_child(boxes, mi, mp4_mvex) {
    Some(value) => value
    None => return None
  }
  let vi = mp4_index(boxes, mvex.start)
  for box in mp4_children(boxes, vi, mp4_trex) {
    let trex = mp4_parse_trex(data, box)
    if trex.track_id == track_id {
      if trex.description_index != 1 {
        raise mp4_error(
          Unsupported,
          "Fragment trex switches sample descriptions",
        )
      }
      return Some(trex)
    }
  }
  None
}

///|
fn mp4_has_fragment_track(
  data : Array[Byte],
  boxes : Array[Mp4Box],
  moofs : Array[Mp4Box],
  track_id : Int64,
) -> Bool raise Mp4Error {
  for moof in moofs {
    let mi = mp4_index(boxes, moof.start)
    for traf in mp4_children(boxes, mi, mp4_traf) {
      let ti = mp4_index(boxes, traf.start)
      let tfhd_box = match mp4_child(boxes, ti, mp4_tfhd) {
        Some(value) => value
        None => continue
      }
      let tfhd = mp4_parse_tfhd(data, tfhd_box)
      if tfhd.track_id == track_id {
        return true
      }
    }
  }
  false
}

///|
fn mp4_track_samples(
  data : Array[Byte],
  boxes : Array[Mp4Box],
  moov : Mp4Box,
  track : Mp4Track,
  limits : DecodeLimits,
  mdats : Array[Mp4Mdat],
) -> Array[Mp4Sample] raise Mp4Error {
  let moofs : Array[Mp4Box] = []
  for box in boxes {
    if box.parent == -1 && box.typ == mp4_moof {
      moofs.push(box)
    }
  }
  let has_fragment = mp4_has_fragment_track(data, boxes, moofs, track.id)
  if has_fragment {
    if track.has_sample_tables {
      let table_samples = mp4_table_samples(data, boxes, track, limits, mdats)
      if table_samples.length() > 0 {
        raise mp4_error(
          Unsupported,
          "Mixed ordinary and fragmented samples are unsupported",
        )
      }
    }
    let trex = mp4_find_trex(data, boxes, moov, track.id)
    mp4_fragment_samples(data, boxes, moofs, track, trex, limits, mdats)
  } else {
    mp4_table_samples(data, boxes, track, limits, mdats)
  }
}

///|
/// Demux an AV1 `av01` track from an ISO BMFF/MP4 byte buffer.
///
/// Samples are returned in decode order. `presentation_timestamp` and
/// `decode_timestamp` are raw media timestamps in `timescale` units; no
/// movie-level edit-list offset is applied. Selected-track edits are exposed
/// in the result; encryption, external data references, or sample-entry
/// switches return `Unsupported`.
pub fn av1_demux_mp4(
  data : Array[Byte],
  track_id? : Int64? = None,
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[Av1DemuxedTrack, DecodeError] {
  match av1_demux_validate_input(data, limits) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let boxes = match mp4_boxes(data) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let moov = match mp4_child(boxes, -1, mp4_moov) {
    Some(value) => value
    None => return Err(decode_error(InvalidData, "mp4", "MP4 has no moov box"))
  }
  let mdats = mp4_find_mdat(boxes)
  if mdats.length() == 0 {
    return Err(decode_error(InvalidData, "mp4", "MP4 has no mdat box"))
  }
  let movie_timescale = mp4_parse_movie_timescale(data, boxes, moov) catch {
    Mp4Error::Diagnostic(error) => return Err(error)
  }
  let moovi = mp4_index(boxes, moov.start)
  let tracks = mp4_children(boxes, moovi, mp4_trak)
  let mut selected : Mp4Track? = None
  for trak in tracks {
    let candidate = mp4_parse_track(
      data, boxes, trak, movie_timescale, track_id,
    ) catch {
      Mp4Error::Diagnostic(error) => return Err(error)
    }
    match candidate {
      None => ()
      Some(track) =>
        match track_id {
          Some(wanted) =>
            if track.id == wanted {
              selected = Some(track)
              break
            }
          None => {
            selected = Some(track)
            break
          }
        }
    }
  }
  let track = match selected {
    Some(value) => value
    None =>
      return Err(
        decode_error(Unsupported, "mp4", "No selected AV1 video track"),
      )
  }
  if track.width > limits.max_frame_pixels / track.height {
    return Err(
      decode_error(
        LimitExceeded,
        "mp4",
        "Track dimensions exceed max_frame_pixels",
      ),
    )
  }
  let samples = mp4_track_samples(data, boxes, moov, track, limits, mdats) catch {
    Mp4Error::Diagnostic(error) => return Err(error)
  }
  if samples.length() > limits.max_frames {
    return Err(
      decode_error(LimitExceeded, "mp4", "MP4 sample count exceeds max_frames"),
    )
  }
  let mut sample_bytes = 0
  for sample in samples {
    if sample.size > limits.max_input_bytes - sample_bytes {
      return Err(
        decode_error(
          LimitExceeded,
          "mp4",
          "Copied sample payloads exceed max_input_bytes",
        ),
      )
    }
    sample_bytes += sample.size
  }
  let packets : Array[Av1Packet] = []
  for sample in samples {
    let start = sample.offset.to_int()
    packets.push({
      data: Array::makei(sample.size, i => data[start + i]),
      presentation_timestamp: Some(sample.pts),
      decode_timestamp: Some(sample.dts),
      duration: Some(sample.duration),
      sync_sample: sample.sync,
    })
  }
  Ok({
    format: Mp4,
    track_id: track.id,
    width: track.width,
    height: track.height,
    timescale: track.timescale,
    movie_timescale: track.movie_timescale,
    edits: track.edits,
    codec_initialization: Array::makei(track.av1c.length(), i => track.av1c[i]),
    packets,
  })
}
