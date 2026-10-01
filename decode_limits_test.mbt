///|
fn limits_one() -> @moonav1.DecodeLimits {
  {
    max_input_bytes: 100000,
    max_frame_pixels: 4096,
    max_total_pixels: 4096,
    max_frames: 1,
  }
}

///|
test "existing decoder functions retain unary callback types" {
  let raw : (Array[Byte]) -> @moonav1.Av1NativeFrame? = @moonav1.av1_decode_native
  assert_true(raw(limits_raw()) is Some(_))
  let images = [limits_grid()].map(@moonav1.avif_decode_rgba)
  assert_true(images[0] is Some(_))
  let rgba8 : Array[(Array[Byte]) -> @moonav1.Image?] = [
    @moonav1.av1_decode, @moonav1.avif_decode, @moonav1.avif_decode_rgba, @moonav1.avif_decode_grid_auto,
  ]
  let rgba16 : Array[(Array[Byte]) -> @moonav1.Image16?] = [
    @moonav1.av1_decode_rgba16, @moonav1.avif_decode_rgba16,
  ]
  let alpha : Array[(Array[Byte]) -> Array[Byte]?] = [
    @moonav1.av1_decode_alpha, @moonav1.avif_decode_alpha, @moonav1.avif_alpha_item_payload,
  ]
  for decode in rgba8 {
    assert_true(decode([]) is None)
  }
  for decode in rgba16 {
    assert_true(decode([]) is None)
  }
  for decode in alpha {
    assert_true(decode([]) is None)
  }
  let native_image : (Array[Byte]) -> @moonav1.AvifNativeImage? = @moonav1.avif_decode_native
  let animation : (Array[Byte]) -> @moonav1.AvifNativeAnimation? = @moonav1.avif_decode_animation_native
  let rgba_animation : (Array[Byte]) -> @moonav1.AvifAnimationPixels? = @moonav1.avif_decode_animation
  let metadata : (Array[Byte]) -> @moonav1.AvifContainer? = @moonav1.avif_container_parse
  let auxiliary : (Array[Byte]) -> @moonav1.AvifAlphaItemDescriptor? = @moonav1.avif_alpha_item_descriptor
  assert_true(native_image([]) is None)
  assert_true(animation([]) is None)
  assert_true(rgba_animation([]) is None)
  assert_true(metadata([]) is None)
  assert_true(auxiliary([]) is None)
}

///|
test "decode limits accept exact boundary and reject each exceeded resource" {
  let data = limits_raw()
  let limit = limits_one()
  let exact = { ..limit, max_input_bytes: data.length(), }
  assert_true(exact.av1_decode_native(data) is Some(_))
  for
    rejected in [
      { ..exact, max_input_bytes: data.length() - 1, },
      { ..exact, max_frame_pixels: 4095, },
      { ..exact, max_total_pixels: 4095, },
      { ..exact, max_frames: 0, },
      { ..exact, max_total_pixels: -1, },
      { ..exact, max_frame_pixels: 100000001, },
    ] {
    assert_true(rejected.av1_decode_native(data) is None)
  }
  let plain = @moonav1.av1_decode_native(data).unwrap()
  let bounded = exact.av1_decode_native(data).unwrap()
  for p in 0..<plain.planes.length() {
    assert_eq(plain.planes[p].data, bounded.planes[p].data)
  }
  assert_true(exact.av1_decode(data) is Some(_))
  assert_true(exact.av1_decode_rgba16(data) is Some(_))
}

///|
test "limits charge hidden pictures and show-existing before returning presentations" {
  let data = limits_hidden()
  let limit = { ..limits_one(), max_frames: 4, max_total_pixels: 4 * 4096, }
  let good = limit
    .av1_video_decode_temporal_unit_native(@moonav1.av1_video_decoder(), data)
    .unwrap()
  assert_eq(good.length(), 3)
  assert_true({ ..limit, max_frames: 3, }.av1_decode_native(data) is None)
  assert_true(
    { ..limit, max_total_pixels: 4 * 4096 - 1, }.av1_decode_native(data) is None,
  )
}

