///|
/// Straight RGBA UNORM16, row-major R/G/B/A, four UInt16 samples per pixel.
/// Each channel spans 0..65535; alpha 65535 is opaque. This is an integer
/// buffer, not half-float or serialized bytes. The caller owns its data.
pub struct Image16 {
  width : Int
  height : Int
  data : FixedArray[UInt16]
}

///|
/// Native buffers are caller-mutable: validate their shape and sample range
/// before conversion instead of reading a mismatched plane or wrapping a value.
fn av1_native_pixels_valid(frame : Av1NativeFrame) -> Bool {
  if frame.width <= 0 ||
    frame.height <= 0 ||
    frame.width > MAX_IMAGE_PIXELS / frame.height ||
    (frame.bit_depth != 8 && frame.bit_depth != 10 && frame.bit_depth != 12) ||
    (frame.planes.length() != 1 && frame.planes.length() != 3) {
    return false
  }
  if frame.planes.length() == 3 && frame.subsampling_y && !frame.subsampling_x {
    return false
  }
  let maximum = (1 << frame.bit_depth) - 1
  for p in 0..<frame.planes.length() {
    let plane = frame.planes[p]
    let w = if p > 0 && frame.subsampling_x {
      (frame.width + 1) / 2
    } else {
      frame.width
    }
    let h = if p > 0 && frame.subsampling_y {
      (frame.height + 1) / 2
    } else {
      frame.height
    }
    if plane.width != w || plane.height != h || plane.data.length() != w * h {
      return false
    }
    for sample in plane.data {
      if sample < 0 || sample > maximum {
        return false
      }
    }
  }
  true
}

///|
fn av1_rgba16_quantize(value : Double) -> UInt16 {
  let clipped = if value <= 0.0 {
    0.0
  } else if value >= 1.0 {
    1.0
  } else {
    value
  }
  (clipped * 65535.0 + 0.5).to_int().to_uint16()
}

///|
fn av1_rgba16_straight(
  value : Double,
  maximum : Double,
  coverage : Double,
) -> Double {
  if coverage == 0.0 || value <= 0.0 {
    0.0
  } else {
    let clipped = if value >= 1.0 { 1.0 } else { value }
    let result = clipped * maximum / coverage
    if result > 1.0 {
      1.0
    } else {
      result
    }
  }
}

///|
fn av1_rgba16_inputs_valid(
  color : Av1NativeFrame,
  alpha : Av1NativeFrame?,
  premultiplied : Bool,
) -> Bool {
  if !av1_native_pixels_valid(color) || (premultiplied && alpha is None) {
    return false
  }
  if alpha is Some(plane) {
    if !av1_native_pixels_valid(plane) ||
      plane.width != color.width ||
      plane.height != color.height ||
      plane.bit_depth != color.bit_depth ||
      plane.planes.length() != 1 {
      return false
    }
  }
  let mono = color.planes.length() == 1
  if !mono &&
    (
      !av1_color_supported(
        color.matrix_coefficients,
        color.color_primaries,
        color.transfer_characteristics,
      ) ||
      (
        color.matrix_coefficients == 0 &&
        (color.subsampling_x || color.subsampling_y)
      )
    ) {
    return false
  }
  true
}

