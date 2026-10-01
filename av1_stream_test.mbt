///|
fn stream_same_frame(
  a : @moonav1.Av1NativeFrame,
  b : @moonav1.Av1NativeFrame,
) -> Unit raise {
  assert_eq((a.width, a.height, a.bit_depth), (b.width, b.height, b.bit_depth))
  assert_eq(a.planes.length(), b.planes.length())
  for p in 0..<a.planes.length() {
    assert_eq(a.planes[p].data, b.planes[p].data)
  }
}

///|
test "AV1 byte stream is invariant under every small chunk boundary" {
  for input in [limits_raw(), limits_hidden()] {
    let expected = @moonav1.av1_video_decode_temporal_unit_native(
      @moonav1.av1_video_decoder(),
      input,
    ).unwrap()
    for size in [1, 2, 3, 7, 31, 4096] {
      let stream = @moonav1.Av1StreamDecoder::new().unwrap()
      let frames : Array[@moonav1.Av1NativeFrame] = []
      let mut start = 0
      while start < input.length() {
        let count = if input.length() - start < size {
          input.length() - start
        } else {
          size
        }
        let batch = stream
          .feed(Array::makei(count, i => input[start + i]))
          .unwrap()
        for frame in batch.frames {
          frames.push(frame)
        }
        start += count
      }
      let last = stream.finish().unwrap()
      assert_eq(last.status, @moonav1.Av1StreamStatus::Finished)
      for frame in last.frames {
        frames.push(frame)
      }
      assert_eq(frames.length(), expected.length())
      for i in 0..<frames.length() {
        stream_same_frame(frames[i], expected[i])
      }
      assert_eq(stream.pending_bytes(), 0)
      assert_true(stream.finish().unwrap().frames.is_empty())
    }
  }
}

///|
test "AV1 stream owns pending bytes and supports explicit TU boundaries" {
  let input = limits_raw()
  let expected = @moonav1.av1_decode_native(input).unwrap()
  let stream = @moonav1.Av1StreamDecoder::new().unwrap()
  assert_true(stream.feed(input).unwrap().frames.is_empty())
  for i in 0..<input.length() {
    input[i] = 0
  }
  let frame = stream.end_temporal_unit().unwrap().frames[0]
  stream_same_frame(frame, expected)
  let _ = stream.feed(limits_raw()).unwrap()
  stream_same_frame(stream.finish().unwrap().frames[0], expected)
  assert_eq(
    diagnostic_kind(stream.feed([])),
    @moonav1.DecodeErrorKind::InvalidState,
  )
  stream.reset()
  let _ = stream.feed(limits_raw()).unwrap()
  stream_same_frame(stream.finish().unwrap().frames[0], expected)
  stream_same_frame(frame, expected)
}

///|
test "AV1 stream distinguishes need more input truncation and sticky failure" {
  let stream = @moonav1.Av1StreamDecoder::new().unwrap()
  assert_eq(
    stream.feed([0x1A, 0x80]).unwrap().status,
    @moonav1.Av1StreamStatus::NeedMoreInput,
  )
  match stream.finish() {
    Err(error) => {
      assert_eq(error.kind, @moonav1.DecodeErrorKind::TruncatedInput)
      assert_eq(error.byte_offset, Some(2L))
    }
    Ok(_) => fail("Truncated OBU accepted at EOF")
  }
  assert_eq(
    diagnostic_kind(stream.feed(limits_raw())),
    @moonav1.DecodeErrorKind::TruncatedInput,
  )
  stream.reset()
  let raw = limits_raw()
  let bytes = raw.copy()
  bytes.push(0x12)
  bytes.push(0)
  assert_eq(stream.feed(bytes).unwrap().frames.length(), 1)
  match stream.feed([0x80]) {
    Err(error) =>
      assert_eq(error.byte_offset, Some((raw.length() + 2).to_int64()))
    Ok(_) => fail("Invalid header accepted")
  }
}

///|
test "AV1 stream limits declared payload and shared call reconstruction work" {
  let tiny = { ..@moonav1.DecodeLimits::default(), max_input_bytes: 4, }
  let stream = @moonav1.Av1StreamDecoder::new(limits=tiny).unwrap()
  assert_eq(
    diagnostic_kind(stream.feed([0x7A, 3])),
    @moonav1.DecodeErrorKind::LimitExceeded,
  )
  assert_true(stream.pending_bytes() <= 20)
  let limits = { ..@moonav1.DecodeLimits::default(), max_frames: 1, }
  let stream = @moonav1.Av1StreamDecoder::new(limits~).unwrap()
  let raw = limits_raw()
  let bytes = raw.copy()
  for _ in 0..<2 {
    for byte in raw {
      bytes.push(byte)
    }
  }
  assert_eq(
    diagnostic_kind(stream.feed(bytes)),
    @moonav1.DecodeErrorKind::LimitExceeded,
  )
}
