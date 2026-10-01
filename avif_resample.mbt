///|
/// Continuous display transforms for callers that choose the output raster.
/// Source coordinates use pixel centers: integer x/y values are pixel
/// centers and the image boundary is [-0.5, width - 0.5].  A crop's first
/// center is `(width - crop_width) / 2 + horizontal_offset`, with the same
/// rule vertically.  The transform chain is composed before sampling, so a
/// crop/rotation/mirror sequence performs one interpolation pass.
///
/// Interpolation is performed in the input image's encoded channel-number
/// domain.  It does not assume sRGB or apply a transfer curve.  Alpha is
/// premultiplied for the weighted samples and the returned image is straight
/// RGBA.  Coordinates outside the source pixel-center interval are extended
/// by clamping to the nearest edge center.
priv struct AvifResampleMap {
  width : Double
  height : Double
  width_ratio : (Int64, Int64)
  height_ratio : (Int64, Int64)
  xx : Double
  xy : Double
  yx : Double
  yy : Double
  tx : Double
  ty : Double
}

///|
fn avif_resample_finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
fn avif_resample_source_shape(
  width : Int,
  height : Int,
  length : Int,
  context : String,
) -> Result[Unit, DecodeError] {
  if width <= 0 || height <= 0 || width > MAX_IMAGE_PIXELS / height {
    return Err(
      decode_error(InvalidData, context, "Source image dimensions are invalid"),
    )
  }
  let expected = width * height * 4
  if length != expected {
    return Err(
      decode_error(
        InvalidBuffer,
        context,
        "RGBA buffer size does not match source dimensions",
      ),
    )
  }
  Ok(())
}

///|
fn avif_resample_output_shape(
  width : Int,
  height : Int,
  context : String,
) -> Result[Unit, DecodeError] {
  if width <= 0 || height <= 0 {
    return Err(
      decode_error(InvalidData, context, "Output dimensions must be positive"),
    )
  }
  if width > MAX_IMAGE_PIXELS / height {
    return Err(
      decode_error(
        LimitExceeded,
        context,
        "Output image exceeds the maximum pixel count",
      ),
    )
  }
  Ok(())
}

///|
fn avif_resample_crop(
  crop : AvifCleanAperture,
  map : AvifResampleMap,
) -> Result[(Double, Double, Double, Double), DecodeError] {
  for
    value in [
      crop.width_n,
      crop.width_d,
      crop.height_n,
      crop.height_d,
      crop.horizontal_d,
      crop.vertical_d,
    ] {
    if value <= 0L || value > 4294967295L {
      return Err(
        decode_error(
          InvalidData,
          "clap",
          "Aperture sizes and denominators must be positive uint32 values",
        ),
      )
    }
  }
  if crop.horizontal_n < -2147483648L ||
    crop.horizontal_n > 2147483647L ||
    crop.vertical_n < -2147483648L ||
    crop.vertical_n > 2147483647L {
    return Err(
      decode_error(
        InvalidData,
        "clap",
        "Aperture offset numerator is outside int32",
      ),
    )
  }
  let crop_width = crop.width_n.to_double() / crop.width_d.to_double()
  let crop_height = crop.height_n.to_double() / crop.height_d.to_double()
  let horizontal = crop.horizontal_n.to_double() / crop.horizontal_d.to_double()
  let vertical = crop.vertical_n.to_double() / crop.vertical_d.to_double()
  if !avif_resample_finite(crop_width) ||
    !avif_resample_finite(crop_height) ||
    !avif_resample_finite(horizontal) ||
    !avif_resample_finite(vertical) ||
    crop_width <= 0.0 ||
    crop_height <= 0.0 {
    return Err(
      decode_error(
        InvalidData,
        "clap",
        "Aperture rational values are not finite and positive",
      ),
    )
  }
  // Bounds are a rational comparison, not a floating-point tolerance.
  // Three uint32 factors can require 96 bits. Standard-library BigInt keeps
  // boundary decisions exact; it is used once per transform, never per pixel.
  if !avif_resample_axis_inside(
      map.width_ratio,
      crop.width_n,
      crop.width_d,
      crop.horizontal_n,
      crop.horizontal_d,
    ) ||
    !avif_resample_axis_inside(
      map.height_ratio,
      crop.height_n,
      crop.height_d,
      crop.vertical_n,
      crop.vertical_d,
    ) {
    return Err(
      decode_error(
        InvalidData,
        "clap",
        "Aperture geometry is outside the source raster",
      ),
    )
  }
  let max_left = map.width - crop_width
  let max_top = map.height - crop_height
  let raw_left = max_left / 2.0 + horizontal
  let raw_top = max_top / 2.0 + vertical
  // Exact validation already proved containment. Clamp round-off at a legal
  // boundary, without admitting a mathematically out-of-bounds rectangle.
  let left = if raw_left < 0.0 {
    0.0
  } else if raw_left > max_left {
    max_left
  } else {
    raw_left
  }
  let top = if raw_top < 0.0 {
    0.0
  } else if raw_top > max_top {
    max_top
  } else {
    raw_top
  }
  Ok((left, top, crop_width, crop_height))
}

