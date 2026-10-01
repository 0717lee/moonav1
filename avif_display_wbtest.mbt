///|
fn display_metadata(transforms : Array[AvifDisplayTransform]) -> AvifMetadata {
  {
    primary_item_id: Some(1),
    track_id: None,
    icc: None,
    exif: None,
    exif_tiff_offset: None,
    xmp: None,
    pixel_aspect_ratio: None,
    transforms: FixedArray::from_array(transforms),
  }
}

///|
test "display transforms move complete RGBA pixels and retain owned storage" {
  let input : Image = {
    width: 3,
    height: 2,
    data: FixedArray::makei(24, i => (i / 4 * 4 + i % 4).to_byte()),
  }
  // Input IDs: [0,1,2;3,4,5]. Expected permutations are written explicitly.
  for
    entry in [
      ([], [0, 1, 2, 3, 4, 5]),
      ([Rotate(1)], [2, 5, 1, 4, 0, 3]),
      ([Mirror(0)], [3, 4, 5, 0, 1, 2]),
      ([Mirror(1)], [2, 1, 0, 5, 4, 3]),
      ([Rotate(1), Mirror(1)], [5, 2, 4, 1, 3, 0]),
      ([Mirror(1), Rotate(1)], [0, 3, 1, 4, 2, 5]),
    ] {
    let (transforms, expected) = entry
    let output = display_metadata(transforms).apply_rgba8(input).unwrap()
    for i in 0..<6 {
      for c in 0..<4 {
        assert_eq(output.data[i * 4 + c], (expected[i] * 4 + c).to_byte())
      }
    }
    output.data[0] = b'\xFF'
    assert_eq(input.data[0], b'\x00')
  }
}

///|
test "clean aperture exact fractions reject resampling and invalid ranges" {
  let crop : AvifCleanAperture = {
    width_n: 4L,
    width_d: 2L,
    height_n: 1L,
    height_d: 1L,
    horizontal_n: -1L,
    horizontal_d: 2L,
    vertical_n: 1L,
    vertical_d: 2L,
  }
  // A half-pixel center offset gives an integer origin on odd geometry.
  assert_eq(avif_crop_rect(crop, 3, 2).unwrap(), (0, 1, 2, 1))
  for
    entry in [
      ({ ..crop, width_d: 0L, }, InvalidData),
      ({ ..crop, width_n: 3L, }, Unsupported),
      ({ ..crop, horizontal_n: 0L, }, Unsupported),
      ({ ..crop, horizontal_n: -3L, }, InvalidData),
      ({ ..crop, vertical_n: 4294967295L, }, InvalidData),
      ({ ..crop, height_n: 4294967296L, }, InvalidData),
    ] {
    let (bad, kind) = entry
    match avif_crop_rect(bad, 3, 2) {
      Err(error) => assert_eq(error.kind, kind)
      Ok(_) => fail("Invalid aperture was accepted")
    }
  }
  for transform in [Rotate(4), Mirror(2)] {
    assert_true(display_metadata([transform]).display_size(3, 2) is Err(_))
  }
  assert_true(display_metadata([]).display_size(0x7FFFFFFF, 2) is Err(_))
  let bad : Image16 = { width: 2, height: 2, data: FixedArray::make(15, 0), }
  assert_true(display_metadata([]).apply_rgba16(bad) is Err(_))
}
