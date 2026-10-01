///|
fn main {
  let input = metadata_fixture()
  let metadata = @moonav1.avif_metadata(input).unwrap()
  let image = @moonav1.avif_decode_native_result(input).unwrap()
  let displayed = metadata.apply_rgba16(image.to_rgba16().unwrap()).unwrap()
  println(
    "Metadata: ICC=\{metadata.icc.unwrap().length()} bytes, transforms=\{metadata.transforms.length()}, display=\{displayed.width}x\{displayed.height}",
  )

  let stride = image.color.width * 4 + 8
  let buffer : FixedArray[UInt16] = FixedArray::make(
    stride * image.color.height,
    0,
  )
  image.to_rgba16_into(buffer, stride).unwrap()
  let y = image.color.planes[0]
  let packed = FixedArray::make(y.width * y.height * 2, b'\x00')
  image.color
  .copy_plane_into(0, packed, y.width * 2, @moonav1.High16LE)
  .unwrap()
  println(
    "Buffers: RGBA16 stride=\{stride} channels, native Y=\{packed.length()} bytes",
  )

  let raw = @moonav1.avif_container_parse_result(input).unwrap().payload
  let stream = @moonav1.Av1StreamDecoder::new().unwrap()
  let mut frames = 0
  let mut at = 0
  while at < raw.length() {
    let size = if raw.length() - at < 13 { raw.length() - at } else { 13 }
    let batch = stream.feed(Array::makei(size, i => raw[at + i])).unwrap()
    frames += batch.frames.length()
    at += size
  }
  frames += stream.finish().unwrap().frames.length()
  println("Chunks: \{frames} presentation, pending=\{stream.pending_bytes()}")

  let animation = @moonav1.AvifAnimationDecoder::new(animation_fixture()).unwrap()
  let first = animation.next_frame().unwrap().unwrap()
  let last = animation.seek_frame(2).unwrap()
  println(
    "Animation: \{animation.frame_count()} frames, first=\{first.index}, seek=\{last.index}, next=\{animation.position()}",
  )
  animation.reset()
  println("Reset: next=\{animation.next_frame().unwrap().unwrap().index}")

  match @moonav1.av1_decode_native_result([b'\x0A']) {
    Err(error) =>
      if error.kind == @moonav1.TruncatedInput {
        println("Diagnostic: TruncatedInput")
      } else {
        abort("Unexpected diagnostic")
      }
    Ok(_) => abort("Truncated input was accepted")
  }
}
