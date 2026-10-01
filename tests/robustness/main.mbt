/// Process-isolated probe. The Python runner gives every input a deadline.
/// No host decoder or exception fallback participates in these calls.

///|
fn nested_boxes(kind : Int, depth : Int) -> Array[Byte] {
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
fn bytes_from_hex(text : String) -> Array[Byte] {
  let digits = text.to_array()
  let data = []
  for i in 0..<(digits.length() / 2) {
    let hi = digits[i * 2].to_int()
    let lo = digits[i * 2 + 1].to_int()
    data.push(
      (((if hi >= 97 { hi - 87 } else { hi - 48 }) << 4) |
      (if lo >= 97 { lo - 87 } else { lo - 48 })).to_byte(),
    )
  }
  data
}

///|
fn inspect_frame(frame : @moonav1.Av1NativeFrame) -> Unit {
  if frame.width <= 0 ||
    frame.height <= 0 ||
    (frame.bit_depth != 8 && frame.bit_depth != 10 && frame.bit_depth != 12) ||
    (frame.planes.length() != 1 && frame.planes.length() != 3) {
    abort("Invalid native frame metadata")
  }
  for p in 0..<frame.planes.length() {
    let dx = if p > 0 && frame.subsampling_x { 2 } else { 1 }
    let dy = if p > 0 && frame.subsampling_y { 2 } else { 1 }
    let plane = frame.planes[p]
    if plane.width != (frame.width + dx - 1) / dx ||
      plane.height != (frame.height + dy - 1) / dy ||
      plane.data.length() != plane.width * plane.height {
      abort("Invalid native plane extent")
    }
    for value in plane.data {
      if value < 0 || value >= 1 << frame.bit_depth {
        abort("Invalid native sample")
      }
    }
  }
}

///|
fn inspect_image(image : @moonav1.AvifNativeImage) -> Unit {
  inspect_frame(image.color)
  match image.alpha {
    None => ()
    Some(alpha) => {
      inspect_frame(alpha)
      if alpha.width != image.color.width ||
        alpha.height != image.color.height ||
        alpha.bit_depth != image.color.bit_depth ||
        alpha.planes.length() != 1 {
        abort("Invalid alpha contract")
      }
    }
  }
}

///|
fn probe_chunks(data : Array[Byte], limits : @moonav1.DecodeLimits) -> Bool {
  let stream = @moonav1.Av1StreamDecoder::new(limits~, allow_monochrome=true).unwrap()
  let mut at = 0
  while at < data.length() {
    let size = if data.length() - at < 17 { data.length() - at } else { 17 }
    match stream.feed(Array::makei(size, i => data[at + i])) {
      Err(_) => return false
      Ok(batch) =>
        for frame in batch.frames {
          inspect_frame(frame)
        }
    }
    at += size
  }
  match stream.finish() {
    Err(_) => false
    Ok(batch) => {
      for frame in batch.frames {
        inspect_frame(frame)
      }
      true
    }
  }
}

///|
fn probe_animation(data : Array[Byte], limits : @moonav1.DecodeLimits) -> Bool {
  let decoder = match @moonav1.AvifAnimationDecoder::new(data, limits~) {
    Err(_) => return false
    Ok(value) => value
  }
  for index in 0..<decoder.frame_count() {
    match decoder.next_frame() {
      Err(_) => return false
      Ok(None) => abort("Premature animation end")
      Ok(Some(frame)) => {
        if frame.index != index {
          abort("Animation index differs")
        }
        inspect_image(frame.image)
      }
    }
  }
  match decoder.next_frame() {
    Ok(None) => true
    _ => abort("Invalid animation end")
  }
}

///|
fn probe_container(data : Array[Byte], limits : @moonav1.DecodeLimits) -> Bool {
  let decoder = match @moonav1.Av1ContainerDecoder::new(data, limits~) {
    Err(_) => return false
    Ok(value) => value
  }
  while true {
    match decoder.next_frame() {
      Err(_) => return false
      Ok(None) => return true
      Ok(Some(value)) => inspect_frame(value.frame)
    }
  } nobreak {
    false
  }
}

///|
fn probe_icc(data : Array[Byte]) -> Bool {
  let profile = match @moonav1.IccProfile::parse(data) {
    Err(_) => return false
    Ok(value) => value
  }
  let source = @moonav1.Image::new(2, 1)
  source.set_pixel(0, 0, 0, 255, 127, 73)
  source.set_pixel(1, 0, 128, 32, 200, 0)
  match profile.apply_rgba8(source) {
    Err(_) => false
    Ok(output) => {
      if output.width != 2 ||
        output.height != 1 ||
        output.data.length() != 8 ||
        output.data[3] != 73 ||
        output.data[7] != 0 {
        abort("ICC output shape or alpha differs")
      }
      true
    }
  }
}

///|
fn probe_container_stream(
  data : Array[Byte],
  limits : @moonav1.DecodeLimits,
) -> Bool {
  let decoder = @moonav1.Av1ContainerStreamDecoder::new(limits~).unwrap()
  for pass in 0..<2 {
    let mut at = 0
    let mut previous = -1
    while at < data.length() {
      let count = if data.length() - at < 17 { data.length() - at } else { 17 }
      let chunk = Array::makei(count, i => data[at + i])
      match decoder.feed(chunk) {
        Err(_) => return false
        Ok(batch) =>
          for value in batch.frames {
            inspect_frame(value.frame)
            if value.packet_index <= previous {
              abort("Stream packet order differs")
            }
            previous = value.packet_index
          }
      }
      for i in 0..<chunk.length() {
        chunk[i] = 0
      }
      if decoder.pending_bytes() > limits.max_input_bytes ||
        decoder.peak_pending_bytes() > limits.max_input_bytes {
        abort("Stream pending input exceeds its policy")
      }
      at += count
    }
    let last = match decoder.finish() {
      Err(_) => return false
      Ok(batch) => batch
    }
    for value in last.frames {
      inspect_frame(value.frame)
    }
    match last.status {
      @moonav1.Finished => return true
      @moonav1.ReplayRequired => {
        if pass != 0 {
          abort("Repeated MP4 replay request")
        }
        match decoder.replay() {
          Err(_) => return false
          Ok(_) => ()
        }
      }
      _ => abort("Container EOF has no terminal state")
    }
  }
  false
}

///|
fn probe_icc_policy(data : Array[Byte]) -> Bool {
  let profile = match @moonav1.IccProfile::parse(data) {
    Err(_) => return false
    Ok(value) => value
  }
  let source = @moonav1.Image::new(2, 1)
  source.set_pixel(0, 0, 0, 32, 64, 73)
  source.set_pixel(1, 0, 48, 211, 86, 123)
  for
    intent in [
      @moonav1.Perceptual,
      @moonav1.RelativeColorimetric,
      @moonav1.Saturation,
      @moonav1.AbsoluteColorimetric,
    ] {
    for bpc in [false, true] {
      if intent is @moonav1.AbsoluteColorimetric && bpc {
        continue
      }
      match
        profile.apply_rgba8_with_options(
          source,
          @moonav1.IccTransformOptions::new(intent, bpc),
        ) {
        Err(_) => return false
        Ok(output) =>
          if output.width != 2 ||
            output.height != 1 ||
            output.data.length() != 8 ||
            output.data[3] != 73 ||
            output.data[7] != 123 {
            abort("ICC policy output shape or alpha differs")
          }
      }
    }
  }
  true
}

///|
fn main {
  let args = @env.args()
  if args.contains("deep-metadata") {
    println(
      if @moonav1.avif_metadata(nested_boxes(0x6970636f, 20000)) is Err(_) {
        "rejected"
      } else {
        "accepted"
      },
    )
  } else if args.contains("deep-lazy-animation") {
    println(
      if @moonav1.AvifAnimationDecoder::new(nested_boxes(0x6d6f6f76, 20000))
        is Err(_) {
        "rejected"
      } else {
        "accepted"
      },
    )
  } else if args.contains("deep-primary") {
    println(
      if @moonav1.avif_container_parse(nested_boxes(0x6970636f, 20000)) is None {
        "rejected"
      } else {
        "accepted"
      },
    )
  } else if args.contains("deep-alpha") {
    println(
      if @moonav1.avif_decode_native(nested_boxes(0x6970636f, 20000)) is None {
        "rejected"
      } else {
        "accepted"
      },
    )
  } else if args.contains("deep-animation") {
    println(
      if @moonav1.avif_animation_descriptor(nested_boxes(0x6d6f6f76, 20000))
        is None {
        "rejected"
      } else {
        "accepted"
      },
    )
  } else {
    let data = bytes_from_hex(args[args.length() - 1])
    let limits = @moonav1.DecodeLimits::{
      max_input_bytes: 16384,
      max_frame_pixels: 65536,
      max_total_pixels: 262144,
      max_frames: 8,
    }
    let accepted = if args.contains("container-stream") {
      probe_container_stream(data, limits)
    } else if args.contains("icc-policy") {
      probe_icc_policy(data)
    } else if args.contains("container") {
      probe_container(data, limits)
    } else if args.contains("icc") {
      probe_icc(data)
    } else if args.contains("chunks") {
      probe_chunks(data, limits)
    } else if args.contains("lazy-animation") {
      probe_animation(data, limits)
    } else if args.contains("metadata") {
      @moonav1.avif_metadata(data, limits~) is Ok(_)
    } else if args.contains("avif") {
      match limits.avif_decode_native(data) {
        Some(image) => {
          inspect_image(image)
          true
        }
        None => false
      }
    } else if args.contains("animation") {
      match limits.avif_decode_animation_native(data) {
        Some(animation) => {
          for frame in animation.frames {
            inspect_image(frame.image)
          }
          true
        }
        None => false
      }
    } else if args.contains("video") {
      match
        limits.av1_video_decode_temporal_unit_native(
          @moonav1.av1_video_decoder(),
          data,
        ) {
        Some(frames) => {
          for frame in frames {
            inspect_frame(frame)
          }
          true
        }
        None => false
      }
    } else {
      match limits.av1_decode_native(data) {
        Some(frame) => {
          inspect_frame(frame)
          true
        }
        None => false
      }
    }
    println(if accepted { "accepted" } else { "rejected" })
  }
}