///|
fn av1_write_rgba16(
  color : Av1NativeFrame,
  alpha : Av1NativeFrame?,
  premultiplied : Bool,
  out : FixedArray[UInt16],
  row_stride : Int,
  sample_offset : Int,
) -> Bool {
  let mono = color.planes.length() == 1
  let maximum = (1 << color.bit_depth) - 1
  let scale = 1 << (color.bit_depth - 8)
  let black = if color.full_range { 0.0 } else { (16 * scale).to_double() }
  let luma_span = if color.full_range {
    maximum.to_double()
  } else {
    (219 * scale).to_double()
  }
  let chroma_span = if color.full_range {
    maximum.to_double()
  } else if color.matrix_coefficients == 8 {
    (219 * scale).to_double()
  } else {
    (224 * scale).to_double()
  }
  let midpoint = (128 * scale).to_double()
  let maximum_f = maximum.to_double()
  let luma = color.planes[0].data
  // Monochrome never reads chroma. Reusing its plane here avoids optional
  // plane lookups in the pixel loop without allocating dummy planes.
  let u_plane = color.planes[if mono { 0 } else { 1 }]
  let v_plane = color.planes[if mono { 0 } else { 2 }]
  let u_data = u_plane.data
  let v_data = v_plane.data
  for row in 0..<color.height {
    let row_start = row * color.width
    let chroma_row = if color.subsampling_y { row / 2 } else { row }
    let chroma_start = chroma_row * u_plane.width
    for x in 0..<color.width {
      let i = row_start + x
      let y = (luma[i].to_double() - black) / luma_span
      // Keep channels scalar across the optional stages: constructing RGB
      // tuples here otherwise allocates once or twice for every pixel.
      let mut r = y
      let mut g = y
      let mut b = y
      if !mono {
        let cx = if color.subsampling_x { x / 2 } else { x }
        let ci = chroma_start + cx
        let u = u_data[ci].to_double()
        let v = v_data[ci].to_double()
        if color.matrix_coefficients == 0 {
          r = (v - black) / luma_span
          b = (u - black) / luma_span
        } else {
          match
            av1_color_rgb(
              y,
              (u - midpoint) / chroma_span,
              (v - midpoint) / chroma_span,
              color.matrix_coefficients,
              color.color_primaries,
              color.transfer_characteristics,
            ) {
            Some((red, green, blue)) => {
              r = red
              g = green
              b = blue
            }
            None => return false
          }
        }
      }
      let coverage = match alpha {
        None => maximum
        Some(frame) => {
          let sample = frame.planes[0].data[i]
          if frame.full_range {
            sample
          } else {
            av1_alpha_expand_limited_sample(sample, frame.bit_depth)
          }
        }
      }
      // Undo premultiplication with native alpha before RGB quantization.
      if premultiplied {
        let coverage_f = coverage.to_double()
        r = av1_rgba16_straight(r, maximum_f, coverage_f)
        g = av1_rgba16_straight(g, maximum_f, coverage_f)
        b = av1_rgba16_straight(b, maximum_f, coverage_f)
      }
      if !mono && color.color_primaries == 10 {
        match av1_color_xyz_to_srgb(r, g, b, color.transfer_characteristics) {
          Some((red, green, blue)) => {
            r = red
            g = green
            b = blue
          }
          None => return false
        }
      }
      if r.is_nan() ||
        g.is_nan() ||
        b.is_nan() ||
        r.is_inf() ||
        g.is_inf() ||
        b.is_inf() {
        return false
      }
      let destination = sample_offset + row * row_stride + x * 4
      out[destination] = av1_rgba16_quantize(r)
      out[destination + 1] = av1_rgba16_quantize(g)
      out[destination + 2] = av1_rgba16_quantize(b)
      out[destination + 3] = ((coverage * 65535 + maximum / 2) / maximum).to_uint16()
    }
  }
  true
}

///|
fn av1_native_to_rgba16(
  color : Av1NativeFrame,
  alpha : Av1NativeFrame?,
  premultiplied : Bool,
) -> Image16? {
  if !av1_rgba16_inputs_valid(color, alpha, premultiplied) {
    return None
  }
  let out = FixedArray::make(color.width * color.height * 4, (0 : UInt16))
  if !av1_write_rgba16(color, alpha, premultiplied, out, color.width * 4, 0) {
    return None
  }
  Some({ width: color.width, height: color.height, data: out, })
}

///|
/// Convert an owned native frame to opaque RGBA16 without decoding again.
/// Nearest chroma and source color/transfer conventions match RGBA8; XYZ is
/// converted to BT.709/sRGB. No HDR tone mapping is performed. Malformed
/// caller-edited planes or unsupported color metadata return None.
pub fn Av1NativeFrame::to_rgba16(self : Av1NativeFrame) -> Image16? {
  av1_native_to_rgba16(self, None, false)
}

///|
/// Convert a static image or animation sample to straight RGBA16. Limited
/// alpha is expanded at its original depth; prem is undone with native alpha
/// before final RGB16 rounding. This does not quantize through RGBA8.
/// The returned buffer shares no mutable data with this image or prior outputs.
pub fn AvifNativeImage::to_rgba16(self : AvifNativeImage) -> Image16? {
  av1_native_to_rgba16(self.color, self.alpha, self.premultiplied)
}

///|
/// Decode raw AV1 and convert its first selected presentation to RGBA16.
fn av1_decode_rgba16_limited(
  data : Array[Byte],
  limits? : DecodeLimits? = None,
) -> Image16? {
  match av1_decode_native_limited(data, limits~) {
    Some(frame) => frame.to_rgba16()
    None => None
  }
}

///|
/// Decode an AVIF primary image/grid with optional alpha to straight RGBA16.
fn avif_decode_rgba16_limited(
  data : Array[Byte],
  limits? : DecodeLimits? = None,
) -> Image16? {
  match avif_decode_native_limited(data, limits~) {
    Some(image) => image.to_rgba16()
    None => None
  }
}
