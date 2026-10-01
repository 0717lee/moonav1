/// Public entry points preserve their original function types.
/// DecodeLimits methods offer per-call policies without adding labels to
/// existing unary functions, so values such as map(avif_decode_rgba) still work.

///|
/// Decode an AV1 OBU stream with fresh reference state and return its first
/// displayed frame after native-depth filtering and final color conversion.
pub fn av1_decode(data : Array[Byte]) -> Image? {
  av1_decode_limited(data)
}

///|
/// Apply this policy to av1_decode; None also reports invalid/exceeded limits.
pub fn DecodeLimits::av1_decode(
  self : DecodeLimits,
  data : Array[Byte],
) -> Image? {
  av1_decode_limited(data, limits=Some(self))
}

///|
/// Decode the first displayed monochrome frame through shared AV1 reconstruction.
/// Alpha represents coverage, so its final conversion always uses full UNORM.
pub fn av1_decode_alpha(data : Array[Byte]) -> Array[Byte]? {
  av1_decode_alpha_limited(data)
}

///|
/// Apply this policy to av1_decode_alpha; None also reports invalid/exceeded limits.
pub fn DecodeLimits::av1_decode_alpha(
  self : DecodeLimits,
  data : Array[Byte],
) -> Array[Byte]? {
  av1_decode_alpha_limited(data, limits=Some(self))
}

///|
/// Decode raw low-overhead AV1 OBUs with fresh reference state and return
/// the first selected presentation. Monochrome is accepted. None means
/// rejection or no displayed picture. No RGBA conversion is performed.
pub fn av1_decode_native(data : Array[Byte]) -> Av1NativeFrame? {
  av1_decode_native_limited(data)
}

///|
/// Apply this policy to av1_decode_native; None also reports invalid/exceeded limits.
pub fn DecodeLimits::av1_decode_native(
  self : DecodeLimits,
  data : Array[Byte],
) -> Av1NativeFrame? {
  av1_decode_native_limited(data, limits=Some(self))
}

///|
/// Decode raw AV1 and convert its first selected presentation to RGBA16.
pub fn av1_decode_rgba16(data : Array[Byte]) -> Image16? {
  av1_decode_rgba16_limited(data)
}

///|
/// Apply this policy to av1_decode_rgba16; None also reports invalid/exceeded limits.
pub fn DecodeLimits::av1_decode_rgba16(
  self : DecodeLimits,
  data : Array[Byte],
) -> Image16? {
  av1_decode_rgba16_limited(data, limits=Some(self))
}

///|
/// Decode a temporal unit and return its first displayed image. All frames in
/// the unit update the reference map. Use av1_video_decode_temporal_unit to
/// receive one presentation per temporal unit, including show-existing. OP0's
/// highest spatial layer actually present is selected independently per unit.
pub fn av1_video_decode_frame(
  decoder : Av1VideoDecoder,
  data : Array[Byte],
  allow_monochrome? : Bool = false,
) -> Image? {
  av1_video_decode_frame_limited(decoder, data, allow_monochrome~)
}

///|
/// Apply this policy to av1_video_decode_frame; None also reports invalid/exceeded limits.
pub fn DecodeLimits::av1_video_decode_frame(
  self : DecodeLimits,
  decoder : Av1VideoDecoder,
  data : Array[Byte],
  allow_monochrome? : Bool = false,
) -> Image? {
  av1_video_decode_frame_limited(
    decoder,
    data,
    allow_monochrome~,
    limits=Some(self),
  )
}

///|
/// Decode temporal units in bitstream order, selecting the highest spatial
/// layer actually present in OP0 for each unit. Input may contain several
/// TD-delimited units; an ISOBMFF sample implicitly ends its single unit.
/// Some([]) denotes a valid unit containing only hidden frames or metadata;
/// None denotes malformed syntax or a missing reference.
/// Failure does not roll back reference updates; discard the decoder after
/// None. Native output is available through av1_video_decode_temporal_unit_native
/// and can be interleaved with this entry point on the same decoder.
pub fn av1_video_decode_temporal_unit(
  decoder : Av1VideoDecoder,
  data : Array[Byte],
  allow_monochrome? : Bool = false,
) -> Array[Image]? {
  av1_video_decode_temporal_unit_limited(decoder, data, allow_monochrome~)
}

