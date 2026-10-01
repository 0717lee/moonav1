///|
/// Synthetic MP4 fixtures cover table expansion and fragment timing without
/// depending on a native muxer. The payload bytes are intentionally opaque;
/// this file tests the container envelope and ownership contract.
fn mp4_test_be32(data : Array[Byte], at : Int, value : Int) -> Unit {
  data[at] = ((value >> 24) & 255).to_byte()
  data[at + 1] = ((value >> 16) & 255).to_byte()
  data[at + 2] = ((value >> 8) & 255).to_byte()
  data[at + 3] = (value & 255).to_byte()
}

///|
fn mp4_test_type(name : String) -> Array[Byte] {
  Array::makei(4, i => name[i].to_int().to_byte())
}

///|
fn mp4_test_box(name : String, payload : Array[Byte]) -> Array[Byte] {
  let out = Array::make(payload.length() + 8, b'\x00')
  mp4_test_be32(out, 0, out.length())
  let typ = mp4_test_type(name)
  for i in 0..<4 {
    out[4 + i] = typ[i]
  }
  for i in 0..<payload.length() {
    out[8 + i] = payload[i]
  }
  out
}

///|
fn mp4_test_fullbox(
  version : Int,
  flags : Int,
  tail : Array[Byte],
) -> Array[Byte] {
  let out = Array::make(tail.length() + 4, b'\x00')
  out[0] = version.to_byte()
  out[1] = ((flags >> 16) & 255).to_byte()
  out[2] = ((flags >> 8) & 255).to_byte()
  out[3] = (flags & 255).to_byte()
  for i in 0..<tail.length() {
    out[4 + i] = tail[i]
  }
  out
}

///|
fn mp4_test_concat(parts : Array[Array[Byte]]) -> Array[Byte] {
  let out : Array[Byte] = []
  for part in parts {
    for byte in part {
      out.push(byte)
    }
  }
  out
}

///|
fn mp4_test_av1c() -> Array[Byte] {
  let out : Array[Byte] = [0x81, 0, 0x0C, 0]
  let sequence : Array[Byte] = [0x0A, 0x06, 0x18, 0x15, 0x7F, 0xFC, 0, 8]
  for byte in sequence {
    out.push(byte)
  }
  out
}

///|
fn mp4_test_tkhd(id : Int) -> Array[Byte] {
  let tail = Array::make(84, b'\x00')
  mp4_test_be32(tail, 8, id)
  mp4_test_be32(tail, 72, 64 << 16)
  mp4_test_be32(tail, 76, 64 << 16)
  mp4_test_box("tkhd", mp4_test_fullbox(0, 7, tail))
}

///|
fn mp4_test_mvhd() -> Array[Byte] {
  let tail = Array::make(20, b'\x00')
  mp4_test_be32(tail, 8, 1000)
  mp4_test_box("mvhd", mp4_test_fullbox(0, 0, tail))
}

///|
fn mp4_test_mdhd() -> Array[Byte] {
  let tail = Array::make(20, b'\x00')
  mp4_test_be32(tail, 8, 1000)
  mp4_test_box("mdhd", mp4_test_fullbox(0, 0, tail))
}

///|
fn mp4_test_hdlr_video() -> Array[Byte] {
  let tail = Array::make(20, b'\x00')
  mp4_test_be32(tail, 4, 0x76696465)
  mp4_test_box("hdlr", mp4_test_fullbox(0, 0, tail))
}

///|
fn mp4_test_stsd() -> Array[Byte] {
  let entry_tail = Array::make(78, b'\x00')
  entry_tail[6] = 0
  entry_tail[7] = 1
  entry_tail[24] = 0
  entry_tail[25] = 64
  entry_tail[26] = 0
  entry_tail[27] = 64
  let av1c = mp4_test_box("av1C", mp4_test_av1c())
  let entry = mp4_test_box("av01", mp4_test_concat([entry_tail, av1c]))
  let tail = Array::make(4, b'\x00')
  mp4_test_be32(tail, 0, 1)
  mp4_test_box("stsd", mp4_test_concat([mp4_test_fullbox(0, 0, tail), entry]))
}

