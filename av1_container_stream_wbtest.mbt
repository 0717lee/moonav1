///|
fn stream_test_feed_ivf(
  data : Array[Byte],
  width : Int,
  cap : Int,
) -> (Array[Av1Packet], Int) raise {
  let stream = Av1ContainerStream::new(limits={
    ..DecodeLimits::default(),
    max_input_bytes: cap,
    max_frames: 1000,
  }).unwrap()
  let packets : Array[Av1Packet] = []
  let mut early_packet = false
  let mut at = 0
  while at < data.length() {
    let n = if data.length() - at < width { data.length() - at } else { width }
    let chunk = Array::makei(n, i => data[at + i])
    let batch = stream.feed(chunk).unwrap()
    for packet in batch.packets {
      packets.push(packet)
    }
    for i in 0..<chunk.length() {
      chunk[i] = 255
    }
    at += n
    if at < data.length() && !batch.packets.is_empty() {
      assert_eq(batch.status, Ready)
      early_packet = true
    }
    assert_true(stream.pending_bytes() <= cap)
  }
  let last = stream.finish().unwrap()
  for packet in last.packets {
    packets.push(packet)
  }
  assert_eq(last.status, Finished)
  assert_eq(stream.finish().unwrap().packets.length(), 0)
  assert_eq(stream.bytes_received(), data.length().to_int64())
  assert_true(
    early_packet,
    msg="Incremental demux waited for the complete input",
  )
  (packets, stream.peak_pending_bytes())
}

///|
test "incremental IVF releases payloads and preserves timing at arbitrary splits" {
  let records = Array::makei(300, i => {
    (i.to_int64() - 7L, [i.to_byte(), 0x55, 0xAA])
  })
  let input = demux_test_ivf(records)
  let expected = av1_demux_ivf(input, limits={
    ..DecodeLimits::default(),
    max_frames: 1000,
  }).unwrap()
  for split in [1, 2, 7, 13, 31, 64] {
    let (packets, peak) = stream_test_feed_ivf(input, split, 64)
    assert_eq(packets.length(), 300)
    assert_true(peak <= 64)
    for i in 0..<packets.length() {
      assert_eq(packets[i].data, expected.packets[i].data)
      assert_eq(
        packets[i].presentation_timestamp,
        expected.packets[i].presentation_timestamp,
      )
      assert_eq(packets[i].decode_timestamp, None)
      assert_eq(packets[i].duration, None)
      assert_eq(packets[i].sync_sample, None)
    }
  }
}

///|
test "incremental IVF every truncation remains distinct from a valid empty feed" {
  let input = demux_test_ivf([(0L, [1, 2, 3]), (1L, [4, 5])])
  for cut in 0..<input.length() {
    let stream = Av1ContainerStream::new().unwrap()
    assert_eq(stream.feed([]).unwrap().status, NeedMoreInput)
    ignore(stream.feed(Array::makei(cut, i => input[i])).unwrap())
    let first = match stream.finish() {
      Err(error) => error
      Ok(_) => fail("A truncated IVF stream unexpectedly finished")
    }
    assert_eq(first.kind, TruncatedInput)
    match stream.feed([0]) {
      Err(error) => assert_eq(error, first)
      Ok(_) => fail("Container error was not sticky")
    }
    stream.reset()
    assert_eq(stream.bytes_received(), 0L)
    assert_eq(stream.packet_count(), 0)
    assert_eq(stream.peak_pending_bytes(), 0)
    assert_eq(stream.feed(input).unwrap().packets.length(), 2)
    assert_eq(stream.finish().unwrap().status, Finished)
  }
}

///|
test "incremental container limits metadata ownership terminal state and replay" {
  let input = demux_test_ivf([(1L, [1, 2, 3])])
  let stream = Av1ContainerStream::new().unwrap()
  let batch = stream.feed(input).unwrap()
  assert_eq(batch.status, Ready)
  assert_eq(batch.packets[0].data, [1, 2, 3])
  assert_eq(stream.track_info().unwrap().timescale, 30000L)
  let info = stream.track_info().unwrap()
  info.codec_initialization.push(99)
  info.edits.push({ duration: 1L, media_time: 0L, media_rate: 65536, })
  assert_true(stream.track_info().unwrap().codec_initialization.is_empty())
  assert_true(stream.track_info().unwrap().edits.is_empty())
  assert_eq(demux_test_error(stream.replay()), InvalidState)
  ignore(stream.finish().unwrap())
  assert_eq(demux_test_error(stream.feed([0])), InvalidState)
  assert_eq(stream.finish().unwrap().status, Finished)
  let small = Av1ContainerStream::new(limits={
    ..DecodeLimits::default(),
    max_input_bytes: 32,
  }).unwrap()
  assert_eq(demux_test_error(small.feed(input)), LimitExceeded)
  small.reset()
  ignore(small.feed(Array::makei(32, i => input[i])).unwrap())
  let oversized = Array::make(12, b'\x00')
  demux_test_le(oversized, 0, 4, 21L)
  assert_eq(demux_test_error(small.feed(oversized)), LimitExceeded)
  let wrong_track = Av1ContainerStream::new(track_id=Some(1L)).unwrap()
  assert_eq(demux_test_error(wrong_track.feed(input)), InvalidData)
  assert_eq(
    demux_test_error(
      Av1ContainerStream::new(limits={
        ..DecodeLimits::default(),
        max_frames: 0,
      }),
    ),
    InvalidData,
  )
}

