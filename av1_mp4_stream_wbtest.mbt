///|
/// Incremental MP4 tests intentionally feed one byte at a time. They exercise
/// headers, metadata, mdat ranges, sample payload splits and ownership without
/// depending on a native muxer.
fn mp4_stream_test_collect(
  input : Array[Byte],
  expect_replay? : Bool = false,
) -> Array[Av1Packet] raise {
  let stream = Av1ContainerStream::new(format=Some(Mp4)).unwrap()
  let packets : Array[Av1Packet] = []
  for i in 0..<input.length() {
    let batch = stream.feed([input[i]]).unwrap()
    for packet in batch.packets {
      packets.push(packet)
    }
  }
  let first_finish = stream.finish().unwrap()
  if expect_replay {
    assert_eq(first_finish.status, ReplayRequired)
    stream.replay().unwrap()
    for i in 0..<input.length() {
      let batch = stream.feed([input[i]]).unwrap()
      for packet in batch.packets {
        packets.push(packet)
      }
    }
  } else {
    assert_eq(first_finish.status, Finished)
    for packet in first_finish.packets {
      packets.push(packet)
    }
  }
  if expect_replay {
    let final_batch = stream.finish().unwrap()
    assert_eq(final_batch.status, Finished)
    for packet in final_batch.packets {
      packets.push(packet)
    }
  }
  packets
}

///|
fn mp4_stream_test_tail_fragment() -> Array[Byte] {
  let input = mp4_test_fragment_file()
  let moov_size = (input[0].to_int() << 24) |
    (input[1].to_int() << 16) |
    (input[2].to_int() << 8) |
    input[3].to_int()
  let moov = Array::makei(moov_size, i => input[i])
  let media = Array::makei(input.length() - moov_size, i => input[moov_size + i])
  mp4_test_concat([media, moov])
}

///|
test "incremental MP4 emits faststart packets across every split" {
  let packets = mp4_stream_test_collect(mp4_test_regular_file())
  assert_eq(packets.length(), 2)
  assert_eq(packets[0].data, [0x11, 0x22])
  assert_eq(packets[1].data, [0x33, 0x44, 0x55])
  assert_eq(packets[0].decode_timestamp, Some(0L))
  assert_eq(packets[1].decode_timestamp, Some(10L))
}

///|
test "incremental fMP4 preserves fragment decode timeline" {
  let packets = mp4_stream_test_collect(mp4_test_fragment_file())
  assert_eq(packets.length(), 2)
  assert_eq(packets[0].decode_timestamp, Some(20L))
  assert_eq(packets[1].decode_timestamp, Some(30L))
  assert_eq(packets[0].data, [0x66, 0x77])
  assert_eq(packets[1].data, [0x88, 0x99])
}

///|
test "tail metadata requests replay without duplicate packets" {
  let packets = mp4_stream_test_collect(
    mp4_stream_test_tail_fragment(),
    expect_replay=true,
  )
  assert_eq(packets.length(), 2)
  assert_eq(packets[0].decode_timestamp, Some(20L))
  assert_eq(packets[1].decode_timestamp, Some(30L))
}

///|
test "tail replay waits for and validates trailing padding boxes" {
  let input = mp4_test_concat([
    mp4_stream_test_tail_fragment(),
    mp4_test_box("free", Array::make(128, b'\x00')),
  ])
  let packets = mp4_stream_test_collect(input, expect_replay=true)
  assert_eq(packets.length(), 2)
}

///|
test "size-zero tail moov is parsed at EOF and replayed" {
  let original = mp4_test_fragment_file()
  let moov_size = (original[0].to_int() << 24) |
    (original[1].to_int() << 16) |
    (original[2].to_int() << 8) |
    original[3].to_int()
  let input = mp4_stream_test_tail_fragment()
  let moov_start = input.length() - moov_size
  for i in 0..<4 {
    input[moov_start + i] = 0
  }
  let packets = mp4_stream_test_collect(input, expect_replay=true)
  assert_eq(packets.length(), 2)
  assert_eq(packets[0].data, [0x66, 0x77])
  assert_eq(packets[1].data, [0x88, 0x99])
}

///|
test "stream accepts a legal wide unsigned mdat size header" {
  let stream = Av1ContainerStream::new(format=Some(Mp4)).unwrap()
  let batch = stream.feed([0x80, 0, 0, 0, b'm', b'd', b'a', b't']).unwrap()
  assert_eq(batch.status, NeedMoreInput)
  match stream.finish() {
    Ok(_) => fail("wide mdat unexpectedly completed")
    Err(error) => assert_eq(error.kind, TruncatedInput)
  }
}

///|
test "complete EOF classifies a sample outside every mdat as invalid data" {
  let input = mp4_test_regular_file().copy()
  let mut stco = 0
  while stco + 4 <= input.length() {
    if input[stco] == b's' &&
      input[stco + 1] == b't' &&
      input[stco + 2] == b'c' &&
      input[stco + 3] == b'o' {
      break
    }
    stco += 1
  }
  mp4_test_be32(input, stco + 12, input.length() + 100)
  let stream = Av1ContainerStream::new(format=Some(Mp4)).unwrap()
  let _ = stream.feed(input).unwrap()
  match stream.finish() {
    Ok(_) => fail("out-of-range sample unexpectedly completed")
    Err(error) => assert_eq(error.kind, InvalidData)
  }
}

///|
test "zero-sized table samples are invalid data" {
  let input = mp4_test_regular_file().copy()
  let mut stsz = 0
  while stsz + 4 <= input.length() {
    if input[stsz] == b's' &&
      input[stsz + 1] == b't' &&
      input[stsz + 2] == b's' &&
      input[stsz + 3] == b'z' {
      break
    }
    stsz += 1
  }
  mp4_test_be32(input, stsz + 20, 0)
  let stream = Av1ContainerStream::new(format=Some(Mp4)).unwrap()
  match stream.feed(input) {
    Ok(_) => fail("zero-sized sample unexpectedly accepted")
    Err(error) => assert_eq(error.kind, InvalidData)
  }
}

///|
test "descriptor count uses max_frames independently of pending bytes" {
  let stream = Av1ContainerStream::new(format=Some(Mp4), limits={
    ..DecodeLimits::default(),
    max_frames: 1,
  }).unwrap()
  match stream.feed(mp4_test_regular_file()) {
    Ok(_) => fail("sample descriptor limit unexpectedly accepted")
    Err(error) => assert_eq(error.kind, LimitExceeded)
  }
}

///|
test "fragment packet size is capped independently of descriptor retention" {
  let input = mp4_test_fragment_file().copy()
  let mut trex = 0
  while trex + 4 <= input.length() {
    if input[trex] == b't' &&
      input[trex + 1] == b'r' &&
      input[trex + 2] == b'e' &&
      input[trex + 3] == b'x' {
      break
    }
    trex += 1
  }
  // trex's default sample size is 20 bytes after the type tag.
  mp4_test_be32(input, trex + 20, 100000)
  let moov_size = (input[0].to_int() << 24) |
    (input[1].to_int() << 16) |
    (input[2].to_int() << 8) |
    input[3].to_int()
  let stream = Av1ContainerStream::new(format=Some(Mp4), limits={
    ..DecodeLimits::default(),
    max_input_bytes: moov_size + 64,
  }).unwrap()
  match stream.feed(input) {
    Ok(_) => fail("oversized fragment packet unexpectedly accepted")
    Err(error) => assert_eq(error.kind, LimitExceeded)
  }
}