///|
/// Apply this policy to av1_video_decode_temporal_unit; None also reports invalid/exceeded limits.
pub fn DecodeLimits::av1_video_decode_temporal_unit(
  self : DecodeLimits,
  decoder : Av1VideoDecoder,
  data : Array[Byte],
  allow_monochrome? : Bool = false,
) -> Array[Image]? {
  av1_video_decode_temporal_unit_limited(
    decoder,
    data,
    allow_monochrome~,
    limits=Some(self),
  )
}

///|
/// Decode temporal units using the same state and presentation policy as
/// av1_video_decode_temporal_unit, returning owned native-depth pictures.
/// Some([]) means valid input with no presentation; hidden frames still
/// update references. None means rejection. State is not rolled back on
/// failure; discard the decoder after None. Monochrome is opt-in, matching
/// the RGBA video entry point. The two APIs can share one decoder in order.
pub fn av1_video_decode_temporal_unit_native(
  decoder : Av1VideoDecoder,
  data : Array[Byte],
  allow_monochrome? : Bool = false,
) -> Array[Av1NativeFrame]? {
  av1_video_decode_temporal_unit_native_limited(
    decoder,
    data,
    allow_monochrome~,
  )
}

///|
/// Apply this policy to av1_video_decode_temporal_unit_native; None also reports invalid/exceeded limits.
pub fn DecodeLimits::av1_video_decode_temporal_unit_native(
  self : DecodeLimits,
  decoder : Av1VideoDecoder,
  data : Array[Byte],
  allow_monochrome? : Bool = false,
) -> Array[Av1NativeFrame]? {
  av1_video_decode_temporal_unit_native_limited(
    decoder,
    data,
    allow_monochrome~,
    limits=Some(self),
  )
}

///|
/// Extract the first alpha item associated with the primary image through
/// auxl and the alpha auxC URN. None also represents malformed input for this
/// public Option API; composition uses the checked internal query instead.
pub fn avif_alpha_item_descriptor(
  data : Array[Byte],
) -> AvifAlphaItemDescriptor? {
  avif_alpha_item_descriptor_limited(data)
}

///|
/// Apply this policy to avif_alpha_item_descriptor; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_alpha_item_descriptor(
  self : DecodeLimits,
  data : Array[Byte],
) -> AvifAlphaItemDescriptor? {
  avif_alpha_item_descriptor_limited(data, limits=Some(self))
}

///|
/// Return the validated raw auxiliary alpha item bytes in extent order.
/// The bytes are still AV1 payload data and are not interpreted as pixels.
pub fn avif_alpha_item_payload(data : Array[Byte]) -> Array[Byte]? {
  avif_alpha_item_payload_limited(data)
}

///|
/// Apply this policy to avif_alpha_item_payload; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_alpha_item_payload(
  self : DecodeLimits,
  data : Array[Byte],
) -> Array[Byte]? {
  avif_alpha_item_payload_limited(data, limits=Some(self))
}

///|
pub fn avif_container_parse(data : Array[Byte]) -> AvifContainer? {
  avif_container_parse_limited(data)
}

///|
/// Apply this policy to avif_container_parse; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_container_parse(
  self : DecodeLimits,
  data : Array[Byte],
) -> AvifContainer? {
  avif_container_parse_limited(data, limits=Some(self))
}

///|
/// Decode the AVIF primary item's selected frame or grid with fresh AV1
/// reference state. The RGBA entry point additionally composes auxiliary alpha.
pub fn avif_decode(data : Array[Byte]) -> Image? {
  avif_decode_limited(data)
}

///|
/// Apply this policy to avif_decode; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_decode(
  self : DecodeLimits,
  data : Array[Byte],
) -> Image? {
  avif_decode_limited(data, limits=Some(self))
}

