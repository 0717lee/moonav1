///|
fn depth_boxes(kind : Int, depth : Int) -> Array[Byte] {
  let data = Array::make(depth * 8, b'\x00')
  for index in 0..<depth {
    let size = (depth - index) * 8
    for byte in 0..<4 {
      data[index * 8 + byte] = ((size >> ((3 - byte) * 8)) & 255).to_byte()
      data[index * 8 + 4 + byte] = ((kind >> ((3 - byte) * 8)) & 255).to_byte()
    }
  }
  data
}

///|
test "AVIF walkers bound nesting without rejecting the exact depth boundary" {
  let primary = depth_boxes(t_ipco, 64)
  let boxes : Array[Box] = []
  walk(primary, 0, primary.length(), -1, boxes)
  assert_eq(boxes.length(), 64)
  let auxiliary : Array[AuxBox] = []
  aux_walk(primary, 0, primary.length(), -1, auxiliary)
  assert_eq(auxiliary.length(), 64)
  let animation = depth_boxes(ga_moov, 64)
  let tracks : Array[GaBox] = []
  ga_walk(animation, 0, animation.length(), -1, tracks)
  assert_eq(tracks.length(), 64)
  let deep = depth_boxes(t_ipco, 65)
  let deep_animation = depth_boxes(ga_moov, 65)
  let main_rejected = try {
    walk(deep, 0, deep.length(), -1, [])
    false
  } catch {
    _ => true
  }
  let alpha_rejected = try {
    aux_walk(deep, 0, deep.length(), -1, [])
    false
  } catch {
    _ => true
  }
  let animation_rejected = try {
    ga_walk(deep_animation, 0, deep_animation.length(), -1, [])
    false
  } catch {
    _ => true
  }
  assert_true(main_rejected && alpha_rejected && animation_rejected)
}

///|
test "repeated grid extents cannot amplify an assembled payload beyond its byte budget" {
  // Existing 64x64 grid-reconstruction test's AV1 payload.
  let raw : Array[Byte] = [
    b'\x0A', b'\x06', b'\x18', b'\x15', b'\x7F', b'\xFD', b'\xB0', b'\x08', b'\x32',
    b'\x13', b'\x18', b'\x00', b'\x00', b'\x00', b'\x50', b'\x00', b'\x00', b'\x00',
    b'\x0A', b'\x05', b'\x79', b'\x52', b'\x6E', b'\x43', b'\xD9', b'\x3A', b'\x46',
    b'\x02', b'\x28',
  ]
  let data = raw.copy()
  data.push(b'\x7a') // Sized padding OBU, no additional decoded picture.
  data.push(b'\x01')
  data.push(b'\x00')
  let extents : Array[AvifGridExtent] = [
    { offset: 0, length: raw.length(), construction_method: 0, },
  ]
  for _ in 0..<16 {
    extents.push({ offset: raw.length(), length: 3, construction_method: 0, })
  }
  let descriptor : AvifGridDescriptor = {
    item_id: 1,
    rows: 1,
    columns: 1,
    output_width: 64,
    output_height: 64,
    tiles: [{ item_id: 2, extents, }],
  }
  let limit : DecodeLimits = {
    max_frame_pixels: 4096,
    max_frames: 1,
    max_input_bytes: raw.length() + 48,
    max_total_pixels: 8192,
  }
  assert_true(limit.avif_decode_grid(data, descriptor) is Some(_))
  assert_true(
    { ..limit, max_input_bytes: raw.length() + 47, }.avif_decode_grid(
      data, descriptor,
    )
    is None,
  )
}
