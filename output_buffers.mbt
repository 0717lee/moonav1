///|
/// Native samples: U16 stores unshifted values; High16 left-aligns the original
/// sample bits. U8 is valid only for eight-bit pictures. No range/RGB conversion.
pub(all) enum PixelPacking {
  U8
  U16LE
  U16BE
  High16LE
  High16BE
} derive(Eq, Debug)

///|
fn output_buffer_fits(
  length : Int,
  offset : Int,
  stride : Int,
  row : Int,
  height : Int,
) -> Bool {
  offset >= 0 &&
  offset <= length &&
  row > 0 &&
  height > 0 &&
  stride >= row &&
  row <= length - offset &&
  height - 1 <= (length - offset - row) / stride
}

///|
/// Copy one native plane into a reusable byte buffer. row_bytes and offset are
/// in bytes; row padding and bytes outside the visible rectangle are untouched.
/// Invalid arguments/samples reject before any destination write. This export
/// does not expose or reuse the decoder's reference buffers.
pub fn Av1NativeFrame::copy_plane_into(
  self : Av1NativeFrame,
  plane : Int,
  destination : FixedArray[Byte],
  row_bytes : Int,
  packing : PixelPacking,
  offset? : Int = 0,
) -> Result[Unit, DecodeError] {
  if !av1_native_pixels_valid(self) ||
    plane < 0 ||
    plane >= self.planes.length() {
    return Err(
      decode_error(
        InvalidData,
        "pixels",
        "Invalid native picture or plane index",
      ),
    )
  }
  if packing == U8 && self.bit_depth != 8 {
    return Err(
      decode_error(
        Unsupported,
        "packing",
        "U8 packing cannot preserve a high-bit-depth sample",
      ),
    )
  }
  let bytes = if packing == U8 { 1 } else { 2 }
  let source = self.planes[plane]
  if !output_buffer_fits(
      destination.length(),
      offset,
      row_bytes,
      source.width * bytes,
      source.height,
    ) {
    return Err(
      decode_error(
        InvalidBuffer,
        "output",
        "Destination offset, stride or capacity is invalid",
      ),
    )
  }
  let shift = if packing == High16LE || packing == High16BE {
    16 - self.bit_depth
  } else {
    0
  }
  let big = packing == U16BE || packing == High16BE
  for y in 0..<source.height {
    for x in 0..<source.width {
      let value = source.data[y * source.width + x] << shift
      let at = offset + y * row_bytes + x * bytes
      if bytes == 1 {
        destination[at] = value.to_byte()
      } else {
        destination[at] = (if big { value >> 8 } else { value & 255 }).to_byte()
        destination[at + 1] = (if big { value & 255 } else { value >> 8 }).to_byte()
      }
    }
  }
  Ok(())
}

///|
fn av1_rgba16_into(
  color : Av1NativeFrame,
  alpha : Av1NativeFrame?,
  premultiplied : Bool,
  destination : FixedArray[UInt16],
  row_stride : Int,
  offset : Int,
) -> Result[Unit, DecodeError] {
  if !av1_rgba16_inputs_valid(color, alpha, premultiplied) {
    return Err(
      decode_error(
        InvalidData,
        "pixels",
        "Invalid native planes or unsupported color conversion",
      ),
    )
  }
  if !output_buffer_fits(
      destination.length(),
      offset,
      row_stride,
      color.width * 4,
      color.height,
    ) {
    return Err(
      decode_error(
        InvalidBuffer,
        "output",
        "Destination offset, stride or capacity is invalid",
      ),
    )
  }
  if !av1_write_rgba16(
      color, alpha, premultiplied, destination, row_stride, offset,
    ) {
    return Err(
      decode_error(
        InvalidData,
        "color",
        "Color conversion failed; destination may be partially written",
      ),
    )
  }
  Ok(())
}

///|
/// Write straight RGBA16 directly into caller storage. Stride and offset count
/// UInt16 channels, not bytes. Argument rejection leaves the destination intact;
/// an unexpected numerical conversion failure may leave a partial destination.
/// This removes output allocation; reconstruction/validation costs still apply.
pub fn Av1NativeFrame::to_rgba16_into(
  self : Av1NativeFrame,
  destination : FixedArray[UInt16],
  row_stride : Int,
  offset? : Int = 0,
) -> Result[Unit, DecodeError] {
  av1_rgba16_into(self, None, false, destination, row_stride, offset)
}

///|
/// Native alpha and premultiplication use the same precision and order as
/// to_rgba16(). Row padding and surrounding destination channels are untouched.
pub fn AvifNativeImage::to_rgba16_into(
  self : AvifNativeImage,
  destination : FixedArray[UInt16],
  row_stride : Int,
  offset? : Int = 0,
) -> Result[Unit, DecodeError] {
  av1_rgba16_into(
    self.color,
    self.alpha,
    self.premultiplied,
    destination,
    row_stride,
    offset,
  )
}

///|
/// Serialize straight UNORM16 channels, preserving the exact values.
pub fn Image16::copy_bytes_into(
  self : Image16,
  destination : FixedArray[Byte],
  row_bytes : Int,
  big_endian? : Bool = false,
  offset? : Int = 0,
) -> Result[Unit, DecodeError] {
  if self.width <= 0 ||
    self.height <= 0 ||
    self.width > MAX_IMAGE_PIXELS / self.height ||
    self.data.length() != self.width * self.height * 4 {
    return Err(
      decode_error(InvalidData, "pixels", "Invalid RGBA16 image shape"),
    )
  }
  if !output_buffer_fits(
      destination.length(),
      offset,
      row_bytes,
      self.width * 8,
      self.height,
    ) {
    return Err(
      decode_error(
        InvalidBuffer,
        "output",
        "Destination offset, stride or capacity is invalid",
      ),
    )
  }
  for y in 0..<self.height {
    for channel in 0..<(self.width * 4) {
      let value = self.data[y * self.width * 4 + channel].to_int()
      let at = offset + y * row_bytes + channel * 2
      destination[at] = (if big_endian { value >> 8 } else { value & 255 }).to_byte()
      destination[at + 1] = (if big_endian { value & 255 } else { value >> 8 }).to_byte()
    }
  }
  Ok(())
}
