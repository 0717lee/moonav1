///|
/// Decode the unchanged independent fixtures in fixtures.mbt. All three
/// backends run this consumer without file I/O or external codec dependencies.
fn main {
  // Opt into an application work policy; video budgets restart per call.
  let limits = @moonav1.DecodeLimits::default()
  let input = example_obu
  let frame = match limits.av1_decode_native(input) {
    Some(value) => value
    None => abort("AV1 input was rejected or has no displayed frame")
  }
  let y = frame.planes[0]
  println(
    "AV1: \{frame.width}x\{frame.height}, \{frame.bit_depth}-bit, \{frame.planes.length()} planes",
  )
  println(
    "Y: \{y.width}x\{y.height}, stride \{y.width} samples, first sample \{y.data[0]}",
  )

  // Each temporal unit uses the same decoder. A valid unit may yield no
  // presentation. Returned samples remain valid after the next decode call.
  let decoder = @moonav1.av1_video_decoder()
  let pictures = match
    limits.av1_video_decode_temporal_unit_native(decoder, input) {
    Some(value) => value
    None => abort("AV1 video unit was rejected; discard this decoder")
  }
  println("Video: \{pictures.length()} presentation(s)")

  // AVIF keeps primary color and auxiliary alpha separate, at their original
  // depth. premultiplied describes the stored association before conversion.
  let image = match limits.avif_decode_native(example_avif) {
    Some(value) => value
    None => abort("AVIF color or alpha was rejected")
  }
  println(
    "AVIF: \{image.color.width}x\{image.color.height}, \{image.color.bit_depth}-bit, premultiplied=\{image.premultiplied}",
  )
  match image.alpha {
    Some(alpha) =>
      println(
        "Alpha: \{alpha.bit_depth}-bit, full_range=\{alpha.full_range}, first sample \{alpha.planes[0].data[0]}",
      )
    None => println("Alpha: opaque")
  }

  // RGBA8 is still available when a caller needs a display-ready byte raster.
  let rgba = @moonav1.av1_decode(input).unwrap()
  println("RGBA8: \{rgba.data.length()} bytes")
  let rgba16 = @moonav1.av1_decode_rgba16(input).unwrap()
  println(
    "RGBA16: \{rgba16.data.length()} UInt16 channels, opaque alpha \{rgba16.data[3].to_int()}",
  )

  // Decode an AVIF sequence once and select repeatedly in primary-track units.
  let animation = match
    @moonav1.avif_decode_animation_native(example_animation) {
    Some(value) => value
    None => abort("AVIF animation was rejected")
  }
  let selected = animation.frame_at(250).unwrap()
  println(
    "Animation: \{animation.frames.length()} frames, timescale \{animation.timescale}, \{selected.image.color.bit_depth}-bit",
  )
  println(
    "At 250: frame \{selected.index}, timestamp \{selected.timestamp}, duration \{selected.duration}, premultiplied=\{selected.image.premultiplied}",
  )
  println("At 600: frame \{animation.frame_at(600).unwrap().index}")
  let selected16 = selected.image.to_rgba16().unwrap()
  let low_alpha = selected.image.alpha.unwrap().planes[0].data[2]
  println(
    "Animation RGBA16: low native alpha \{low_alpha} -> \{selected16.data[11].to_int()}",
  )
}
