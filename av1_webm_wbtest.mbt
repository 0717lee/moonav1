///|
/// Focused structural tests for the pure EBML/Block layer. Full WebM
/// integration fixtures are kept separate because CodecPrivate must contain
/// a real AV1 sequence header and temporal unit.
fn webm_test_track(lacing? : Bool = true) -> WebmTrack {
  {
    number: 1L,
    track_type: 1,
    codec_av1: true,
    codec_private: None,
    width: 16,
    height: 16,
    default_duration: Some(33333333L),
    codec_delay: None,
    flag_lacing: lacing,
    content_encoded: false,
    track_timestamp_scale_one: true,
  }
}

///|
fn webm_test_track_entry(payload : Array[Byte]) -> Array[Byte] {
  let out : Array[Byte] = [0xAE, (0x80 + payload.length()).to_byte()]
  for byte in payload {
    out.push(byte)
  }
  out
}

///|
test "WebM VINT preserves IDs and recognizes unknown sizes" {
  let id_bytes : Array[Byte] = [0xA3]
  let unknown_bytes : Array[Byte] = [0x1F, 0xFF, 0xFF, 0xFF]
  let zero_bytes : Array[Byte] = [0x00]
  let chapter_display_id : Array[Byte] = [0x80]
  let all_one_id_data : Array[Byte] = [0x7F, 0xFF]
  let finite_all_one : Array[Byte] = [0xFF]
  match webm_read_vint(id_bytes, 0, 1, id=true) {
    Ok(value) =>
      assert_eq((value.value, value.width, value.unknown), (0xA3L, 1, false))
    Err(_) => fail("SimpleBlock ID was not parsed")
  }
  match webm_read_vint(unknown_bytes, 0, 4, size_mode=true) {
    Ok(value) =>
      assert_eq((value.value, value.width, value.unknown), (0L, 4, true))
    Err(_) => fail("Unknown-size VINT was not parsed")
  }
  match webm_read_vint(finite_all_one, 0, 1) {
    Ok(value) =>
      assert_eq((value.value, value.width, value.unknown), (127L, 1, false))
    Err(_) => fail("Finite all-one VINT was rejected")
  }
  let lace_value = webm_read_vint(finite_all_one, 0, 1).unwrap().value
  assert_eq(webm_i64_add(1L, lace_value - 63L, 0).unwrap(), 65L)
  match webm_read_vint(finite_all_one, 0, 1, size_mode=true) {
    Ok(value) =>
      assert_eq((value.value, value.width, value.unknown), (0L, 1, true))
    Err(_) => fail("Unknown-size VINT was rejected")
  }
  match webm_read_vint(chapter_display_id, 0, 1, id=true) {
    Ok(value) =>
      assert_eq((value.value, value.width, value.unknown), (0x80L, 1, false))
    Err(_) => fail("RFC 9559 ChapterDisplay ID was rejected")
  }
  assert_eq(
    demux_test_error(webm_read_vint(all_one_id_data, 0, 2, id=true)),
    InvalidData,
  )
  assert_eq(
    demux_test_error(webm_read_vint(zero_bytes, 0, 1, id=true)),
    InvalidData,
  )
}

///|
test "WebM Xiph fixed and EBML lacing expose owned frame spans" {
  let tracks = [webm_test_track()]
  let xiph : Array[Byte] = [0x81, 0, 0, 0x82, 1, 2, 0xAA, 0xBB, 0xCC, 0xDD]
  let fixed : Array[Byte] = [0x81, 0, 0, 0x84, 1, 0xAA, 0xBB, 0xCC, 0xDD]
  let ebml : Array[Byte] = [0x81, 0, 0, 0x86, 1, 0x82, 0xAA, 0xBB, 0xCC, 0xDD]
  for bytes in [xiph, fixed, ebml] {
    let block = webm_block_track(bytes, 0, bytes.length(), tracks).unwrap()
    assert_eq(block.frames.length(), 2)
    assert_eq(
      (
        block.frames[0].end - block.frames[0].start,
        block.frames[1].end - block.frames[1].start,
      ),
      (2, 2),
    )
    assert_true(block.keyframe)
  }
}

///|
test "WebM EBML header declarations use RFC defaults and validate read version" {
  let defaults : Array[Byte] = [
    0x1A, 0x45, 0xDF, 0xA3, 0x87, 0x42, 0x82, 0x84, 119, 101, 98, 109,
  ]
  let header = webm_read_element(defaults, 0, defaults.length()).unwrap()
  assert_eq(webm_parse_ebml_header(defaults, header), Ok(()))
  let bad_version : Array[Byte] = [
    0x1A, 0x45, 0xDF, 0xA3, 0x8F, 0x42, 0x87, 0x81, 2, 0x42, 0x85, 0x81, 3, 0x42,
    0x82, 0x84, 119, 101, 98, 109,
  ]
  let bad_header = webm_read_element(bad_version, 0, bad_version.length()).unwrap()
  assert_eq(
    demux_test_error(webm_parse_ebml_header(bad_version, bad_header)),
    Unsupported,
  )
}