///|
fn mp4_test_stts() -> Array[Byte] {
  let tail = Array::make(12, b'\x00')
  mp4_test_be32(tail, 0, 1)
  mp4_test_be32(tail, 4, 2)
  mp4_test_be32(tail, 8, 10)
  mp4_test_box("stts", mp4_test_fullbox(0, 0, tail))
}

///|
fn mp4_test_ctts(version? : Int = 0) -> Array[Byte] {
  let tail = Array::make(12, b'\x00')
  mp4_test_be32(tail, 0, 1)
  mp4_test_be32(tail, 4, 2)
  mp4_test_be32(tail, 8, if version == 1 { -3 } else { 3 })
  mp4_test_box("ctts", mp4_test_fullbox(version, 0, tail))
}

///|
fn mp4_test_stsc() -> Array[Byte] {
  let tail = Array::make(16, b'\x00')
  mp4_test_be32(tail, 0, 1)
  mp4_test_be32(tail, 4, 1)
  mp4_test_be32(tail, 8, 2)
  mp4_test_be32(tail, 12, 1)
  mp4_test_box("stsc", mp4_test_fullbox(0, 0, tail))
}

///|
fn mp4_test_stsz() -> Array[Byte] {
  let tail = Array::make(16, b'\x00')
  mp4_test_be32(tail, 0, 0)
  mp4_test_be32(tail, 4, 2)
  mp4_test_be32(tail, 8, 2)
  mp4_test_be32(tail, 12, 3)
  mp4_test_box("stsz", mp4_test_fullbox(0, 0, tail))
}

///|
fn mp4_test_stz2() -> Array[Byte] {
  let tail = Array::make(10, b'\x00')
  tail[3] = 8
  mp4_test_be32(tail, 4, 2)
  tail[8] = 2
  tail[9] = 3
  mp4_test_box("stz2", mp4_test_fullbox(0, 0, tail))
}

///|
fn mp4_test_chunk_offsets(value : Int) -> Array[Byte] {
  let tail = Array::make(8, b'\x00')
  mp4_test_be32(tail, 0, 1)
  mp4_test_be32(tail, 4, value)
  mp4_test_box("stco", mp4_test_fullbox(0, 0, tail))
}

///|
fn mp4_test_stss() -> Array[Byte] {
  let tail = Array::make(8, b'\x00')
  mp4_test_be32(tail, 0, 1)
  mp4_test_be32(tail, 4, 1)
  mp4_test_box("stss", mp4_test_fullbox(0, 0, tail))
}

///|
fn mp4_test_edts(media_time? : Int = 0) -> Array[Byte] {
  let tail = Array::make(16, b'\x00')
  mp4_test_be32(tail, 0, 1)
  mp4_test_be32(tail, 4, 1000)
  mp4_test_be32(tail, 8, media_time)
  mp4_test_be32(tail, 12, 1 << 16)
  mp4_test_box("edts", mp4_test_box("elst", mp4_test_fullbox(0, 0, tail)))
}

///|
fn mp4_test_regular(
  offset : Int,
  stz2? : Bool = false,
  ctts_version? : Int = 0,
  edit_media_time? : Int = 0,
  reference_version? : Int? = None,
) -> Array[Byte] {
  let stbl = mp4_test_box(
    "stbl",
    mp4_test_concat([
      mp4_test_stsd(),
      mp4_test_stts(),
      mp4_test_ctts(version=ctts_version),
      mp4_test_stsc(),
      if stz2 {
        mp4_test_stz2()
      } else {
        mp4_test_stsz()
      },
      mp4_test_chunk_offsets(offset),
      mp4_test_stss(),
    ]),
  )
  let dinf = match reference_version {
    None => []
    Some(version) =>
      mp4_test_box(
        "dinf",
        mp4_test_box(
          "dref",
          mp4_test_concat([
            mp4_test_fullbox(0, 0, [0, 0, 0, 1]),
            mp4_test_box("url ", mp4_test_fullbox(version, 1, [])),
          ]),
        ),
      )
  }
  let minf = mp4_test_box("minf", mp4_test_concat([dinf, stbl]))
  let mdia = mp4_test_box(
    "mdia",
    mp4_test_concat([mp4_test_mdhd(), mp4_test_hdlr_video(), minf]),
  )
  let trak = mp4_test_box(
    "trak",
    mp4_test_concat([
      mp4_test_tkhd(1),
      mp4_test_edts(media_time=edit_media_time),
      mdia,
    ]),
  )
  mp4_test_box("moov", mp4_test_concat([mp4_test_mvhd(), trak]))
}

