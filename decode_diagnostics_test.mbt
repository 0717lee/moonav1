///|
fn[T] diagnostic_kind(
  result : Result[T, @moonav1.DecodeError],
) -> @moonav1.DecodeErrorKind raise {
  match result {
    Err(error) => error.kind
    Ok(_) => fail("Expected a structured decode failure")
  }
}

///|
test "checked AV1 separates no presentation missing reference and explicit unsupported OBU" {
  let source = limits_hidden()
  // Saved non-reduced sequence header: TD plus a nine-byte sequence payload.
  assert_eq(source[2], b'\x0A')
  assert_eq(source[3], b'\x09')
  let sequence = Array::makei(13, i => source[i])
  assert_true(
    @moonav1.av1_video_decode_temporal_unit_native_result(
      @moonav1.av1_video_decoder(),
      sequence,
    )
    .unwrap()
    .is_empty(),
  )
  assert_eq(
    diagnostic_kind(@moonav1.av1_decode_native_result(sequence)),
    @moonav1.NoPresentation,
  )
  let existing = sequence.copy()
  for byte in [b'\x1A', b'\x01', b'\xF0'] {
    existing.push(byte)
  }
  assert_eq(
    diagnostic_kind(@moonav1.av1_decode_native_result(existing)),
    @moonav1.MissingReference,
  )
  let tile_list = sequence.copy()
  tile_list.push(b'\x42')
  tile_list.push(b'\x00')
  assert_eq(
    diagnostic_kind(@moonav1.av1_decode_native_result(tile_list)),
    @moonav1.Unsupported,
  )
}

///|
test "checked AVIF preserves alpha grid pixels and distinguishes broken box envelopes" {
  let input = limits_grid()
  let expected = @moonav1.avif_decode_native(input).unwrap()
  let actual = @moonav1.avif_decode_native_result(input).unwrap()
  stream_same_frame(actual.color, expected.color)
  stream_same_frame(actual.alpha.unwrap(), expected.alpha.unwrap())
  assert_eq(
    @moonav1.avif_decode_rgba16_result(input).unwrap().data,
    expected.to_rgba16().unwrap().data,
  )
  assert_eq(
    @moonav1.avif_decode_rgba_result(input).unwrap().data,
    @moonav1.avif_decode_rgba(input).unwrap().data,
  )
  assert_eq(
    diagnostic_kind(
      @moonav1.avif_container_parse_result([0, 0, 0, 7, 102, 114, 101, 101]),
    ),
    @moonav1.InvalidData,
  )
  assert_eq(
    diagnostic_kind(
      @moonav1.avif_container_parse_result([0, 0, 0, 16, 102, 114, 101, 101]),
    ),
    @moonav1.TruncatedInput,
  )
}

///|
test "checked AV1 errors distinguish framing state and policy" {
  assert_eq(
    diagnostic_kind(@moonav1.av1_decode_native_result([])),
    @moonav1.DecodeErrorKind::TruncatedInput,
  )
  assert_eq(
    diagnostic_kind(@moonav1.av1_decode_native_result([0x80])),
    @moonav1.DecodeErrorKind::InvalidData,
  )
  assert_eq(
    diagnostic_kind(@moonav1.av1_decode_native_result([0x32, 1, 0])),
    @moonav1.DecodeErrorKind::MissingSequence,
  )
  match @moonav1.av1_decode_native_result([0x12]) {
    Err(error) => {
      assert_eq(error.kind, @moonav1.DecodeErrorKind::TruncatedInput)
      assert_eq(error.byte_offset, Some(1L))
      assert_eq(error.context, "obu")
    }
    Ok(_) => fail("Truncated length accepted")
  }
  let limits = { ..@moonav1.DecodeLimits::default(), max_frame_pixels: 63, }
  assert_eq(
    diagnostic_kind(@moonav1.av1_decode_native_result(limits_raw(), limits~)),
    @moonav1.DecodeErrorKind::LimitExceeded,
  )
  let invalid = { ..limits, max_frames: 0, }
  assert_eq(
    diagnostic_kind(
      @moonav1.av1_decode_native_result(limits_raw(), limits=invalid),
    ),
    @moonav1.DecodeErrorKind::InvalidData,
  )
}

///|
test "checked native API retains all samples and legacy unary functions" {
  let bytes = limits_raw()
  let checked = @moonav1.av1_decode_native_result(bytes).unwrap()
  let legacy = @moonav1.av1_decode_native(bytes).unwrap()
  assert_eq(checked.bit_depth, legacy.bit_depth)
  for p in 0..<checked.planes.length() {
    assert_eq(checked.planes[p].data, legacy.planes[p].data)
  }
  let rgba = @moonav1.av1_decode_rgba16_result(bytes).unwrap()
  assert_eq(rgba.data, legacy.to_rgba16().unwrap().data)
  let callback : (Array[Byte]) -> @moonav1.Av1NativeFrame? = @moonav1.av1_decode_native
  assert_true(callback([]) is None)
}
