/// Shared helpers for generated reference suites. Kept in the black-box test
/// package so the moved files do not need to depend on root test files.

///|
fn native_test_bytes(rows : Array[String]) -> Array[Byte] {
  let result : Array[Byte] = []
  for row in rows {
    let chars = row.to_array()
    for i in 0..<(chars.length() / 2) {
      let hi = chars[i * 2].to_int()
      let lo = chars[i * 2 + 1].to_int()
      result.push(
        (((if hi >= 97 { hi - 87 } else { hi - 48 }) << 4) |
        (if lo >= 97 { lo - 87 } else { lo - 48 })).to_byte(),
      )
    }
  }
  result
}

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
fn native_test_expand(rows : Array[String]) -> Array[Int] {
  let bytes = native_test_bytes(rows)
  let result : Array[Int] = []
  let mut pos = 0
  while pos < bytes.length() {
    let control = bytes[pos].to_int()
    pos = pos + 1
    if control < 128 {
      for _ in 0..<(control + 1) {
        result.push(bytes[pos].to_int() | (bytes[pos + 1].to_int() << 8))
        pos = pos + 2
      }
    } else {
      let value = bytes[pos].to_int() | (bytes[pos + 1].to_int() << 8)
      pos = pos + 2
      for _ in 0..<(control - 125) {
        result.push(value)
      }
    }
  }
  result
}