///|
fn mp4_test_regular_file(
  stz2? : Bool = false,
  ctts_version? : Int = 0,
  edit_media_time? : Int = 0,
  reference_version? : Int? = None,
) -> Array[Byte] {
  let samples : Array[Byte] = [0x11, 0x22, 0x33, 0x44, 0x55]
  let zero = mp4_test_regular(
    0,
    stz2~,
    ctts_version~,
    edit_media_time~,
    reference_version~,
  )
  let offset = zero.length() + 8
  let moov = mp4_test_regular(
    offset,
    stz2~,
    ctts_version~,
    edit_media_time~,
    reference_version~,
  )
  mp4_test_concat([moov, mp4_test_box("mdat", samples)])
}

///|
fn mp4_test_fragmented_moov() -> Array[Byte] {
  let stbl = mp4_test_box("stbl", mp4_test_stsd())
  let minf = mp4_test_box("minf", stbl)
  let mdia = mp4_test_box(
    "mdia",
    mp4_test_concat([mp4_test_mdhd(), mp4_test_hdlr_video(), minf]),
  )
  let trak = mp4_test_box("trak", mp4_test_concat([mp4_test_tkhd(1), mdia]))
  let trex_tail = Array::make(20, b'\x00')
  mp4_test_be32(trex_tail, 0, 1)
  mp4_test_be32(trex_tail, 4, 1)
  mp4_test_be32(trex_tail, 8, 10)
  mp4_test_be32(trex_tail, 12, 2)
  mp4_test_be32(trex_tail, 16, 0)
  let trex = mp4_test_box("trex", mp4_test_fullbox(0, 0, trex_tail))
  mp4_test_box(
    "moov",
    mp4_test_concat([mp4_test_mvhd(), trak, mp4_test_box("mvex", trex)]),
  )
}

///|
fn mp4_test_fragment_file(
  preceding_unselected? : Bool = false,
  duration_empty? : Bool = false,
  timestamp? : Int64 = 20L,
) -> Array[Byte] {
  let tfhd_flags = if duration_empty {
    0x010000
  } else if preceding_unselected {
    0
  } else {
    0x020000
  }
  let tfhd = mp4_test_box("tfhd", mp4_test_fullbox(0, tfhd_flags, [0, 0, 0, 1]))
  let time_bytes = Array::make(8, b'\x00')
  for i in 0..<8 {
    time_bytes[i] = ((timestamp >> (56 - 8 * i)) & 255L).to_int().to_byte()
  }
  let tfdt = mp4_test_box("tfdt", mp4_test_fullbox(1, 0, time_bytes))
  let trun_tail = Array::make(4 + 4 + 8, b'\x00')
  mp4_test_be32(trun_tail, 0, 2)
  // The data offset is relative to the moof because tfhd uses default-base-is-moof.
  mp4_test_be32(trun_tail, 4, 0)
  mp4_test_be32(trun_tail, 8, 0)
  mp4_test_be32(trun_tail, 12, 0x10000)
  let trun = mp4_test_box("trun", mp4_test_fullbox(0, 0x401, trun_tail))
  let traf = mp4_test_box("traf", mp4_test_concat([tfhd, tfdt, trun]))
  let trafs = if preceding_unselected {
    let other_tfhd = mp4_test_box("tfhd", mp4_test_fullbox(0, 0, [0, 0, 0, 2]))
    let other_trun = mp4_test_box("trun", mp4_test_fullbox(0, 0, [0, 0, 0, 0]))
    mp4_test_concat([
      mp4_test_box("traf", mp4_test_concat([other_tfhd, other_trun])),
      traf,
    ])
  } else {
    traf
  }
  let moof0 = mp4_test_box("moof", trafs)
  let trun_offset = moof0.length() - trun.length() + 16
  let data_offset = moof0.length() + 8
  mp4_test_be32(moof0, trun_offset, data_offset)
  mp4_test_concat([
    mp4_test_fragmented_moov(),
    moof0,
    mp4_test_box("mdat", [0x66, 0x77, 0x88, 0x99]),
  ])
}