///|
fn avif_resample_axis_inside(
  parent : (Int64, Int64),
  size_n : Int64,
  size_d : Int64,
  offset_n : Int64,
  offset_d : Int64,
) -> Bool {
  let parent_n = @bigint.BigInt::from_int64(parent.0)
  let parent_d = @bigint.BigInt::from_int64(parent.1)
  let numerator = @bigint.BigInt::from_int64(size_n)
  let denominator = @bigint.BigInt::from_int64(size_d)
  let spare = parent_n * denominator - numerator * parent_d
  if spare.compare_int(0) < 0 {
    return false
  }
  let magnitude = if offset_n < 0L { -offset_n } else { offset_n }
  let distance = @bigint.BigInt::from_int64(2L * magnitude) *
    parent_d *
    denominator
  spare * @bigint.BigInt::from_int64(offset_d) >= distance
}

///|
fn avif_resample_map(
  metadata : AvifMetadata,
  width : Int,
  height : Int,
) -> Result[AvifResampleMap, DecodeError] {
  if width <= 0 || height <= 0 || width > MAX_IMAGE_PIXELS / height {
    return Err(
      decode_error(
        InvalidData,
        "display",
        "Source image dimensions are invalid",
      ),
    )
  }
  let mut map : AvifResampleMap = {
    width: width.to_double(),
    height: height.to_double(),
    width_ratio: (width.to_int64(), 1L),
    height_ratio: (height.to_int64(), 1L),
    xx: 1.0,
    xy: 0.0,
    yx: 0.0,
    yy: 1.0,
    tx: 0.0,
    ty: 0.0,
  }
  for transform in metadata.transforms {
    match transform {
      Crop(crop) => {
        let (left, top, crop_width, crop_height) = match
          avif_resample_crop(crop, map) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        map = {
          ..map,
          width: crop_width,
          height: crop_height,
          width_ratio: (crop.width_n, crop.width_d),
          height_ratio: (crop.height_n, crop.height_d),
          tx: map.tx + map.xx * left + map.xy * top,
          ty: map.ty + map.yx * left + map.yy * top,
        }
      }
      Rotate(turns) => {
        if turns < 0 || turns > 3 {
          return Err(
            decode_error(InvalidData, "irot", "Rotation must be in 0..3"),
          )
        }
        for _ in 0..<turns {
          map = {
            width: map.height,
            height: map.width,
            width_ratio: map.height_ratio,
            height_ratio: map.width_ratio,
            xx: map.xy,
            xy: -map.xx,
            yx: map.yy,
            yy: -map.yx,
            tx: map.tx + map.xx * (map.width - 1.0),
            ty: map.ty + map.yx * (map.width - 1.0),
          }
        }
      }
      Mirror(mode) =>
        if mode == 0 {
          map = {
            ..map,
            xy: -map.xy,
            yy: -map.yy,
            tx: map.tx + map.xy * (map.height - 1.0),
            ty: map.ty + map.yy * (map.height - 1.0),
          }
        } else if mode == 1 {
          map = {
            ..map,
            xx: -map.xx,
            yx: -map.yx,
            tx: map.tx + map.xx * (map.width - 1.0),
            ty: map.ty + map.yx * (map.width - 1.0),
          }
        } else {
          return Err(
            decode_error(InvalidData, "imir", "Mirror mode must be 0 or 1"),
          )
        }
    }
    if !avif_resample_finite(map.width) ||
      !avif_resample_finite(map.height) ||
      !avif_resample_finite(map.xx) ||
      !avif_resample_finite(map.xy) ||
      !avif_resample_finite(map.yx) ||
      !avif_resample_finite(map.yy) ||
      !avif_resample_finite(map.tx) ||
      !avif_resample_finite(map.ty) {
      return Err(
        decode_error(
          InvalidData,
          "display",
          "Display transform produced non-finite geometry",
        ),
      )
    }
  }
  Ok(map)
}

