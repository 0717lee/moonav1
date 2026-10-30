///|
fn extension_find(data : Array[Byte], word : String) -> Int {
  let chars = word.to_array()
  for start in 0..<(data.length() - chars.length() + 1) {
    let mut same = true
    for i in 0..<chars.length() {
      if data[start + i].to_int() != chars[i].to_int() {
        same = false
        break
      }
    }
    if same {
      return start
    }
  }
  abort("Fixture marker missing")
}

///|
test "metadata owns input bytes and preserves opaque ICC Exif and XMP" {
  let input = extension_metadata_8_r0_m0()
  let metadata = @moonav1.avif_metadata(input).unwrap()
  let exif = metadata.exif.unwrap().copy()
  let xmp = metadata.xmp.unwrap().copy()
  for i in 0..<input.length() {
    input[i] = b'\x00'
  }
  assert_eq(metadata.exif.unwrap(), exif)
  assert_eq(metadata.xmp.unwrap(), xmp)
  assert_eq(metadata.exif_tiff_offset, Some(6))
  let fresh = @moonav1.avif_metadata(extension_metadata_8_r0_m0()).unwrap()
  metadata.xmp.unwrap()[0] = b'\x00'
  assert_true(fresh.xmp.unwrap()[0] != b'\x00')
}

///|
test "metadata reports malformed transforms encoded strings and essential properties" {
  for mode in 0..<5 {
    let input = extension_metadata_8_r0_m0()
    let expected = if mode == 0 {
      input[extension_find(input, "irot") + 4] = b'\x80'
      @moonav1.InvalidData
    } else if mode == 1 {
      let at = extension_find(input, "clap") + 8
      for i in 0..<4 {
        input[at + i] = b'\x00'
      }
      @moonav1.InvalidData
    } else if mode == 2 {
      let at = extension_find(input, "irot")
      for i in 0..<4 {
        input[at + i] = b'z'
      }
      @moonav1.Unsupported
    } else if mode == 3 {
      let at = extension_find(input, "application/rdf+xml") + 19
      input[at] = b'X'
      @moonav1.TruncatedInput
    } else {
      let at = extension_find(input, "Exif\u0000\u0000II") - 4
      for i in 0..<4 {
        input[at + i] = b'\xFF'
      }
      @moonav1.InvalidData
    }
    assert_eq(diagnostic_kind(@moonav1.avif_metadata(input)), expected)
  }
  let input = extension_metadata_8_r0_m0()
  ignore(input.pop())
  assert_eq(
    diagnostic_kind(@moonav1.avif_metadata(input)),
    @moonav1.TruncatedInput,
  )
  assert_eq(
    diagnostic_kind(
      @moonav1.avif_metadata(input, limits={
        ..@moonav1.DecodeLimits::default(),
        max_input_bytes: 1,
      }),
    ),
    @moonav1.LimitExceeded,
  )
}