///|
fn mp4_test_unrelated_moof() -> Array[Byte] {
  let tfhd = mp4_test_box("tfhd", mp4_test_fullbox(0, 0x020000, [0, 0, 0, 2]))
  let trun = mp4_test_box("trun", mp4_test_fullbox(0, 0, [0, 0, 0, 0]))
  mp4_test_box("moof", mp4_test_box("traf", mp4_test_concat([tfhd, trun])))
}

///|
test "MP4 ordinary tables preserve decode order, ctts, stss and ownership" {
  let input = mp4_test_regular_file()
  let track = match av1_demux_mp4(input) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  assert_eq(
    (track.format, track.track_id, track.width, track.height, track.timescale),
    (Mp4, 1L, 64, 64, 1000L),
  )
  assert_eq(track.movie_timescale, Some(1000L))
  assert_eq(track.edits.length(), 1)
  assert_eq(
    (
      track.edits[0].duration,
      track.edits[0].media_time,
      track.edits[0].media_rate,
    ),
    (1000L, 0L, 65536),
  )
  assert_eq(track.codec_initialization, [
    0x0A, 0x06, 0x18, 0x15, 0x7F, 0xFC, 0, 8,
  ])
  assert_eq(track.packets.length(), 2)
  assert_eq(track.packets[0].decode_timestamp, Some(0L))
  assert_eq(track.packets[0].presentation_timestamp, Some(3L))
  assert_eq(track.packets[1].decode_timestamp, Some(10L))
  assert_eq(track.packets[1].presentation_timestamp, Some(13L))
  assert_eq(track.packets[0].duration, Some(10L))
  assert_eq(track.packets[0].sync_sample, Some(true))
  assert_eq(track.packets[1].sync_sample, Some(false))
  input[input.length() - 5] = 0
  assert_eq(track.packets[0].data, [0x11, 0x22])
}

///|
test "MP4 self-contained data references require version zero" {
  assert_eq(
    av1_demux_mp4(mp4_test_regular_file(reference_version=Some(0))).unwrap().packets.length(),
    2,
  )
  assert_eq(
    demux_test_error(
      av1_demux_mp4(mp4_test_regular_file(reference_version=Some(1))),
    ),
    Unsupported,
  )
}

///|
test "MP4 fragments use tfdt, trun data offset and trex defaults" {
  let track = av1_demux_mp4(mp4_test_fragment_file()).unwrap()
  assert_eq(track.packets.length(), 2)
  assert_eq(track.packets[0].decode_timestamp, Some(20L))
  assert_eq(track.packets[1].decode_timestamp, Some(30L))
  assert_eq(track.packets[0].presentation_timestamp, Some(20L))
  assert_eq(track.packets[0].duration, Some(10L))
  assert_eq(track.packets[0].sync_sample, Some(true))
  assert_eq(track.packets[1].sync_sample, Some(false))
}

///|
test "MP4 integer readers preserve unsigned low words and reject huge counts" {
  let bytes : Array[Byte] = [0, 0, 0, 1, 0x80, 0, 0, 0x20]
  assert_eq(mp4_u64(bytes, 0, 8), 6442450976L)
  assert_eq(mp4_i64([255, 255, 255, 255, 255, 255, 255, 255], 0, 8), -1L)
  assert_eq(
    mp4_i64([128, 0, 0, 0, 0, 0, 0, 0], 0, 8),
    -9223372036854775807L - 1L,
  )
  assert_eq(mp4_u32_wide(bytes, 4, 8), 2147483680L)
  let track = av1_demux_mp4(mp4_test_fragment_file(timestamp=6442450976L)).unwrap()
  assert_eq(track.packets[0].decode_timestamp, Some(6442450976L))
  assert_eq(track.packets[1].decode_timestamp, Some(6442450986L))
  let rejected = mp4_u32(bytes, 4, 8) catch {
    Mp4Error::Diagnostic(e) => {
      assert_eq(e.kind, LimitExceeded)
      -1
    }
  }
  assert_eq(rejected, -1)
}

