///|
/// One visible native-depth plane, tightly packed in row-major order.
/// `data[y * width + x]` is an unshifted sample, not a serialized byte pair.
/// On return, data.length() == width * height and every sample is in
/// 0..<(1 << frame.bit_depth). The caller owns this mutable buffer.
pub struct Av1PixelPlane {
  width : Int
  height : Int
  data : FixedArray[Int]
}

///|
/// A displayed AV1 picture after reconstruction, filters, super-resolution
/// and signaled film grain, before color conversion or range expansion.
/// `planes` contains Y alone for monochrome, otherwise Y, U, V. Matrix 0
/// identifies G, B, R in those same slots. Chroma dimensions round up on
/// subsampled axes. There is no coded padding in any output plane.
///
/// Color identifiers retain their bitstream values (2 means unspecified).
/// AVIF output also applies the existing nclx metadata rules. Samples retain
/// the original 8/10/12-bit precision and full/limited range. All buffers are
/// independent of decoder references, other returned pictures and input data.
pub struct Av1NativeFrame {
  width : Int
  height : Int
  bit_depth : Int
  subsampling_x : Bool
  subsampling_y : Bool
  full_range : Bool
  matrix_coefficients : Int
  color_primaries : Int
  transfer_characteristics : Int
  planes : FixedArray[Av1PixelPlane]
}

///|
/// An AVIF image: a primary image/grid or an animation sample, with validated alpha.
/// Alpha, when present, is a single native-depth plane with the same size
/// and bit depth as color. Its own full_range flag describes its raw samples;
/// limited-range alpha has not been expanded. None means opaque.
/// `premultiplied` reports the color-to-alpha prem association. Color samples
/// have not been unpremultiplied. Use avif_decode_rgba for straight RGBA8.
pub struct AvifNativeImage {
  color : Av1NativeFrame
  alpha : Av1NativeFrame?
  premultiplied : Bool
}

///|
fn av1_frame_to_native(frame : Av1FramePlanes) -> Av1NativeFrame {
  let planes = FixedArray::makei(frame.planes.length(), fn(plane) {
    let (dx, dy) = av1_frame_plane_divisor(frame, plane)
    let width = (frame.width + dx - 1) / dx
    let height = (frame.height + dy - 1) / dy
    let stride = frame.coded_width / dx
    let source = frame.planes[plane]
    let data = if width == stride {
      // A new buffer is still required even when only bottom padding is cut.
      FixedArray::from_array(source[:width * height])
    } else {
      let cropped = FixedArray::make(width * height, 0)
      for y in 0..<height {
        let source_row = y * stride
        let output_row = y * width
        for x in 0..<width {
          cropped[output_row + x] = source[source_row + x]
        }
      }
      cropped
    }
    Av1PixelPlane::{ width, height, data, }
  })
  {
    width: frame.width,
    height: frame.height,
    bit_depth: frame.bit_depth,
    subsampling_x: frame.sub_x == 1,
    subsampling_y: frame.sub_y == 1,
    full_range: frame.full_range,
    matrix_coefficients: frame.matrix_coefficients,
    color_primaries: frame.color_primaries,
    transfer_characteristics: frame.transfer_characteristics,
    planes,
  }
}

///|
/// Decode raw low-overhead AV1 OBUs with fresh reference state and return
/// the first selected presentation. Monochrome is accepted. None means
/// rejection or no displayed picture. No RGBA conversion is performed.
fn av1_decode_native_limited(
  data : Array[Byte],
  limits? : DecodeLimits? = None,
) -> Av1NativeFrame? {
  if !decode_input_allowed(data.length(), limits) {
    return None
  }
  av1_decode_frame_planes(
    data,
    allow_monochrome=true,
    budget=decode_budget(limits),
  ).map(av1_frame_to_native)
}

///|
/// Decode AVIF primary color and optional alpha at native precision.
/// Grid assembly, layer selection and metadata follow avif_decode_rgba.
/// Invalid or unsupported color/alpha input returns None, never partial color.
/// This is the primary-item API; it does not return an animation timeline.
fn avif_decode_native_limited(
  data : Array[Byte],
  limits? : DecodeLimits? = None,
) -> AvifNativeImage? {
  let (color, alpha, premultiplied) = match
    avif_decode_image_planes(data, limits~) {
    Some(value) => value
    None => return None
  }
  Some({
    color: av1_frame_to_native(color),
    alpha: alpha.map(av1_frame_to_native),
    premultiplied,
  })
}

///|
/// Decode temporal units using the same state and presentation policy as
/// av1_video_decode_temporal_unit, returning owned native-depth pictures.
/// Some([]) means valid input with no presentation; hidden frames still
/// update references. None means rejection. State is not rolled back on
/// failure; discard the decoder after None. Monochrome is opt-in, matching
/// the RGBA video entry point. The two APIs can share one decoder in order.
fn av1_video_decode_temporal_unit_native_limited(
  decoder : Av1VideoDecoder,
  data : Array[Byte],
  allow_monochrome? : Bool = false,
  limits? : DecodeLimits? = None,
) -> Array[Av1NativeFrame]? {
  if !decode_input_allowed(data.length(), limits) {
    return None
  }
  av1_video_decode_temporal_unit_planes(
    decoder,
    data,
    allow_monochrome~,
    budget=decode_budget(limits),
  ).map(frames => frames.map(av1_frame_to_native))
}
