///|
fn resample_test_metadata(
  transforms : Array[AvifDisplayTransform],
) -> AvifMetadata {
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
fn resample_test_rgba2x2() -> Image {
  {
    width: 2,
    height: 2,
    data: FixedArray::from_array([
      b'\xFF', b'\x00', b'\x00', b'\xFF', b'\x00', b'\xFF', b'\x00', b'\xFF', b'\x00',
      b'\x00', b'\xFF', b'\xFF', b'\xFF', b'\xFF', b'\xFF', b'\xFF',
    ]),
  }
}

///|
test "resample fractional crop uses pixel centers and owns output" {
  let crop : AvifCleanAperture = {
    width_n: 3L,
    width_d: 2L,
    height_n: 3L,
    height_d: 2L,
    horizontal_n: 1L,
    horizontal_d: 4L,
    vertical_n: 1L,
    vertical_d: 4L,
  }
  let source = resample_test_rgba2x2()
  let output = resample_test_metadata([Crop(crop)])
    .resample_rgba8(source, 1, 1)
    .unwrap()
  // Crop's first center is (0.5, 0.5); the one output center maps to
  // (0.75, 0.75) in the source.  Bilinear RGB is encoded-domain math.
  assert_eq(output.data[0], b'\x9F')
  assert_eq(output.data[1], b'\xBF')
  assert_eq(output.data[2], b'\xBF')
  assert_eq(output.data[3], b'\xFF')
  output.data[0] = b'\x00'
  assert_eq(source.data[0], b'\xFF')
}

///|
test "resample composes operation order and preserves exact integer cases" {
  let source : Image = {
    width: 3,
    height: 2,
    data: FixedArray::makei(24, i => (i / 4 * 10 + i % 4).to_byte()),
  }
  let exact = resample_test_metadata([Rotate(1)])
    .resample_rgba8(source, 2, 3)
    .unwrap()
  let old = resample_test_metadata([Rotate(1)]).apply_rgba8(source).unwrap()
  assert_eq(exact.data, old.data)
  let crop : AvifCleanAperture = {
    width_n: 2L,
    width_d: 1L,
    height_n: 1L,
    height_d: 1L,
    horizontal_n: 0L,
    horizontal_d: 2L,
    vertical_n: 0L,
    vertical_d: 1L,
  }
  let crop_then_rotate = resample_test_metadata([Crop(crop), Rotate(1)])
    .resample_rgba8(source, 2, 2)
    .unwrap()
  let rotate_then_crop = resample_test_metadata([Rotate(1), Crop(crop)])
    .resample_rgba8(source, 2, 2)
    .unwrap()
  assert_true(crop_then_rotate.data[0] != rotate_then_crop.data[0])
}

///|
test "resample bilinear keeps transparent color out of alpha fringe" {
  let source : Image = {
    width: 2,
    height: 1,
    data: FixedArray::from_array([
      b'\xFF', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\xFF', b'\xFF',
    ]),
  }
  let output = resample_test_metadata([]).resample_rgba8(source, 3, 1).unwrap()
  assert_eq(output.data[4], b'\x00')
  assert_eq(output.data[5], b'\x00')
  assert_eq(output.data[6], b'\xFF')
  assert_eq(output.data[7], b'\x80')
  let source16 : Image16 = {
    width: 2,
    height: 1,
    data: FixedArray::from_array([65535, 0, 0, 0, 0, 0, 65535, 65535]),
  }
  let output16 = resample_test_metadata([])
    .resample_rgba16(source16, 3, 1)
    .unwrap()
  assert_eq(output16.data[4], 0)
  assert_eq(output16.data[5], 0)
  assert_eq(output16.data[6], 65535)
  assert_eq(output16.data[7], 32768)
}

///|
test "resample rejects malformed buffers rational geometry and pixel limits" {
  let source = resample_test_rgba2x2()
  let bad_denominator : AvifCleanAperture = {
    width_n: 1L,
    width_d: 0L,
    height_n: 1L,
    height_d: 1L,
    horizontal_n: 0L,
    horizontal_d: 1L,
    vertical_n: 0L,
    vertical_d: 1L,
  }
  match
    resample_test_metadata([Crop(bad_denominator)]).resample_rgba8(source, 1, 1) {
    Err(error) => assert_eq(error.kind, InvalidData)
    Ok(_) => fail("Invalid denominator was accepted")
  }
  let outside : AvifCleanAperture = {
    ..bad_denominator,
    width_n: 3L,
    width_d: 1L,
    height_d: 1L,
    horizontal_d: 1L,
  }
  match resample_test_metadata([Crop(outside)]).resample_rgba8(source, 1, 1) {
    Err(error) => assert_eq(error.kind, InvalidData)
    Ok(_) => fail("Out-of-bounds crop was accepted")
  }
  let bad_offset : AvifCleanAperture = {
    ..outside,
    width_n: 1L,
    height_n: 1L,
    horizontal_n: 2147483648L,
  }
  match
    resample_test_metadata([Crop(bad_offset)]).resample_rgba8(source, 1, 1) {
    Err(error) => assert_eq(error.kind, InvalidData)
    Ok(_) => fail("Offset outside int32 was accepted")
  }
  let malformed : Image = {
    width: 2,
    height: 2,
    data: FixedArray::make(3, b'\x00'),
  }
  match resample_test_metadata([]).resample_rgba8(malformed, 1, 1) {
    Err(error) => assert_eq(error.kind, InvalidBuffer)
    Ok(_) => fail("Malformed source buffer was accepted")
  }
  match resample_test_metadata([]).resample_rgba8(source, 50000000, 3) {
    Err(error) => assert_eq(error.kind, LimitExceeded)
    Ok(_) => fail("Oversized output was accepted")
  }
}

///|
test "fractional crop containment is exact at rational raster boundaries" {
  let edge : AvifCleanAperture = {
    width_n: 4L,
    width_d: 5L,
    height_n: 1L,
    height_d: 1L,
    horizontal_n: 1L,
    horizontal_d: 10L,
    vertical_n: 0L,
    vertical_d: 1L,
  }
  let image = Image::new(1, 1)
  image.set_pixel(0, 0, 10, 20, 30, 255)
  let output = resample_test_metadata([Crop(edge)])
    .resample_rgba8(image, 1, 1)
    .unwrap()
  assert_eq(output.data, image.data)
  let outside = { ..edge, horizontal_n: 214748365L, horizontal_d: 2147483647L, }
  assert_eq(
    demux_test_error(
      resample_test_metadata([Crop(outside)]).resample_rgba8(image, 1, 1),
    ),
    InvalidData,
  )
  // These cross products exceed signed Int64; the last two rectangles differ
  // by less than one Double ULP but are on opposite sides of the boundary.
  assert_false(
    avif_resample_axis_inside((100000000L, 1L), 1L, 4294967295L, -50000000L, 1L),
  )
  assert_true(
    avif_resample_axis_inside(
      (4294967295L, 4294967294L),
      4294967294L,
      4294967295L,
      1L,
      4294967295L,
    ),
  )
  assert_false(
    avif_resample_axis_inside(
      (4294967295L, 4294967294L),
      4294967294L,
      4294967295L,
      1L,
      4294967294L,
    ),
  )
}

///|
test "parsed clap offsets sign extend int32 before display and resampling" {
  // Width/height one, horizontal offset -1/2, vertical offset zero.
  let data : Array[Byte] = [
    0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 255, 255, 255, 255, 0, 0, 0,
    2, 0, 0, 0, 0, 0, 0, 0, 1,
  ]
  let builder = metadata_builder(32)
  metadata_property(builder, data, {
    typ: 0x636C6170,
    start: 0,
    payload: 0,
    end: 32,
    parent: -1,
  })
  let metadata = metadata_finish(builder, Some(1), None)
  match metadata.transforms[0] {
    Crop(crop) => assert_eq(crop.horizontal_n, -1L)
    _ => fail("clap did not produce a crop")
  }
  let image = Image::new(2, 1)
  image.set_pixel(0, 0, 10, 20, 30, 255)
  image.set_pixel(1, 0, 40, 50, 60, 255)
  assert_eq(
    metadata.apply_rgba8(image).unwrap().get_pixel(0, 0),
    (b'\x0A', b'\x14', b'\x1E', b'\xFF'),
  )
  assert_eq(
    metadata.resample_rgba8(image, 1, 1).unwrap().data,
    metadata.apply_rgba8(image).unwrap().data,
  )
}