///|
test "WebM TrackEntry rejects duplicate singleton elements" {
  let duplicate_lacing : Array[Byte] = webm_test_track_entry([
    0xD7, 0x81, 1, 0x83, 0x81, 1, 0x86, 0x85, 86, 95, 65, 86, 49, 0x9C, 0x81, 0,
    0x9C, 0x81, 1,
  ])
  let duplicate_scale : Array[Byte] = webm_test_track_entry([
    0xD7, 0x81, 1, 0x83, 0x81, 1, 0x86, 0x85, 86, 95, 65, 86, 49, 0x23, 0x31, 0x4F,
    0x88, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0, 0x23, 0x31, 0x4F, 0x88, 0x3F, 0xF0, 0, 0,
    0, 0, 0, 0,
  ])
  let duplicate_video : Array[Byte] = webm_test_track_entry([
    0xD7, 0x81, 1, 0x83, 0x81, 1, 0x86, 0x85, 86, 95, 65, 86, 49, 0xE0, 0x80, 0xE0,
    0x80,
  ])
  let duplicate_encodings : Array[Byte] = webm_test_track_entry([
    0xD7, 0x81, 1, 0x83, 0x81, 1, 0x86, 0x85, 86, 95, 65, 86, 49, 0x6D, 0x80, 0x80,
    0x6D, 0x80, 0x80,
  ])
  for
    bytes in [
      duplicate_lacing, duplicate_scale, duplicate_video, duplicate_encodings,
    ] {
    let entry = webm_read_element(bytes, 0, bytes.length()).unwrap()
    assert_eq(demux_test_error(webm_parse_track(bytes, entry)), InvalidData)
  }
}

///|
test "WebM unknown Cluster boundary stops at known siblings after globals" {
  let info : Array[Byte] = [0x15, 0x49, 0xA9, 0x66, 0x80]
  assert_eq(webm_next_cluster(info, 0, info.length()).unwrap(), 0)
  let void_info : Array[Byte] = [0xEC, 0x80, 0x15, 0x49, 0xA9, 0x66, 0x80]
  assert_eq(webm_next_cluster(void_info, 0, void_info.length()).unwrap(), 2)
}

///|
test "WebM lacing preserves three unequal frame lengths" {
  let tracks = [webm_test_track()]
  let xiph : Array[Byte] = [
    0x81, 0, 0, 0x82, 2, 1, 2, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
  ]
  let ebml : Array[Byte] = [
    0x81, 0, 0, 0x86, 2, 0x81, 0xC0, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
  ]
  for bytes in [xiph, ebml] {
    let block = webm_block_track(bytes, 0, bytes.length(), tracks).unwrap()
    assert_eq(block.frames.length(), 3)
    assert_eq(
      [
        block.frames[0].end - block.frames[0].start,
        block.frames[1].end - block.frames[1].start,
        block.frames[2].end - block.frames[2].start,
      ],
      [1, 2, 3],
    )
  }
}

///|
test "WebM lace timing preserves BlockDuration remainder and unknown PTS" {
  let first = webm_laced_timing(Some(10L), Some(3L), 1L, 3, 0, 0).unwrap()
  let second = webm_laced_timing(Some(10L), Some(3L), 1L, 3, 1, 0).unwrap()
  let last = webm_laced_timing(Some(10L), Some(3L), 1L, 3, 2, 0).unwrap()
  assert_eq(first, (Some(3L), Some(0L)))
  assert_eq(second, (Some(3L), Some(3L)))
  assert_eq(last, (Some(4L), Some(6L)))
  assert_eq(
    webm_laced_timing(None, None, 1L, 3, 0, 0).unwrap(),
    (None, Some(0L)),
  )
  assert_eq(webm_laced_timing(None, None, 1L, 3, 1, 0).unwrap(), (None, None))
  assert_eq(
    demux_test_error(webm_laced_timing(Some(5L), Some(3L), 1L, 3, 2, 0)),
    InvalidData,
  )
}

///|
test "WebM lacing rejects disabled tracks and truncated frames" {
  let disabled : Array[Byte] = [0x81, 0, 0, 0x82, 1, 2, 0xAA, 0xBB, 0xCC, 0xDD]
  assert_eq(
    demux_test_error(
      webm_block_track(disabled, 0, disabled.length(), [
        webm_test_track(lacing=false),
      ]),
    ),
    InvalidData,
  )
  let truncated : Array[Byte] = [0x81, 0, 0, 0x82, 1, 3, 0xAA]
  assert_eq(
    demux_test_error(
      webm_block_track(truncated, 0, truncated.length(), [webm_test_track()]),
    ),
    TruncatedInput,
  )
}

///|
test "unknown Cluster boundary accepts exactly its element budget before a sibling" {
  let input = Array::make(WEBM_MAX_ELEMENTS * 2, b'\x80')
  let sibling = input.length()
  for byte in ([0x1F, 0x43, 0xB6, 0x75, 0x80] : Array[Byte]) {
    input.push(byte)
  }
  assert_eq(webm_next_cluster(input, 0, input.length()).unwrap(), sibling)
  let over = Array::make((WEBM_MAX_ELEMENTS + 1) * 2, b'\x80')
  assert_eq(
    demux_test_error(webm_next_cluster(over, 0, over.length())),
    LimitExceeded,
  )
}