///|
/// Decode the validated auxiliary alpha item from a complete AVIF container.
/// The result is a row-major 8-bit alpha plane, rounded from its native depth.
pub fn avif_decode_alpha(data : Array[Byte]) -> Array[Byte]? {
  avif_decode_alpha_limited(data)
}

///|
/// Apply this policy to avif_decode_alpha; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_decode_alpha(
  self : DecodeLimits,
  data : Array[Byte],
) -> Array[Byte]? {
  avif_decode_alpha_limited(data, limits=Some(self))
}

///|
/// Parse and decode all animation samples from a self-contained BMFF buffer.
pub fn avif_decode_animation(data : Array[Byte]) -> AvifAnimationPixels? {
  avif_decode_animation_limited(data)
}

///|
/// Apply this policy to avif_decode_animation; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_decode_animation(
  self : DecodeLimits,
  data : Array[Byte],
) -> AvifAnimationPixels? {
  avif_decode_animation_limited(data, limits=Some(self))
}

///|
/// Decode an AVIF sequence and select the image visible at `timestamp` in
/// track timescale units.  The full sequence is validated before selection;
/// malformed timing or pixel samples therefore cannot produce a partial frame.
pub fn avif_decode_animation_frame(
  data : Array[Byte],
  timestamp : Int,
) -> Image? {
  avif_decode_animation_frame_limited(data, timestamp)
}

///|
/// Apply this policy to avif_decode_animation_frame; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_decode_animation_frame(
  self : DecodeLimits,
  data : Array[Byte],
  timestamp : Int,
) -> Image? {
  avif_decode_animation_frame_limited(data, timestamp, limits=Some(self))
}

///|
/// Decode an ordered set of AV1 animation samples using the native decoder.
/// A malformed or unsupported sample rejects the whole sequence so callers do
/// not accidentally present a partial animation.
pub fn avif_decode_animation_frames(
  descriptor : AvifAnimationDescriptor,
  samples : Array[Array[Byte]],
) -> AvifAnimationPixels? {
  avif_decode_animation_frames_limited(descriptor, samples)
}

///|
/// Apply this policy to avif_decode_animation_frames; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_decode_animation_frames(
  self : DecodeLimits,
  descriptor : AvifAnimationDescriptor,
  samples : Array[Array[Byte]],
) -> AvifAnimationPixels? {
  avif_decode_animation_frames_limited(descriptor, samples, limits=Some(self))
}

///|
/// Decode the entire AVIF animation at 8/10/12-bit native precision.
/// Each color/alpha track keeps its own AV1 reference state. Track association,
/// exact time alignment, metadata and rejection follow avif_decode_animation;
/// color conversion and alpha range expansion/unpremultiplication are omitted.
/// None rejects the whole animation, including a malformed later sample.
pub fn avif_decode_animation_native(data : Array[Byte]) -> AvifNativeAnimation? {
  avif_decode_animation_native_limited(data)
}

///|
/// Apply this policy to avif_decode_animation_native; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_decode_animation_native(
  self : DecodeLimits,
  data : Array[Byte],
) -> AvifNativeAnimation? {
  avif_decode_animation_native_limited(data, limits=Some(self))
}

///|
/// Convenience entrypoint for callers that already extracted sample timing
/// tables. The arrays must match the sample order and length.
pub fn avif_decode_animation_samples(
  timescale : Int,
  timestamps : Array[Int],
  durations : Array[Int],
  samples : Array[Array[Byte]],
) -> AvifAnimationPixels? {
  avif_decode_animation_samples_limited(
    timescale, timestamps, durations, samples,
  )
}

///|
/// Apply this policy to avif_decode_animation_samples; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_decode_animation_samples(
  self : DecodeLimits,
  timescale : Int,
  timestamps : Array[Int],
  durations : Array[Int],
  samples : Array[Array[Byte]],
) -> AvifAnimationPixels? {
  avif_decode_animation_samples_limited(
    timescale,
    timestamps,
    durations,
    samples,
    limits=Some(self),
  )
}