///|
fn avif_resample_axis(value : Double, limit : Int) -> (Int, Int, Double) {
  let maximum = (limit - 1).to_double()
  let clamped = if value <= 0.0 {
    0.0
  } else if value >= maximum {
    maximum
  } else {
    value
  }
  let left = clamped.to_int()
  let right = if left + 1 < limit { left + 1 } else { left }
  (left, right, clamped - left.to_double())
}

///|
fn avif_resample_u8(value : Double) -> Byte {
  if value <= 0.0 {
    b'\x00'
  } else if value >= 255.0 {
    b'\xFF'
  } else {
    (value + 0.5).to_int().to_byte()
  }
}

///|
fn avif_resample_u16(value : Double) -> UInt16 {
  if value <= 0.0 {
    (0 : UInt16)
  } else if value >= 65535.0 {
    (65535 : UInt16)
  } else {
    (value + 0.5).to_int().to_uint16()
  }
}

///|
fn avif_resample_bilinear8(
  data : FixedArray[Byte],
  width : Int,
  height : Int,
  source_x : Double,
  source_y : Double,
) -> (Byte, Byte, Byte, Byte) {
  let (x0, x1, fx) = avif_resample_axis(source_x, width)
  let (y0, y1, fy) = avif_resample_axis(source_y, height)
  let wx0 = 1.0 - fx
  let wx1 = fx
  let wy0 = 1.0 - fy
  let wy1 = fy
  let mut premult_r = 0.0
  let mut premult_g = 0.0
  let mut premult_b = 0.0
  let mut alpha = 0.0
  for tap in 0..<4 {
    let x = if (tap & 1) == 0 { x0 } else { x1 }
    let y = if tap < 2 { y0 } else { y1 }
    let wx = if (tap & 1) == 0 { wx0 } else { wx1 }
    let wy = if tap < 2 { wy0 } else { wy1 }
    let weight = wx * wy
    let at = (y * width + x) * 4
    let coverage = data[at + 3].to_int().to_double() / 255.0
    alpha += weight * coverage
    premult_r += weight * data[at].to_int().to_double() * coverage
    premult_g += weight * data[at + 1].to_int().to_double() * coverage
    premult_b += weight * data[at + 2].to_int().to_double() * coverage
  }
  if alpha <= 0.0 {
    (b'\x00', b'\x00', b'\x00', b'\x00')
  } else {
    (
      avif_resample_u8(premult_r / alpha),
      avif_resample_u8(premult_g / alpha),
      avif_resample_u8(premult_b / alpha),
      avif_resample_u8(alpha * 255.0),
    )
  }
}