///|
test "video work budgets reset per call and reject before frame allocation" {
  let decoder = @moonav1.av1_video_decoder()
  let data = limits_raw()
  let limit = limits_one()
  for _ in 0..<3 {
    assert_eq(
      limit
      .av1_video_decode_temporal_unit_native(decoder, data)
      .unwrap()
      .length(),
      1,
    )
  }
  let rejected = @moonav1.av1_video_decoder()
  assert_true(
    { ..limit, max_frame_pixels: 1, }.av1_video_decode_temporal_unit_native(
      rejected, data,
    )
    is None,
  )
  assert_true(rejected.map.valid.all(value => !value))
  assert_true(rejected.map.slots.all(value => value is None))
}

///|
test "limits count padded super-resolution pixels rather than coded width" {
  let data = limits_superres()
  let limit = {
    ..limits_one(),
    max_frame_pixels: 104 * 72,
    max_total_pixels: 104 * 72,
  }
  let frame = limit.av1_decode_native(data).unwrap()
  assert_eq((frame.width, frame.height), (97, 65))
  assert_true(
    { ..limit, max_frame_pixels: 104 * 72 - 1, }.av1_decode_native(data) is None,
  )
}

///|
test "AVIF grid limits include both canvases and every color alpha cell" {
  let data = limits_grid()
  let limit : @moonav1.DecodeLimits = {
    max_input_bytes: data.length(),
    max_frame_pixels: 96 * 98,
    max_total_pixels: 2 * (96 * 98 + 4 * 64 * 64),
    max_frames: 8,
  }
  let image = limit.avif_decode_native(data).unwrap()
  assert_eq((image.color.width, image.color.height), (96, 98))
  assert_true(image.alpha is Some(_))
  for
    rejected in [
      { ..limit, max_total_pixels: limit.max_total_pixels - 1, },
      { ..limit, max_frames: 7, },
      { ..limit, max_frame_pixels: 96 * 98 - 1, },
    ] {
    assert_true(rejected.avif_decode_native(data) is None)
    assert_true(rejected.avif_decode_rgba(data) is None)
    assert_true(rejected.avif_decode_rgba16(data) is None)
  }
  assert_true(limit.avif_decode_rgba(data) is Some(_))
  assert_true(limit.avif_decode_rgba16(data) is Some(_))
}

///|
test "animation budgets cover all frames and both tracks" {
  let data = limits_animation()
  let limit : @moonav1.DecodeLimits = {
    max_input_bytes: data.length(),
    max_frame_pixels: 16 * 16,
    max_total_pixels: 6 * 16 * 16,
    max_frames: 6,
  }
  assert_eq(
    limit.avif_decode_animation_native(data).unwrap().frames.length(),
    3,
  )
  assert_true(limit.avif_decode_animation(data) is Some(_))
  let rejected = { ..limit, max_frames: 5, }
  assert_true(rejected.avif_decode_animation_native(data) is None)
  assert_true(rejected.avif_decode_animation(data) is None)
  assert_true(rejected.avif_decode_animation_frame(data, 0) is None)
}

///|
test "sample-array entry points share frame and compressed-byte budgets" {
  let sample = limits_raw()
  let limit = {
    ..limits_one(),
    max_frames: 2,
    max_total_pixels: 2 * 4096,
    max_input_bytes: 2 * sample.length(),
  }
  assert_true(
    limit.avif_decode_animation_samples(1, [0, 1], [1, 1], [sample, sample])
    is Some(_),
  )
  assert_true(
    { ..limit, max_frames: 1, }.avif_decode_animation_samples(
      1,
      [0, 1],
      [1, 1],
      [sample, sample],
    )
    is None,
  )
  assert_true(
    { ..limit, max_input_bytes: 2 * sample.length() - 1, }.avif_decode_animation_samples(
      1,
      [0, 1],
      [1, 1],
      [sample, sample],
    )
    is None,
  )
  let grid_limit = {
    ..limit,
    max_frame_pixels: 128 * 64,
    max_total_pixels: 4 * 4096,
  }
  assert_true(
    grid_limit.avif_decode_grid_tiles(1, 2, 128, 64, [sample, sample])
    is Some(_),
  )
  assert_true(
    limit.avif_decode_grid_tiles(1, 2, 128, 64, [sample, sample]) is None,
  )
}
