///|
fn main {
  // Neutral 10-bit sample retained from av1_decode_test.mbt.
  let encoded : Array[Byte] = [
    b'\x12', b'\x00', b'\x0A', b'\x06', b'\x18', b'\x15', b'\x7F', b'\xFE', b'\x08',
    b'\x08', b'\x32', b'\x06', b'\x15', b'\x00', b'\x00', b'\x00', b'\x40', b'\x2E',
  ]
  let image = match @moonav1.av1_decode(encoded) {
    Some(image) => image
    None => abort("AV1 sample was rejected")
  }
  if image.width != 64 || image.height != 64 {
    abort("unexpected decoded dimensions")
  }
  if image.get_pixel(0, 0) != (b'\x82', b'\x82', b'\x82', b'\xFF') {
    abort("unexpected decoded RGBA8 pixel")
  }
  if @moonav1.av1_decode([]) is Some(_) {
    abort("empty input must be rejected")
  }
  println("\{image.width}x\{image.height} AV1 -> RGBA8 OK")
}