///|
test "incremental pixel decoder preserves payload failure and resets" {
  let invalid = demux_test_ivf([(0L, [0x0A])])
  let decoder = Av1ContainerStreamDecoder::new().unwrap()
  let error = match decoder.feed(invalid) {
    Err(value) => value
    Ok(_) => fail("Incomplete AV1 OBU was decoded")
  }
  assert_eq(error.kind, TruncatedInput)
  assert_eq(error.byte_offset, None)
  match decoder.finish() {
    Err(next) => assert_eq(next, error)
    Ok(_) => fail("Pixel failure was not sticky")
  }
  decoder.reset()
  let empty = decoder.feed(demux_test_ivf([])).unwrap()
  assert_true(empty.frames.is_empty())
  assert_eq(decoder.finish().unwrap().status, Finished)
}

///|
test "terminal feed misuse preserves pending MP4 replay" {
  let decoder = Av1ContainerStreamDecoder::new().unwrap()
  let input = mp4_stream_test_tail_fragment()
  assert_true(decoder.feed(input).unwrap().frames.is_empty())
  assert_eq(decoder.finish().unwrap().status, ReplayRequired)
  let peak = decoder.peak_pending_bytes()
  assert_eq(demux_test_error(decoder.feed([0])), InvalidState)
  decoder.replay().unwrap()
  assert_eq(decoder.peak_pending_bytes(), peak)
  assert_eq(decoder.feed([]).unwrap().status, NeedMoreInput)
}

///|
test "incremental IVF validates timebase overflow and exact packet bounds" {
  let bad_scale = demux_test_ivf([(0L, [1])])
  demux_test_le(bad_scale, 20, 4, 0L)
  assert_eq(
    demux_test_error(Av1ContainerStream::new().unwrap().feed(bad_scale)),
    InvalidData,
  )
  let overflow = demux_test_ivf([(9223372036854775807L, [1])])
  assert_eq(
    demux_test_error(Av1ContainerStream::new().unwrap().feed(overflow)),
    Unsupported,
  )
  let exact = Av1ContainerStream::new(limits={
    ..DecodeLimits::default(),
    max_frames: 2,
  }).unwrap()
  let two = demux_test_ivf([(0L, [1]), (1L, [2])])
  assert_eq(exact.feed(two).unwrap().packets.length(), 2)
  assert_eq(exact.finish().unwrap().status, Finished)
  let extra = two.copy()
  demux_test_le(extra, 24, 4, 1L)
  assert_eq(
    demux_test_error(Av1ContainerStream::new().unwrap().feed(extra)),
    InvalidData,
  )
}

///|
test "incremental pixels own their planes and share each feed work budget" {
  let raw = container_seek_key_sample()
  let source = container_seek_ivf([raw, raw], [0L, 1L])
  let expected = av1_decode_native(raw).unwrap()
  let limits = {
    ..DecodeLimits::default(),
    max_total_pixels: expected.width * expected.height,
  }
  let combined = Av1ContainerStreamDecoder::new(limits~).unwrap()
  assert_eq(demux_test_error(combined.feed(source)), LimitExceeded)
  let split = Av1ContainerStreamDecoder::new(limits~).unwrap()
  let first_end = 32 + 12 + raw.length()
  let prefix = Array::makei(first_end, i => source[i])
  let first = split.feed(prefix).unwrap().frames[0]
  for i in 0..<prefix.length() {
    prefix[i] = 0
  }
  first.frame.planes[0].data[0] = -1
  let second = split
    .feed(Array::makei(source.length() - first_end, i => source[first_end + i]))
    .unwrap().frames[0]
  assert_eq(second.packet_index, 1)
  for p in 0..<expected.planes.length() {
    assert_eq(second.frame.planes[p].data, expected.planes[p].data)
  }
  assert_eq(split.finish().unwrap().status, Finished)
}