///|
fn avif_resample_bilinear16(
  data : FixedArray[UInt16],
  width : Int,
  height : Int,
  source_x : Double,
  source_y : Double,
) -> (UInt16, UInt16, UInt16, UInt16) {
  let (x0, x1, fx) = avif_resample_axis(source_x, width)
  let (y0, y1, fy) = avif_resample_axis(source_y, height)
  let wx0 = 1.0 - fx
  let wx1 = fx
  let wy0 = 1.0 - fy
  let wy1 = fy
  let mut premult_r = 0.0
  let mut premult_g = 0.0
  let mut premult_b = 0.0
  let mut alpha = 0.0
  for tap in 0..<4 {
    let x = if (tap & 1) == 0 { x0 } else { x1 }
    let y = if tap < 2 { y0 } else { y1 }
    let wx = if (tap & 1) == 0 { wx0 } else { wx1 }
    let wy = if tap < 2 { wy0 } else { wy1 }
    let weight = wx * wy
    let at = (y * width + x) * 4
    let coverage = data[at + 3].to_int().to_double() / 65535.0
    alpha += weight * coverage
    premult_r += weight * data[at].to_int().to_double() * coverage
    premult_g += weight * data[at + 1].to_int().to_double() * coverage
    premult_b += weight * data[at + 2].to_int().to_double() * coverage
  }
  if alpha <= 0.0 {
    ((0 : UInt16), (0 : UInt16), (0 : UInt16), (0 : UInt16))
  } else {
    (
      avif_resample_u16(premult_r / alpha),
      avif_resample_u16(premult_g / alpha),
      avif_resample_u16(premult_b / alpha),
      avif_resample_u16(alpha * 65535.0),
    )
  }
}

///|
fn avif_resample_source_point(
  map : AvifResampleMap,
  x : Int,
  y : Int,
  output_width : Int,
  output_height : Int,
) -> (Double, Double) {
  let logical_x = (x.to_double() + 0.5) * map.width / output_width.to_double() -
    0.5
  let logical_y = (y.to_double() + 0.5) * map.height / output_height.to_double() -
    0.5
  (
    map.xx * logical_x + map.xy * logical_y + map.tx,
    map.yx * logical_x + map.yy * logical_y + map.ty,
  )
}

///|
/// Fractional crop/resize/display transform for straight RGBA8.
///
/// The output owns a fresh buffer.  If the transform chain is an exact
/// integer crop/permutation and the requested dimensions match it, this uses
/// the exact display path so identity and rotation/mirror cases retain their
/// byte-for-byte behavior.
pub fn AvifMetadata::resample_rgba8(
  self : AvifMetadata,
  image : Image,
  width : Int,
  height : Int,
) -> Result[Image, DecodeError] {
  match
    avif_resample_source_shape(
      image.width,
      image.height,
      image.data.length(),
      "resample",
    ) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match avif_resample_output_shape(width, height, "resample") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match avif_display_map(self, image.width, image.height) {
    Ok(exact) if exact.width == width && exact.height == height =>
      return self.apply_rgba8(image)
    _ => ()
  }
  let map = match avif_resample_map(self, image.width, image.height) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output = FixedArray::make(width * height * 4, b'\x00')
  for i in 0..<(width * height) {
    let x = i % width
    let y = i / width
    let (source_x, source_y) = avif_resample_source_point(
      map, x, y, width, height,
    )
    let (r, g, b, a) = avif_resample_bilinear8(
      image.data,
      image.width,
      image.height,
      source_x,
      source_y,
    )
    output[i * 4] = r
    output[i * 4 + 1] = g
    output[i * 4 + 2] = b
    output[i * 4 + 3] = a
  }
  Ok({ width, height, data: output, })
}

///|
/// Fractional crop/resize/display transform for straight RGBA16.
pub fn AvifMetadata::resample_rgba16(
  self : AvifMetadata,
  image : Image16,
  width : Int,
  height : Int,
) -> Result[Image16, DecodeError] {
  match
    avif_resample_source_shape(
      image.width,
      image.height,
      image.data.length(),
      "resample",
    ) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match avif_resample_output_shape(width, height, "resample") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match avif_display_map(self, image.width, image.height) {
    Ok(exact) if exact.width == width && exact.height == height =>
      return self.apply_rgba16(image)
    _ => ()
  }
  let map = match avif_resample_map(self, image.width, image.height) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output = FixedArray::make(width * height * 4, (0 : UInt16))
  for i in 0..<(width * height) {
    let x = i % width
    let y = i / width
    let (source_x, source_y) = avif_resample_source_point(
      map, x, y, width, height,
    )
    let (r, g, b, a) = avif_resample_bilinear16(
      image.data,
      image.width,
      image.height,
      source_x,
      source_y,
    )
    output[i * 4] = r
    output[i * 4 + 1] = g
    output[i * 4 + 2] = b
    output[i * 4 + 3] = a
  }
  Ok({ width, height, data: output, })
}
