///|
/// Exact clap fractions. Sizes/denominators are unsigned 32-bit values;
/// offsets are signed 32-bit numerators. No floating-point rounding is applied.
pub(all) struct AvifCleanAperture {
  width_n : Int64
  width_d : Int64
  height_n : Int64
  height_d : Int64
  horizontal_n : Int64
  horizontal_d : Int64
  vertical_n : Int64
  vertical_d : Int64
} derive(Eq, Debug)

///|
/// Rotation is anticlockwise in quarter turns. Mirror mode 0 exchanges top
/// and bottom; mode 1 exchanges left and right (HEIF mode, not the old axis).
pub(all) enum AvifDisplayTransform {
  Crop(AvifCleanAperture)
  Rotate(Int)
  Mirror(Int)
} derive(Eq, Debug)

///|
/// Owned metadata for a primary item or a selected picture track. Exif is the
/// item payload after its four-byte offset field; exif_tiff_offset locates TIFF
/// inside it. ICC/Exif/XMP are opaque bytes, not an ICC engine or an XML parser.
/// Transforms retain property-association order. Pixel aspect ratio is metadata
/// only; applying raster transforms does not resample nonsquare pixels.
pub struct AvifMetadata {
  primary_item_id : Int?
  track_id : Int?
  icc : FixedArray[Byte]?
  exif : FixedArray[Byte]?
  exif_tiff_offset : Int?
  xmp : FixedArray[Byte]?
  pixel_aspect_ratio : (Int64, Int64)?
  transforms : FixedArray[AvifDisplayTransform]
}

///|
priv struct AvifDisplayMap {
  width : Int
  height : Int
  xx : Int
  xy : Int
  yx : Int
  yy : Int
  tx : Int
  ty : Int
}

///|
fn avif_crop_rect(
  crop : AvifCleanAperture,
  width : Int,
  height : Int,
) -> Result[(Int, Int, Int, Int), DecodeError] {
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
  if crop.width_n % crop.width_d != 0L ||
    crop.height_n % crop.height_d != 0L ||
    crop.horizontal_n * 2L % crop.horizontal_d != 0L ||
    crop.vertical_n * 2L % crop.vertical_d != 0L {
    return Err(
      decode_error(
        Unsupported,
        "clap",
        "Fractional aperture requires resampling; metadata remains available",
      ),
    )
  }
  let w = crop.width_n / crop.width_d
  let h = crop.height_n / crop.height_d
  let x2 = width.to_int64() - w + crop.horizontal_n * 2L / crop.horizontal_d
  let y2 = height.to_int64() - h + crop.vertical_n * 2L / crop.vertical_d
  if x2 % 2L != 0L || y2 % 2L != 0L {
    return Err(
      decode_error(
        Unsupported,
        "clap",
        "Aperture origin is not an integer pixel",
      ),
    )
  }
  let x = x2 / 2L
  let y = y2 / 2L
  if w > width.to_int64() ||
    h > height.to_int64() ||
    x < 0L ||
    y < 0L ||
    x > width.to_int64() - w ||
    y > height.to_int64() - h {
    return Err(
      decode_error(InvalidData, "clap", "Aperture is outside the image"),
    )
  }
  Ok((x.to_int(), y.to_int(), w.to_int(), h.to_int()))
}

///|
fn avif_display_map(
  metadata : AvifMetadata,
  width : Int,
  height : Int,
) -> Result[AvifDisplayMap, DecodeError] {
  if width <= 0 || height <= 0 || width > MAX_IMAGE_PIXELS / height {
    return Err(decode_error(InvalidData, "display", "Invalid image dimensions"))
  }
  let mut map : AvifDisplayMap = {
    width,
    height,
    xx: 1,
    xy: 0,
    yx: 0,
    yy: 1,
    tx: 0,
    ty: 0,
  }
  for transform in metadata.transforms {
    match transform {
      Crop(crop) => {
        let (x, y, w, h) = match avif_crop_rect(crop, map.width, map.height) {
          Ok(rect) => rect
          Err(error) => return Err(error)
        }
        map = {
          ..map,
          width: w,
          height: h,
          tx: map.tx + map.xx * x + map.xy * y,
          ty: map.ty + map.yx * x + map.yy * y,
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
            xx: map.xy,
            xy: -map.xx,
            yx: map.yy,
            yy: -map.yx,
            tx: map.tx + map.xx * (map.width - 1),
            ty: map.ty + map.yx * (map.width - 1),
          }
        }
      }
      Mirror(mode) =>
        if mode == 0 {
          map = {
            ..map,
            xy: -map.xy,
            yy: -map.yy,
            tx: map.tx + map.xy * (map.height - 1),
            ty: map.ty + map.yy * (map.height - 1),
          }
        } else if mode == 1 {
          map = {
            ..map,
            xx: -map.xx,
            yx: -map.yx,
            tx: map.tx + map.xx * (map.width - 1),
            ty: map.ty + map.yx * (map.width - 1),
          }
        } else {
          return Err(
            decode_error(InvalidData, "imir", "Mirror mode must be 0 or 1"),
          )
        }
    }
  }
  Ok(map)
}

///|
/// Validate the transform chain and report resulting raster dimensions.
pub fn AvifMetadata::display_size(
  self : AvifMetadata,
  width : Int,
  height : Int,
) -> Result[(Int, Int), DecodeError] {
  match avif_display_map(self, width, height) {
    Ok(map) => Ok((map.width, map.height))
    Err(error) => Err(error)
  }
}

///|
fn[T] avif_display_pixels(
  metadata : AvifMetadata,
  pixels : FixedArray[T],
  width : Int,
  height : Int,
) -> Result[(Int, Int, FixedArray[T]), DecodeError] {
  let map = match avif_display_map(metadata, width, height) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if pixels.length() != width * height * 4 {
    return Err(
      decode_error(
        InvalidData,
        "display",
        "RGBA buffer size does not match the image",
      ),
    )
  }
  let output = FixedArray::makei(map.width * map.height * 4, i => {
    let x = i / 4 % map.width
    let y = i / 4 / map.width
    let sx = map.xx * x + map.xy * y + map.tx
    let sy = map.yx * x + map.yy * y + map.ty
    pixels[(sy * width + sx) * 4 + i % 4]
  })
  Ok((map.width, map.height, output))
}

///|
/// Explicit, exact raster permutation/crop. Color and alpha move together;
/// ICC, Exif orientation and pixel aspect ratio are not applied implicitly.
/// The result owns a new buffer even for an empty transform chain.
pub fn AvifMetadata::apply_rgba16(
  self : AvifMetadata,
  image : Image16,
) -> Result[Image16, DecodeError] {
  match avif_display_pixels(self, image.data, image.width, image.height) {
    Ok((width, height, data)) => Ok({ width, height, data, })
    Err(error) => Err(error)
  }
}

///|
pub fn AvifMetadata::apply_rgba8(
  self : AvifMetadata,
  image : Image,
) -> Result[Image, DecodeError] {
  match avif_display_pixels(self, image.data, image.width, image.height) {
    Ok((width, height, data)) => Ok({ width, height, data, })
    Err(error) => Err(error)
  }
}
