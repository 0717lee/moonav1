///|
test "RGBA16 caller buffer matches owned output including alpha" {
  let image = @moonav1.avif_decode_native(limits_grid()).unwrap()
  let expected = image.to_rgba16().unwrap()
  let stride = image.color.width * 4 + 9
  let output : FixedArray[UInt16] = FixedArray::make(
    5 + stride * image.color.height + 11,
    65535,
  )
  for _ in 0..<2 {
    image.to_rgba16_into(output, stride, offset=5).unwrap()
  }
  for y in 0..<image.color.height {
    for c in 0..<(image.color.width * 4) {
      assert_eq(
        output[5 + y * stride + c],
        expected.data[y * image.color.width * 4 + c],
      )
    }
    for c in (image.color.width * 4)..<stride {
      assert_eq(output[5 + y * stride + c], 65535)
    }
  }
  let raw = @moonav1.av1_decode_native(limits_raw()).unwrap()
  let contiguous : FixedArray[UInt16] = FixedArray::make(
    raw.width * raw.height * 4,
    0,
  )
  raw.to_rgba16_into(contiguous, raw.width * 4).unwrap()
  assert_eq(contiguous, raw.to_rgba16().unwrap().data)
  let bytes = FixedArray::make(expected.width * expected.height * 8, b'\x00')
  expected.copy_bytes_into(bytes, expected.width * 8, big_endian=true).unwrap()
  for i in 0..<expected.data.length() {
    assert_eq(
      bytes[2 * i].to_int() * 256 + bytes[2 * i + 1].to_int(),
      expected.data[i].to_int(),
    )
  }
}

///|
test "invalid output buffers reject before writes" {
  let frame = @moonav1.av1_decode_native(limits_raw()).unwrap()
  let bytes = FixedArray::make(frame.width * frame.height * 2, b'\x7E')
  assert_eq(
    diagnostic_kind(
      frame.copy_plane_into(
        0,
        bytes,
        frame.width * 2 - 1,
        @moonav1.PixelPacking::U16LE,
      ),
    ),
    @moonav1.DecodeErrorKind::InvalidBuffer,
  )
  assert_eq(
    diagnostic_kind(
      frame.copy_plane_into(0, bytes, frame.width, @moonav1.PixelPacking::U8),
    ),
    @moonav1.DecodeErrorKind::Unsupported,
  )
  for value in bytes {
    assert_eq(value, b'\x7E')
  }
  let output : FixedArray[UInt16] = FixedArray::make(
    frame.width * frame.height * 4,
    32767,
  )
  assert_eq(
    diagnostic_kind(frame.to_rgba16_into(output, frame.width * 4, offset=1)),
    @moonav1.DecodeErrorKind::InvalidBuffer,
  )
  assert_eq(
    diagnostic_kind(frame.to_rgba16_into(output, 0x7FFFFFFF)),
    @moonav1.DecodeErrorKind::InvalidBuffer,
  )
  frame.planes[0].data[0] = -1
  assert_eq(
    diagnostic_kind(frame.to_rgba16_into(output, frame.width * 4)),
    @moonav1.DecodeErrorKind::InvalidData,
  )
  for value in output {
    assert_eq(value, 32767)
  }
}
