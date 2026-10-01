///|
fn animation_stream_same(
  actual : @moonav1.AvifNativeAnimationFrame,
  expected : @moonav1.AvifNativeAnimationFrame,
) -> Unit raise {
  assert_eq(
    (actual.index, actual.timestamp, actual.duration, actual.timescale),
    (expected.index, expected.timestamp, expected.duration, expected.timescale),
  )
  assert_eq(actual.image.premultiplied, expected.image.premultiplied)
  for p in 0..<expected.image.color.planes.length() {
    assert_eq(
      actual.image.color.planes[p].data,
      expected.image.color.planes[p].data,
    )
  }
  assert_eq(
    actual.image.alpha.unwrap().planes[0].data,
    expected.image.alpha.unwrap().planes[0].data,
  )
}

///|
test "lazy animation reports late entropy failure and recovers only after reset" {
  let bytes = limits_animation()
  let timing = @moonav1.avif_animation_descriptor(bytes).unwrap().frames[2]
  let mut at = timing.offset
  let end = at + timing.length
  while at < end {
    let header = bytes[at].to_int()
    at += 1
    if (header & 4) != 0 {
      at += 1
    }
    let mut size = 0
    let mut shift = 0
    while true {
      let value = bytes[at].to_int()
      at += 1
      size = size | ((value & 127) << shift)
      shift += 7
      if (value & 128) == 0 {
        break
      }
    }
    if ((header >> 3) & 15) == 6 {
      for i in at..<(at + size) {
        bytes[i] = b'\x00'
      }
    }
    at += size
  }
  // OBU envelopes and prior samples stay valid. The zeroed frame payload
  // cannot produce the required single shown picture.
  let decoder = @moonav1.AvifAnimationDecoder::new(bytes).unwrap()
  assert_eq(decoder.next_frame().unwrap().unwrap().index, 0)
  assert_eq(decoder.next_frame().unwrap().unwrap().index, 1)
  assert_true(decoder.next_frame() is Err(_))
  assert_eq(decoder.position(), 2)
  assert_true(decoder.seek_frame(0) is Err(_))
  decoder.reset()
  assert_eq(decoder.next_frame().unwrap().unwrap().index, 0)
}

///|
test "lazy animation preserves native pixels timing ownership and seek" {
  let data = limits_animation()
  let expected = @moonav1.avif_decode_animation_native(data).unwrap()
  let decoder = @moonav1.AvifAnimationDecoder::new(data).unwrap()
  for i in 0..<data.length() {
    data[i] = b'\x00'
  }
  assert_eq(decoder.frame_count(), 3)
  assert_eq(decoder.position(), 0)
  assert_true(decoder.is_keyframe(0).unwrap())
  assert_eq(decoder.nearest_keyframe(2).unwrap(), Some(0))
  let first = decoder.next_frame().unwrap().unwrap()
  animation_stream_same(first, expected.frames[0])
  first.image.color.planes[0].data[0] = -1
  first.image.alpha.unwrap().planes[0].data[0] = -1
  for i in 1..<3 {
    animation_stream_same(
      decoder.next_frame().unwrap().unwrap(),
      expected.frames[i],
    )
    assert_eq(
      decoder.frame_timing(i).unwrap().timestamp,
      expected.frames[i].timestamp,
    )
  }
  assert_true(decoder.next_frame().unwrap() is None)
  assert_true(decoder.next_frame().unwrap() is None)
  for index in [2, 0, 1, 2] {
    animation_stream_same(
      decoder.seek_frame(index).unwrap(),
      expected.frames[index],
    )
    assert_eq(decoder.position(), index + 1)
  }
  assert_eq(diagnostic_kind(decoder.seek_frame(3)), @moonav1.InvalidData)
  assert_eq(decoder.position(), 3)
  decoder.reset()
  animation_stream_same(
    decoder.next_frame().unwrap().unwrap(),
    expected.frames[0],
  )
  let metadata = decoder.metadata()
  assert_eq(metadata.primary_item_id, None)
  assert_true(metadata.track_id is Some(_))
}

///|
test "lazy animation budgets apply to one next operation and complete seek replay" {
  let limits : @moonav1.DecodeLimits = {
    max_input_bytes: 100000,
    max_frame_pixels: 256,
    max_total_pixels: 512,
    max_frames: 2,
  }
  // Eager decoding charges all six coded pictures; lazy next retains only
  // decoder references and charges the current color/alpha pair.
  assert_true(limits.avif_decode_animation_native(limits_animation()) is None)
  let decoder = @moonav1.AvifAnimationDecoder::new(limits_animation(), limits~).unwrap()
  for _ in 0..<3 {
    assert_true(decoder.next_frame().unwrap() is Some(_))
  }
  assert_eq(diagnostic_kind(decoder.seek_frame(2)), @moonav1.LimitExceeded)
  assert_eq(diagnostic_kind(decoder.next_frame()), @moonav1.LimitExceeded)
  decoder.reset()
  assert_eq(decoder.next_frame().unwrap().unwrap().index, 0)
  let small = @moonav1.AvifAnimationDecoder::new(limits_animation(), limits={
    ..limits,
    max_frames: 1,
  }).unwrap()
  assert_eq(diagnostic_kind(small.next_frame()), @moonav1.LimitExceeded)
}