///|
/// Decode a grid directly from a BMFF buffer and its parsed descriptor.
/// Each tile may contain one or more iloc extents; extents are concatenated
/// before passing the sample to the pure AV1 decoder.
pub fn avif_decode_grid(
  data : Array[Byte],
  descriptor : AvifGridDescriptor,
) -> Image? {
  avif_decode_grid_limited(data, descriptor)
}

///|
/// Apply this policy to avif_decode_grid; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_decode_grid(
  self : DecodeLimits,
  data : Array[Byte],
  descriptor : AvifGridDescriptor,
) -> Image? {
  avif_decode_grid_limited(data, descriptor, limits=Some(self))
}

///|
/// Decode and compose a grid directly from a BMFF buffer.  This convenience
/// entrypoint performs descriptor extraction and pixel reconstruction as one
/// operation, so callers cannot accidentally skip the `dimg` ordering or
/// extent validation step.
pub fn avif_decode_grid_auto(data : Array[Byte]) -> Image? {
  avif_decode_grid_auto_limited(data)
}

///|
/// Apply this policy to avif_decode_grid_auto; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_decode_grid_auto(
  self : DecodeLimits,
  data : Array[Byte],
) -> Image? {
  avif_decode_grid_auto_limited(data, limits=Some(self))
}

///|
/// Decode ordered AV1 grid tile samples and compose them into one image.
/// The samples must be in row-major grid order; unsupported tile syntax
/// rejects the whole image instead of returning a partial reconstruction.
pub fn avif_decode_grid_tiles(
  rows : Int,
  columns : Int,
  output_width : Int,
  output_height : Int,
  samples : Array[Array[Byte]],
) -> Image? {
  avif_decode_grid_tiles_limited(
    rows, columns, output_width, output_height, samples,
  )
}

///|
/// Apply this policy to avif_decode_grid_tiles; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_decode_grid_tiles(
  self : DecodeLimits,
  rows : Int,
  columns : Int,
  output_width : Int,
  output_height : Int,
  samples : Array[Array[Byte]],
) -> Image? {
  avif_decode_grid_tiles_limited(
    rows,
    columns,
    output_width,
    output_height,
    samples,
    limits=Some(self),
  )
}

///|
/// Decode AVIF primary color and optional alpha at native precision.
/// Grid assembly, layer selection and metadata follow avif_decode_rgba.
/// Invalid or unsupported color/alpha input returns None, never partial color.
/// This is the primary-item API; it does not return an animation timeline.
pub fn avif_decode_native(data : Array[Byte]) -> AvifNativeImage? {
  avif_decode_native_limited(data)
}

///|
/// Apply this policy to avif_decode_native; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_decode_native(
  self : DecodeLimits,
  data : Array[Byte],
) -> AvifNativeImage? {
  avif_decode_native_limited(data, limits=Some(self))
}

///|
/// Decode a primary AVIF image and compose its validated auxiliary alpha item.
/// A valid image without an alpha item keeps the existing opaque result; an
/// alpha item that cannot be decoded is reported as `None` rather than dropped.
pub fn avif_decode_rgba(data : Array[Byte]) -> Image? {
  avif_decode_rgba_limited(data)
}

///|
/// Apply this policy to avif_decode_rgba; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_decode_rgba(
  self : DecodeLimits,
  data : Array[Byte],
) -> Image? {
  avif_decode_rgba_limited(data, limits=Some(self))
}

///|
/// Decode an AVIF primary image/grid with optional alpha to straight RGBA16.
pub fn avif_decode_rgba16(data : Array[Byte]) -> Image16? {
  avif_decode_rgba16_limited(data)
}

///|
/// Apply this policy to avif_decode_rgba16; None also reports invalid/exceeded limits.
pub fn DecodeLimits::avif_decode_rgba16(
  self : DecodeLimits,
  data : Array[Byte],
) -> Image16? {
  avif_decode_rgba16_limited(data, limits=Some(self))
}