///|
test "MP4 rejects duration-is-empty and unsafe implicit bases" {
  assert_eq(
    demux_test_error(av1_demux_mp4(mp4_test_fragment_file(duration_empty=true))),
    Unsupported,
  )
  assert_eq(
    demux_test_error(
      av1_demux_mp4(mp4_test_fragment_file(preceding_unselected=true)),
    ),
    Unsupported,
  )
}

///|
test "MP4 ordinary track ignores moofs belonging to another track" {
  let input = mp4_test_concat([
    mp4_test_regular_file(),
    mp4_test_unrelated_moof(),
  ])
  let track = av1_demux_mp4(input).unwrap()
  assert_eq(track.packets.length(), 2)
  assert_eq(track.packets[0].presentation_timestamp, Some(3L))
}

///|
test "MP4 stz2 sample sizes are expanded" {
  let track = av1_demux_mp4(mp4_test_regular_file(stz2=true)).unwrap()
  assert_eq(track.packets.length(), 2)
  assert_eq(track.packets[0].data, [0x11, 0x22])
  assert_eq(track.packets[1].data, [0x33, 0x44, 0x55])
}

///|
test "MP4 ctts version one accepts signed composition offsets" {
  let track = av1_demux_mp4(mp4_test_regular_file(ctts_version=1)).unwrap()
  assert_eq(track.packets[0].presentation_timestamp, Some(-3L))
  assert_eq(track.packets[1].presentation_timestamp, Some(7L))
}

///|
test "MP4 rejects truncation, sample ranges outside mdat and work limits" {
  let complete = mp4_test_regular_file()
  for cut in [0, 7, 40, complete.length() - 1] {
    let result = av1_demux_mp4(Array::makei(cut, i => complete[i]))
    match result {
      Err(_) => ()
      Ok(_) => fail("truncated MP4 unexpectedly accepted")
    }
  }
  let limited = av1_demux_mp4(complete, limits={
    ..DecodeLimits::default(),
    max_frames: 1,
  })
  assert_eq(demux_test_error(limited), LimitExceeded)
  let outside = complete.copy()
  // stco's one offset is the first occurrence of the ASCII stco tag.
  let mut at = 0
  while at + 4 <= outside.length() {
    if outside[at] == b's' &&
      outside[at + 1] == b't' &&
      outside[at + 2] == b'c' &&
      outside[at + 3] == b'o' {
      break
    }
    at += 1
  }
  mp4_test_be32(outside, at + 12, outside.length() + 100)
  assert_eq(demux_test_error(av1_demux_mp4(outside)), InvalidData)
}

///|
test "MP4 rejects invalid edit media time, FullBox version and sequence dimensions" {
  let complete = mp4_test_regular_file()
  assert_eq(
    demux_test_error(av1_demux_mp4(mp4_test_regular_file(edit_media_time=-2))),
    InvalidData,
  )

  let bad_stsd = complete.copy()
  let mut stsd = 0
  while stsd + 4 <= bad_stsd.length() {
    if bad_stsd[stsd] == b's' &&
      bad_stsd[stsd + 1] == b't' &&
      bad_stsd[stsd + 2] == b's' &&
      bad_stsd[stsd + 3] == b'd' {
      break
    }
    stsd += 1
  }
  bad_stsd[stsd + 4] = 1
  assert_eq(demux_test_error(av1_demux_mp4(bad_stsd)), Unsupported)

  let bad_dimensions = complete.copy()
  let mut av01 = 0
  while av01 + 4 <= bad_dimensions.length() {
    if bad_dimensions[av01] == b'a' &&
      bad_dimensions[av01 + 1] == b'v' &&
      bad_dimensions[av01 + 2] == b'0' &&
      bad_dimensions[av01 + 3] == b'1' {
      break
    }
    av01 += 1
  }
  bad_dimensions[av01 + 28] = 0
  bad_dimensions[av01 + 29] = 65
  assert_eq(demux_test_error(av1_demux_mp4(bad_dimensions)), InvalidData)
}
