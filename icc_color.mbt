///|
/// Pure ICC v2/v4 input/display profile conversion for straight RGBA images.
///
/// The implementation intentionally keeps the supported surface explicit. It
/// accepts RGB and Gray matrix/TRC profiles with XYZ PCS, and A2B LUT profiles
/// with XYZ or Lab PCS. Device-link, printer,
/// n-component, named-color, and output-only workflows are rejected by the
/// parser instead of being guessed.
const ICC_SIG_ACSP : Int = 0x61637370

///|
const ICC_SIG_SCNR : Int = 0x73636E72

///|
const ICC_SIG_MNTR : Int = 0x6D6E7472

///|
const ICC_SIG_PRTR : Int = 0x70727472

///|
const ICC_SIG_LINK : Int = 0x6C696E6B

///|
const ICC_SIG_SPAC : Int = 0x73706163

///|
const ICC_SIG_NMCL : Int = 0x6E6D636C

///|
const ICC_SIG_RGB : Int = 0x52474220

///|
const ICC_SIG_GRAY : Int = 0x47524159

///|
const ICC_SIG_XYZ : Int = 0x58595A20

///|
const ICC_SIG_LAB : Int = 0x4C616220

///|
const ICC_SIG_CURV : Int = 0x63757276

///|
const ICC_SIG_PARA : Int = 0x70617261

///|
const ICC_SIG_XYZ_TYPE : Int = 0x58595A20

///|
const ICC_SIG_MFT1 : Int = 0x6D667431

///|
const ICC_SIG_MFT2 : Int = 0x6D667432

///|
const ICC_SIG_MAB : Int = 0x6D414220

///|
const ICC_SIG_RXYZ : Int = 0x7258595A

///|
const ICC_SIG_GXYZ : Int = 0x6758595A

///|
const ICC_SIG_BXYZ : Int = 0x6258595A

///|
const ICC_SIG_RTRC : Int = 0x72545243

///|
const ICC_SIG_GTRC : Int = 0x67545243

///|
const ICC_SIG_BTRC : Int = 0x62545243

///|
const ICC_SIG_KTRC : Int = 0x6B545243

///|
const ICC_SIG_WTPT : Int = 0x77747074

///|
const ICC_SIG_A2B0 : Int = 0x41324230

///|
const ICC_SIG_A2B1 : Int = 0x41324231

///|
const ICC_SIG_A2B2 : Int = 0x41324232

///|
/// Maximum supported RGB lattice, retaining the existing 65-point limit.
const ICC_MAX_CLUT_CELLS : Int = 274625

///|
/// ICC rendering intents understood by the policy-aware entry points.
pub(all) enum IccRenderingIntent {
  Perceptual
  RelativeColorimetric
  Saturation
  AbsoluteColorimetric
}

///|
/// Rendering and black-point policy for an ICC conversion.
///
/// The legacy `apply_rgba8` and `apply_rgba16` methods use
/// `RelativeColorimetric` with black-point compensation disabled. Use this
/// value with the `*_with_options` methods to select an ICC intent and, when
/// requested, LittleCMS-compatible black-point compensation.
pub struct IccTransformOptions {
  intent : IccRenderingIntent
  black_point_compensation : Bool
}

///|
pub fn IccTransformOptions::new(
  intent : IccRenderingIntent,
  black_point_compensation : Bool,
) -> IccTransformOptions {
  { intent, black_point_compensation, }
}

///|
pub fn IccTransformOptions::relative_colorimetric() -> IccTransformOptions {
  { intent: RelativeColorimetric, black_point_compensation: false, }
}

///|
priv enum IccIssue {
  IccTruncated(String)
  IccInvalid(String)
  IccUnsupported(String)
  IccLimit(String)
}

///|
priv struct IccTag {
  signature : Int
  offset : Int
  size : Int
}

///|
priv enum IccCurve {
  IccIdentity
  IccGamma(Double)
  IccSampled(Array[Double])
  IccParametric(Int, Array[Double])
}

///|
priv struct IccLut {
  input_channels : Int
  output_channels : Int
  grids : Array[Int]
  has_clut : Bool
  clut : Array[Double]
  input_curves : Array[IccCurve]
  middle_curves : Array[IccCurve]
  output_curves : Array[IccCurve]
  matrix : Array[Double]
  translation : Array[Double]
  pcs_lab : Bool
  pcs_xyz_scale : Double
  lab_legacy : Bool
}

///|
priv enum IccPipeline {
  IccMatrixRgb(Array[Double], IccCurve, IccCurve, IccCurve)
  IccMatrixGray(Array[Double], IccCurve)
  IccLutPipeline(IccLut)
}

///|
/// A validated, immutable ICC input/display profile.
pub struct IccProfile {
  priv color_space : Int
  priv pipeline : IccPipeline
  priv source_bytes : Array[Byte]
  priv declared_size : Int
  priv tags : Array[IccTag]
  priv perceptual_tag : IccTag?
  priv saturation_tag : IccTag?
  priv relative_tag : IccTag?
  priv device_class : Int
  priv matrix_shaper : Bool
  priv pcs_lab : Bool
  priv pcs_xyz : Bool
  priv lab_legacy : Bool
}

///|
fn icc_error(issue : IccIssue) -> DecodeError {
  match issue {
    IccTruncated(message) => decode_error(TruncatedInput, "icc", message)
    IccInvalid(message) => decode_error(InvalidData, "icc", message)
    IccUnsupported(message) => decode_error(Unsupported, "icc", message)
    IccLimit(message) => decode_error(LimitExceeded, "icc", message)
  }
}

///|
fn icc_u8(data : Array[Byte], at : Int, limit : Int) -> Int? {
  if at < 0 || at >= limit || at >= data.length() {
    None
  } else {
    Some(data[at].to_int())
  }
}

///|
fn icc_u16(data : Array[Byte], at : Int, limit : Int) -> Int? {
  if at < 0 || at > limit - 2 || at + 1 >= data.length() {
    None
  } else {
    Some((data[at].to_int() << 8) | data[at + 1].to_int())
  }
}

///|
fn icc_u32(data : Array[Byte], at : Int, limit : Int) -> Int? {
  if at < 0 || at > limit - 4 || at + 3 >= data.length() {
    None
  } else {
    let high = data[at].to_int()
    // All offsets, sizes and counts used by this bounded implementation fit
    // in a signed MoonBit Int. Rejecting the sign bit also avoids target
    // dependent overflow on 32-bit WASM.
    if high >= 128 {
      None
    } else {
      Some(
        (high << 24) |
        (data[at + 1].to_int() << 16) |
        (data[at + 2].to_int() << 8) |
        data[at + 3].to_int(),
      )
    }
  }
}

///|
fn icc_s15f16(data : Array[Byte], at : Int, limit : Int) -> Double? {
  match (icc_u16(data, at, limit), icc_u16(data, at + 2, limit)) {
    (Some(high), Some(low)) => {
      let signed = if high >= 32768 { high - 65536 } else { high }
      Some(signed.to_double() + low.to_double() / 65536.0)
    }
    _ => None
  }
}

///|
fn icc_has_range(at : Int, length : Int, limit : Int) -> Bool {
  at >= 0 && length >= 0 && at <= limit && length <= limit - at
}

///|
fn icc_mab_target(
  base : Int,
  relative : Int,
  tag_end : Int,
) -> Result[Int, IccIssue] {
  if relative < 32 || relative % 4 != 0 || relative > tag_end - base {
    return Err(IccInvalid("mAB processing-element offset is invalid"))
  }
  Ok(base + relative)
}

///|
fn icc_tag(tags : Array[IccTag], signature : Int) -> IccTag? {
  for tag in tags {
    if tag.signature == signature {
      return Some(tag)
    }
  }
  None
}

///|
fn icc_clamp(value : Double) -> Double {
  if value <= 0.0 {
    0.0
  } else if value >= 1.0 {
    1.0
  } else {
    value
  }
}

///|
fn icc_curve_count(function_type : Int) -> Int? {
  match function_type {
    0 => Some(1)
    1 => Some(3)
    2 => Some(4)
    3 => Some(5)
    4 => Some(7)
    _ => None
  }
}

///|
fn icc_curve_eval(curve : IccCurve, value : Double) -> Double {
  let x = icc_clamp(value)
  match curve {
    IccIdentity => x
    IccGamma(gamma) => if x <= 0.0 { 0.0 } else { @math.pow(x, gamma) }
    IccSampled(samples) => {
      let count = samples.length()
      if count == 0 {
        x
      } else if count == 1 {
        samples[0]
      } else {
        let position = x * (count - 1).to_double()
        let index = position.to_int()
        if index >= count - 1 {
          samples[count - 1]
        } else {
          let fraction = position - index.to_double()
          samples[index] * (1.0 - fraction) + samples[index + 1] * fraction
        }
      }
    }
    IccParametric(function_type, parameters) => {
      let power = parameters[0]
      let a = if parameters.length() > 1 { parameters[1] } else { 1.0 }
      let b = if parameters.length() > 2 { parameters[2] } else { 0.0 }
      let c = if parameters.length() > 3 { parameters[3] } else { 0.0 }
      let d = if parameters.length() > 4 { parameters[4] } else { 0.0 }
      let e = if parameters.length() > 5 { parameters[5] } else { 0.0 }
      let f = if parameters.length() > 6 { parameters[6] } else { 0.0 }
      let positive_power = fn(base : Double) -> Double {
        if base <= 0.0 {
          0.0
        } else {
          @math.pow(base, power)
        }
      }
      icc_clamp(
        match function_type {
          0 => positive_power(x)
          1 => if x >= -b / a { positive_power(a * x + b) } else { 0.0 }
          2 => if x >= -b / a { positive_power(a * x + b) + c } else { c }
          3 => if x >= d { positive_power(a * x + b) } else { c * x }
          4 => if x >= d { positive_power(a * x + b) + e } else { c * x + f }
          _ => 0.0
        },
      )
    }
  }
}

///|
fn icc_parse_curve_at(
  data : Array[Byte],
  at : Int,
  limit : Int,
) -> Result[(IccCurve, Int), IccIssue] {
  let type_signature = match icc_u32(data, at, limit) {
    Some(value) => value
    None => return Err(IccTruncated("Curve type header is truncated"))
  }
  if !icc_has_range(at, 12, limit) {
    return Err(IccTruncated("Curve header is truncated"))
  }
  match type_signature {
    ICC_SIG_CURV => {
      let count = match icc_u32(data, at + 8, limit) {
        Some(value) => value
        None => return Err(IccTruncated("Sampled curve count is truncated"))
      }
      if count == 0 {
        return Ok((IccIdentity, at + 12))
      }
      if count == 1 {
        let gamma = match icc_u16(data, at + 12, limit) {
          Some(value) => value
          None => return Err(IccTruncated("Curve gamma is truncated"))
        }
        if gamma == 0 {
          return Err(IccInvalid("Curve gamma must be positive"))
        }
        return Ok((IccGamma(gamma.to_double() / 256.0), at + 16))
      }
      if count > 65536 {
        return Err(IccLimit("Curve exceeds 65536 sampled entries"))
      }
      if count > (limit - (at + 12)) / 2 {
        return Err(IccInvalid("Sampled curve has an invalid length"))
      }
      let end = at + 12 + count * 2
      let samples = Array::makei(count, i => {
        match icc_u16(data, at + 12 + i * 2, limit) {
          Some(value) => value.to_double() / 65535.0
          None => 0.0
        }
      })
      Ok((IccSampled(samples), (end + 3) / 4 * 4))
    }
    ICC_SIG_PARA => {
      let function_type = match icc_u16(data, at + 8, limit) {
        Some(value) => value
        None =>
          return Err(IccTruncated("Parametric curve function is truncated"))
      }
      let count = match icc_curve_count(function_type) {
        Some(value) => value
        None =>
          return Err(IccUnsupported("Parametric curve function is unsupported"))
      }
      if count > (limit - (at + 12)) / 4 {
        return Err(IccTruncated("Parametric curve parameters are truncated"))
      }
      let parameters = Array::makei(count, i => {
        icc_s15f16(data, at + 12 + i * 4, limit).unwrap_or(0.0)
      })
      if parameters[0] <= 0.0 {
        return Err(IccInvalid("Parametric curve gamma must be positive"))
      }
      if (function_type == 1 || function_type == 2) && parameters[1] == 0.0 {
        return Err(IccInvalid("Parametric curve has a zero slope"))
      }
      Ok(
        (
          IccParametric(function_type, parameters),
          (at + 12 + count * 4 + 3) / 4 * 4,
        ),
      )
    }
    _ => Err(IccUnsupported("Curve tag type is unsupported"))
  }
}

///|
fn icc_parse_curve_tag(
  data : Array[Byte],
  tag : IccTag,
  limit : Int,
) -> Result[IccCurve, IccIssue] {
  let end = tag.offset + tag.size
  if !icc_has_range(tag.offset, tag.size, limit) {
    return Err(IccInvalid("Curve tag lies outside the profile"))
  }
  match icc_parse_curve_at(data, tag.offset, end) {
    Ok((curve, _)) => Ok(curve)
    Err(issue) => Err(issue)
  }
}

///|
fn icc_parse_xyz_tag(
  data : Array[Byte],
  tag : IccTag,
  limit : Int,
) -> Result[(Double, Double, Double), IccIssue] {
  if tag.size < 20 || !icc_has_range(tag.offset, tag.size, limit) {
    return Err(IccInvalid("XYZ tag has an invalid size"))
  }
  let type_signature = match icc_u32(data, tag.offset, limit) {
    Some(value) => value
    None => return Err(IccTruncated("XYZ tag type is truncated"))
  }
  if type_signature != ICC_SIG_XYZ_TYPE {
    return Err(IccInvalid("XYZ tag has the wrong type"))
  }
  match
    (
      icc_s15f16(data, tag.offset + 8, limit),
      icc_s15f16(data, tag.offset + 12, limit),
      icc_s15f16(data, tag.offset + 16, limit),
    ) {
    (Some(x), Some(y), Some(z)) => Ok((x, y, z))
    _ => Err(IccTruncated("XYZ tag payload is truncated"))
  }
}

///|
fn icc_matrix_from_tags(
  data : Array[Byte],
  tags : Array[IccTag],
  limit : Int,
) -> Result[IccPipeline, IccIssue] {
  let rxyz = match icc_tag(tags, ICC_SIG_RXYZ) {
    Some(tag) =>
      match icc_parse_xyz_tag(data, tag, limit) {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
    None => return Err(IccInvalid("RGB profile is missing rXYZ"))
  }
  let gxyz = match icc_tag(tags, ICC_SIG_GXYZ) {
    Some(tag) =>
      match icc_parse_xyz_tag(data, tag, limit) {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
    None => return Err(IccInvalid("RGB profile is missing gXYZ"))
  }
  let bxyz = match icc_tag(tags, ICC_SIG_BXYZ) {
    Some(tag) =>
      match icc_parse_xyz_tag(data, tag, limit) {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
    None => return Err(IccInvalid("RGB profile is missing bXYZ"))
  }
  let rtrc = match icc_tag(tags, ICC_SIG_RTRC) {
    Some(tag) =>
      match icc_parse_curve_tag(data, tag, limit) {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
    None => return Err(IccInvalid("RGB profile is missing rTRC"))
  }
  let gtrc = match icc_tag(tags, ICC_SIG_GTRC) {
    Some(tag) =>
      match icc_parse_curve_tag(data, tag, limit) {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
    None => return Err(IccInvalid("RGB profile is missing gTRC"))
  }
  let btrc = match icc_tag(tags, ICC_SIG_BTRC) {
    Some(tag) =>
      match icc_parse_curve_tag(data, tag, limit) {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
    None => return Err(IccInvalid("RGB profile is missing bTRC"))
  }
  Ok(
    IccMatrixRgb(
      [rxyz.0, gxyz.0, bxyz.0, rxyz.1, gxyz.1, bxyz.1, rxyz.2, gxyz.2, bxyz.2],
      rtrc,
      gtrc,
      btrc,
    ),
  )
}

///|
fn icc_white_valid(white : (Double, Double, Double)) -> Bool {
  if white.0.is_nan() ||
    white.1.is_nan() ||
    white.2.is_nan() ||
    white.0.is_inf() ||
    white.1.is_inf() ||
    white.2.is_inf() ||
    white.0 <= 0.0 ||
    white.1 <= 0.0 ||
    white.2 <= 0.0 {
    return false
  }
  let cone_l = 0.8951 * white.0 + 0.2664 * white.1 - 0.1614 * white.2
  let cone_m = -0.7502 * white.0 + 1.7135 * white.1 + 0.0367 * white.2
  let cone_s = 0.0389 * white.0 - 0.0685 * white.1 + 1.0296 * white.2
  !cone_l.is_nan() &&
  !cone_m.is_nan() &&
  !cone_s.is_nan() &&
  !cone_l.is_inf() &&
  !cone_m.is_inf() &&
  !cone_s.is_inf() &&
  cone_l != 0.0 &&
  cone_m != 0.0 &&
  cone_s != 0.0
}

///|
fn icc_parse_gray_pipeline(
  data : Array[Byte],
  tags : Array[IccTag],
  limit : Int,
) -> Result[IccPipeline, IccIssue] {
  let white = match icc_tag(tags, ICC_SIG_WTPT) {
    Some(tag) =>
      match icc_parse_xyz_tag(data, tag, limit) {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
    None => return Err(IccInvalid("Gray profile is missing wtpt"))
  }
  let trc = match icc_tag(tags, ICC_SIG_KTRC) {
    Some(tag) =>
      match icc_parse_curve_tag(data, tag, limit) {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
    None => return Err(IccInvalid("Gray profile is missing kTRC"))
  }
  if !icc_white_valid(white) {
    return Err(
      IccInvalid("Gray profile media white is not a finite Bradford white"),
    )
  }
  Ok(IccMatrixGray([white.0, white.1, white.2], trc))
}

///|
fn icc_tag_data_type(
  data : Array[Byte],
  tag : IccTag,
  limit : Int,
) -> Result[Int, IccIssue] {
  if !icc_has_range(tag.offset, tag.size, limit) || tag.size < 8 {
    return Err(IccInvalid("Tag lies outside the profile"))
  }
  match icc_u32(data, tag.offset, limit) {
    Some(value) => Ok(value)
    None => Err(IccTruncated("Tag type is truncated"))
  }
}

///|
fn icc_lut_count(grid : Int, channels : Int) -> Int? {
  if grid < 2 || grid > 65 || channels < 1 || channels > 4 {
    return None
  }
  let mut count = 1
  for _ in 0..<channels {
    if count > ICC_MAX_CLUT_CELLS / grid {
      return None
    }
    count *= grid
  }
  Some(count)
}

///|
fn icc_matrix_is_identity(matrix : Array[Double]) -> Bool {
  for i in 0..<matrix.length() {
    let expected = if i == 0 || i == 4 || i == 8 { 1.0 } else { 0.0 }
    let difference = matrix[i] - expected
    if difference > 0.000001 || difference < -0.000001 {
      return false
    }
  }
  true
}

///|
fn icc_parse_sampled_table(
  data : Array[Byte],
  at : Int,
  count : Int,
  sixteen_bit : Bool,
  limit : Int,
) -> Result[(IccCurve, Int), IccIssue] {
  let width = if sixteen_bit { 2 } else { 1 }
  if count <= 0 || count > 1048576 || count > (limit - at) / width {
    return Err(IccInvalid("LUT table has an invalid size"))
  }
  let samples = Array::makei(count, i => {
    if sixteen_bit {
      icc_u16(data, at + i * 2, limit).unwrap_or(0).to_double() / 65535.0
    } else {
      icc_u8(data, at + i, limit).unwrap_or(0).to_double() / 255.0
    }
  })
  Ok((IccSampled(samples), at + count * width))
}

///|
fn icc_parse_mft(
  data : Array[Byte],
  tag : IccTag,
  limit : Int,
  sixteen_bit : Bool,
  pcs_lab : Bool,
  pcs_xyz : Bool,
) -> Result[IccLut, IccIssue] {
  let header_size = if sixteen_bit { 52 } else { 48 }
  if tag.size < header_size || !icc_has_range(tag.offset, tag.size, limit) {
    return Err(IccInvalid("mft LUT header has an invalid size"))
  }
  let p = tag.offset
  let input_channels = icc_u8(data, p + 8, limit).unwrap_or(0)
  let output_channels = icc_u8(data, p + 9, limit).unwrap_or(0)
  let grid = icc_u8(data, p + 10, limit).unwrap_or(0)
  if (input_channels != 1 && input_channels != 3) || output_channels != 3 {
    return Err(
      IccUnsupported("LUT must have one or three inputs and three outputs"),
    )
  }
  let cells = match icc_lut_count(grid, input_channels) {
    Some(value) => value
    None => return Err(IccInvalid("LUT grid is outside supported bounds"))
  }
  let input_entries = if sixteen_bit {
    icc_u16(data, p + 48, limit).unwrap_or(0)
  } else {
    256
  }
  let output_entries = if sixteen_bit {
    icc_u16(data, p + 50, limit).unwrap_or(0)
  } else {
    256
  }
  if input_entries < 2 ||
    output_entries < 2 ||
    input_entries > 65536 ||
    output_entries > 65536 {
    return Err(IccInvalid("LUT table entry count is invalid"))
  }
  let tag_end = p + tag.size
  let mut pos = p + header_size
  let input_curves : Array[IccCurve] = []
  for _ in 0..<input_channels {
    let parsed = match
      icc_parse_sampled_table(data, pos, input_entries, sixteen_bit, tag_end) {
      Ok(value) => value
      Err(issue) => return Err(issue)
    }
    input_curves.push(parsed.0)
    pos = parsed.1
  }
  let clut_values = cells * output_channels
  let clut_width = if sixteen_bit { 2 } else { 1 }
  if clut_values > (tag_end - pos) / clut_width {
    return Err(IccTruncated("LUT CLUT is truncated"))
  }
  let clut = Array::makei(clut_values, i => {
    if sixteen_bit {
      icc_u16(data, pos + i * 2, tag_end).unwrap_or(0).to_double() / 65535.0
    } else {
      icc_u8(data, pos + i, tag_end).unwrap_or(0).to_double() / 255.0
    }
  })
  pos += clut_values * clut_width
  let output_curves : Array[IccCurve] = []
  for _ in 0..<output_channels {
    let parsed = match
      icc_parse_sampled_table(data, pos, output_entries, sixteen_bit, tag_end) {
      Ok(value) => value
      Err(issue) => return Err(issue)
    }
    output_curves.push(parsed.0)
    pos = parsed.1
  }
  let matrix = Array::makei(9, i => {
    icc_s15f16(data, p + 12 + i * 4, tag_end).unwrap_or(0.0)
  })
  if !icc_matrix_is_identity(matrix) {
    return Err(IccUnsupported("mft matrix is supported only when identity"))
  }
  Ok({
    input_channels,
    output_channels,
    grids: Array::makei(input_channels, _ => grid),
    has_clut: true,
    clut,
    input_curves,
    middle_curves: Array::makei(output_channels, _ => IccIdentity),
    output_curves,
    matrix,
    translation: [0.0, 0.0, 0.0],
    pcs_lab,
    pcs_xyz_scale: if pcs_xyz {
      if sixteen_bit {
        65535.0 / 32768.0
      } else {
        255.0 / 128.0
      }
    } else {
      1.0
    },
    // lut16Type's PCS Lab signature is the legacy FF00-domain encoding in
    // both v2 and v4 ICC. The profile version does not switch this tag form.
    lab_legacy: pcs_lab && sixteen_bit,
  })
}

///|
fn icc_parse_curve_sequence(
  data : Array[Byte],
  at : Int,
  count : Int,
  limit : Int,
) -> Result[(Array[IccCurve], Int), IccIssue] {
  let curves : Array[IccCurve] = []
  let mut pos = at
  for _ in 0..<count {
    let parsed = match icc_parse_curve_at(data, pos, limit) {
      Ok(value) => value
      Err(issue) => return Err(issue)
    }
    curves.push(parsed.0)
    pos = parsed.1
  }
  Ok((curves, pos))
}

///|
fn icc_parse_mab(
  data : Array[Byte],
  tag : IccTag,
  limit : Int,
  pcs_lab : Bool,
  pcs_xyz : Bool,
  lab_legacy : Bool,
) -> Result[IccLut, IccIssue] {
  if tag.size < 32 || !icc_has_range(tag.offset, tag.size, limit) {
    return Err(IccInvalid("mAB LUT header has an invalid size"))
  }
  let p = tag.offset
  let input_channels = icc_u8(data, p + 8, limit).unwrap_or(0)
  let output_channels = icc_u8(data, p + 9, limit).unwrap_or(0)
  if (input_channels != 1 && input_channels != 3) || output_channels != 3 {
    return Err(
      IccUnsupported("mAB LUT must have one or three inputs and three outputs"),
    )
  }
  let b_offset = match icc_u32(data, p + 12, limit) {
    Some(value) => value
    None => return Err(IccInvalid("mAB B-curve offset is invalid"))
  }
  let matrix_offset = match icc_u32(data, p + 16, limit) {
    Some(value) => value
    None => return Err(IccInvalid("mAB matrix offset is invalid"))
  }
  let m_offset = match icc_u32(data, p + 20, limit) {
    Some(value) => value
    None => return Err(IccInvalid("mAB M-curve offset is invalid"))
  }
  let clut_offset = match icc_u32(data, p + 24, limit) {
    Some(value) => value
    None => return Err(IccInvalid("mAB CLUT offset is invalid"))
  }
  let a_offset = match icc_u32(data, p + 28, limit) {
    Some(value) => value
    None => return Err(IccInvalid("mAB A-curve offset is invalid"))
  }
  if b_offset == 0 ||
    (a_offset == 0) != (clut_offset == 0) ||
    (m_offset == 0) != (matrix_offset == 0) {
    return Err(
      IccInvalid(
        "mAB requires B curves, paired A/CLUT and paired M/matrix stages",
      ),
    )
  }
  let tag_end = p + tag.size
  if clut_offset == 0 && input_channels != 3 {
    return Err(IccUnsupported("mAB gray pipelines require a CLUT"))
  }
  let a_target = if a_offset == 0 {
    None
  } else {
    Some(
      match icc_mab_target(p, a_offset, tag_end) {
        Ok(value) => value
        Err(issue) => return Err(issue)
      },
    )
  }
  let b_target = if b_offset == 0 {
    None
  } else {
    Some(
      match icc_mab_target(p, b_offset, tag_end) {
        Ok(value) => value
        Err(issue) => return Err(issue)
      },
    )
  }
  let m_target = if m_offset == 0 {
    None
  } else {
    Some(
      match icc_mab_target(p, m_offset, tag_end) {
        Ok(value) => value
        Err(issue) => return Err(issue)
      },
    )
  }
  let matrix_target = if matrix_offset == 0 {
    None
  } else {
    Some(
      match icc_mab_target(p, matrix_offset, tag_end) {
        Ok(value) => value
        Err(issue) => return Err(issue)
      },
    )
  }
  let clut_target = if clut_offset == 0 {
    None
  } else {
    Some(
      match icc_mab_target(p, clut_offset, tag_end) {
        Ok(value) => value
        Err(issue) => return Err(issue)
      },
    )
  }
  let input_curves = if a_target is None {
    Array::makei(input_channels, _ => IccIdentity)
  } else {
    let target = a_target.unwrap()
    match icc_parse_curve_sequence(data, target, input_channels, tag_end) {
      Ok(value) => value.0
      Err(issue) => return Err(issue)
    }
  }
  let mut middle_curves : Array[IccCurve] = []
  let mut matrix : Array[Double] = []
  let mut translation = [0.0, 0.0, 0.0]
  if matrix_target is Some(target) {
    if !icc_has_range(target, 48, tag_end) {
      return Err(IccTruncated("mAB matrix is truncated"))
    }
    matrix = Array::makei(9, i => {
      icc_s15f16(data, target + i * 4, tag_end).unwrap_or(0.0)
    })
    translation = Array::makei(3, i => {
      icc_s15f16(data, target + 36 + i * 4, tag_end).unwrap_or(0.0)
    })
  }
  if m_target is Some(target) {
    middle_curves = match
      icc_parse_curve_sequence(data, target, output_channels, tag_end) {
      Ok(value) => value.0
      Err(issue) => return Err(issue)
    }
  } else {
    middle_curves = Array::makei(output_channels, _ => IccIdentity)
  }
  let (grids, clut) = if clut_target is None {
    (
      Array::makei(input_channels, _ => 2),
      Array::makei(2 * output_channels, _ => 0.0),
    )
  } else {
    let c = clut_target.unwrap()
    if !icc_has_range(c, 20, tag_end) {
      return Err(IccTruncated("mAB CLUT header is truncated"))
    }
    let grids = Array::makei(input_channels, channel => {
      icc_u8(data, c + channel, tag_end).unwrap_or(0)
    })
    let precision = icc_u8(data, c + 16, tag_end).unwrap_or(0)
    if precision != 1 && precision != 2 {
      return Err(IccUnsupported("mAB CLUT precision is unsupported"))
    }
    let mut cells = 1
    for dimension in grids {
      if dimension < 2 ||
        dimension > 65 ||
        cells > ICC_MAX_CLUT_CELLS / dimension {
        return Err(IccInvalid("mAB CLUT grid is outside supported bounds"))
      }
      cells *= dimension
    }
    if cells <= 0 {
      return Err(IccInvalid("mAB CLUT grid is outside supported bounds"))
    }
    let count = cells * output_channels
    let width = if precision == 2 { 2 } else { 1 }
    if count > (tag_end - (c + 20)) / width {
      return Err(IccTruncated("mAB CLUT values are truncated"))
    }
    let values = Array::makei(count, i => {
      if precision == 2 {
        icc_u16(data, c + 20 + i * 2, tag_end).unwrap_or(0).to_double() /
        65535.0
      } else {
        icc_u8(data, c + 20 + i, tag_end).unwrap_or(0).to_double() / 255.0
      }
    })
    (grids, values)
  }
  let output_curves = if b_target is None {
    Array::makei(output_channels, _ => IccIdentity)
  } else {
    match
      icc_parse_curve_sequence(
        data,
        b_target.unwrap(),
        output_channels,
        tag_end,
      ) {
      Ok(value) => value.0
      Err(issue) => return Err(issue)
    }
  }
  Ok({
    input_channels,
    output_channels,
    grids,
    has_clut: clut_target is Some(_),
    clut,
    input_curves,
    middle_curves,
    output_curves,
    matrix,
    translation,
    pcs_lab,
    pcs_xyz_scale: if pcs_xyz {
      // mAB B curves are always 16-bit curves; CLUT precision does not
      // change the PCS encoding of their output.
      65535.0 / 32768.0
    } else {
      1.0
    },
    lab_legacy,
  })
}

///|
fn icc_parse_lut_tag(
  data : Array[Byte],
  tag : IccTag,
  limit : Int,
  pcs_lab : Bool,
  pcs_xyz : Bool,
  lab_legacy : Bool,
) -> Result[IccLut, IccIssue] {
  let type_signature = match icc_tag_data_type(data, tag, limit) {
    Ok(value) => value
    Err(issue) => return Err(issue)
  }
  match type_signature {
    ICC_SIG_MFT1 =>
      if pcs_xyz {
        Err(IccUnsupported("mft1 PCS XYZ scaling is implementation-specific"))
      } else {
        icc_parse_mft(data, tag, limit, false, pcs_lab, pcs_xyz)
      }
    ICC_SIG_MFT2 => icc_parse_mft(data, tag, limit, true, pcs_lab, pcs_xyz)
    ICC_SIG_MAB =>
      if lab_legacy {
        Err(IccUnsupported("mAB LUTs are supported only for ICC v4 profiles"))
      } else {
        icc_parse_mab(data, tag, limit, pcs_lab, pcs_xyz, lab_legacy)
      }
    _ => Err(IccUnsupported("A2B0 LUT type is unsupported"))
  }
}

///|
fn icc_parse_intent_pipeline(
  data : Array[Byte],
  tag : IccTag,
  limit : Int,
  pcs_lab : Bool,
  pcs_xyz : Bool,
  lab_legacy : Bool,
) -> Result[IccPipeline, IccIssue] {
  match icc_parse_lut_tag(data, tag, limit, pcs_lab, pcs_xyz, lab_legacy) {
    Ok(lut) => Ok(IccLutPipeline(lut))
    Err(issue) => Err(issue)
  }
}

///|
fn icc_apply_bradford(
  x : Double,
  y : Double,
  z : Double,
  source_white : (Double, Double, Double),
) -> (Double, Double, Double) {
  let source_l = 0.8951 * source_white.0 +
    0.2664 * source_white.1 -
    0.1614 * source_white.2
  let source_m = -0.7502 * source_white.0 +
    1.7135 * source_white.1 +
    0.0367 * source_white.2
  let source_s = 0.0389 * source_white.0 -
    0.0685 * source_white.1 +
    1.0296 * source_white.2
  let target_x = 0.3127 / 0.3290
  let target_z = (1.0 - 0.3127 - 0.3290) / 0.3290
  let target_l = 0.8951 * target_x + 0.2664 - 0.1614 * target_z
  let target_m = -0.7502 * target_x + 1.7135 + 0.0367 * target_z
  let target_s = 0.0389 * target_x - 0.0685 + 1.0296 * target_z
  let cone_x = 0.8951 * x + 0.2664 * y - 0.1614 * z
  let cone_y = -0.7502 * x + 1.7135 * y + 0.0367 * z
  let cone_z = 0.0389 * x - 0.0685 * y + 1.0296 * z
  let adapted_l = cone_x * target_l / source_l
  let adapted_m = cone_y * target_m / source_m
  let adapted_s = cone_z * target_s / source_s
  (
    0.9869929 * adapted_l - 0.1470543 * adapted_m + 0.1599627 * adapted_s,
    0.4323053 * adapted_l + 0.5183603 * adapted_m + 0.0492912 * adapted_s,
    -0.0085287 * adapted_l + 0.0400428 * adapted_m + 0.9684867 * adapted_s,
  )
}

///|
fn icc_xyz_to_srgb(
  x : Double,
  y : Double,
  z : Double,
  source_white : (Double, Double, Double),
) -> (Double, Double, Double) {
  let adapted = icc_apply_bradford(x, y, z, source_white)
  let r = 3.2409699419045226 * adapted.0 -
    1.537383177570094 * adapted.1 -
    0.4986107602930034 * adapted.2
  let g = -0.9692436362808796 * adapted.0 +
    1.8759675015077202 * adapted.1 +
    0.04155505740717559 * adapted.2
  let b = 0.05563007969699366 * adapted.0 -
    0.20397695888897652 * adapted.1 +
    1.0569715142428786 * adapted.2
  (icc_srgb_encode(r), icc_srgb_encode(g), icc_srgb_encode(b))
}

///|
fn icc_srgb_encode(value : Double) -> Double {
  let x = if value <= 0.0 { 0.0 } else { value }
  if x <= 0.0031308 {
    12.92 * x
  } else {
    1.055 * @math.pow(x, 1.0 / 2.4) - 0.055
  }
}

///|
fn icc_lab_to_xyz(
  l_encoded : Double,
  a_encoded : Double,
  b_encoded : Double,
  lab_legacy : Bool,
) -> (Double, Double, Double) {
  let l_scale = if lab_legacy { 65535.0 / 65280.0 } else { 1.0 }
  // Legacy PCS Lab uses FF00 as the nominal 16-bit maximum for all three
  // components. Converting to the current normalized PCS domain first keeps
  // 8000 exactly neutral for a*/b* and FF00 exactly 127 for those channels.
  let ab_scale = if lab_legacy { 65535.0 / 65280.0 * 255.0 } else { 255.0 }
  let l = l_encoded * l_scale * 100.0
  let a = a_encoded * ab_scale - 128.0
  let b = b_encoded * ab_scale - 128.0
  let fy = (l + 16.0) / 116.0
  let fx = fy + a / 500.0
  let fz = fy - b / 200.0
  let delta = 6.0 / 29.0
  let inverse = fn(value : Double) -> Double {
    if value > delta {
      value * value * value
    } else {
      3.0 * delta * delta * (value - 4.0 / 29.0)
    }
  }
  (0.9642 * inverse(fx), inverse(fy), 0.8249 * inverse(fz))
}

///|
fn icc_lut_index(lut : IccLut, coordinates : Array[Int]) -> Int {
  let mut index = 0
  for dimension in 0..<lut.input_channels {
    index = index * lut.grids[dimension] + coordinates[dimension]
  }
  index
}

///|
fn icc_lut_clut(lut : IccLut, values : Array[Double]) -> Array[Double] {
  let lows = Array::makei(lut.input_channels, i => {
    let position = icc_clamp(values[i]) * (lut.grids[i] - 1).to_double()
    position.to_int()
  })
  let fractions = Array::makei(lut.input_channels, i => {
    let position = icc_clamp(values[i]) * (lut.grids[i] - 1).to_double()
    let low = position.to_int()
    if low >= lut.grids[i] - 1 {
      0.0
    } else {
      position - low.to_double()
    }
  })
  let output = Array::make(lut.output_channels, 0.0)
  if lut.input_channels == 3 {
    // Tetrahedral interpolation uses the simplex containing the three
    // fractional coordinates. ICC's first input dimension varies slowest.
    let order = [0, 1, 2]
    for i in 0..<2 {
      for j in (i + 1)..<3 {
        if fractions[order[j]] > fractions[order[i]] {
          let saved = order[i]
          order[i] = order[j]
          order[j] = saved
        }
      }
    }
    let coordinates = lows.copy()
    for vertex in 0..<4 {
      let weight = if vertex == 0 {
        1.0 - fractions[order[0]]
      } else if vertex == 3 {
        fractions[order[2]]
      } else {
        fractions[order[vertex - 1]] - fractions[order[vertex]]
      }
      let base = icc_lut_index(lut, coordinates) * lut.output_channels
      for channel in 0..<lut.output_channels {
        output[channel] += weight * lut.clut[base + channel]
      }
      if vertex < 3 && coordinates[order[vertex]] < lut.grids[order[vertex]] - 1 {
        coordinates[order[vertex]] += 1
      }
    }
    return output
  }
  let corners = 1 << lut.input_channels
  for corner in 0..<corners {
    let mut weight = 1.0
    let mut index = 0
    for channel in 0..<lut.input_channels {
      let high = ((corner >> channel) & 1) != 0
      let coordinate = if high { lows[channel] + 1 } else { lows[channel] }
      let bounded = if coordinate >= lut.grids[channel] {
        lut.grids[channel] - 1
      } else {
        coordinate
      }
      weight *= if high { fractions[channel] } else { 1.0 - fractions[channel] }
      index = index * lut.grids[channel] + bounded
    }
    let base = index * lut.output_channels
    for channel in 0..<lut.output_channels {
      output[channel] += weight * lut.clut[base + channel]
    }
  }
  output
}

///|
fn icc_lut_eval(lut : IccLut, encoded : Array[Double]) -> Array[Double] {
  let a_values = Array::makei(lut.input_channels, i => {
    icc_curve_eval(lut.input_curves[i], encoded[i])
  })
  let mut values = if lut.has_clut {
    icc_lut_clut(lut, a_values)
  } else {
    a_values
  }
  values = Array::makei(lut.output_channels, i => {
    icc_curve_eval(lut.middle_curves[i], values[i])
  })
  if lut.matrix.length() == 9 {
    let r = values[0]
    let g = values[1]
    let b = values[2]
    values = [
      lut.matrix[0] * r +
      lut.matrix[1] * g +
      lut.matrix[2] * b +
      lut.translation[0],
      lut.matrix[3] * r +
      lut.matrix[4] * g +
      lut.matrix[5] * b +
      lut.translation[1],
      lut.matrix[6] * r +
      lut.matrix[7] * g +
      lut.matrix[8] * b +
      lut.translation[2],
    ]
  }
  values = Array::makei(lut.output_channels, i => {
    icc_curve_eval(lut.output_curves[i], values[i])
  })
  values
}

///|
fn icc_profile_xyz(
  pipeline : IccPipeline,
  encoded : Array[Double],
) -> (Double, Double, Double) {
  match pipeline {
    IccMatrixRgb(matrix, rtrc, gtrc, btrc) => {
      let r = icc_curve_eval(rtrc, encoded[0])
      let g = icc_curve_eval(gtrc, encoded[1])
      let b = icc_curve_eval(btrc, encoded[2])
      (
        matrix[0] * r + matrix[1] * g + matrix[2] * b,
        matrix[3] * r + matrix[4] * g + matrix[5] * b,
        matrix[6] * r + matrix[7] * g + matrix[8] * b,
      )
    }
    IccMatrixGray(white, trc) => {
      let value = icc_curve_eval(trc, encoded[0])
      (white[0] * value, white[1] * value, white[2] * value)
    }
    IccLutPipeline(lut) => {
      let values = icc_lut_eval(lut, encoded)
      if lut.pcs_lab {
        icc_lab_to_xyz(values[0], values[1], values[2], lut.lab_legacy)
      } else {
        (
          values[0] * lut.pcs_xyz_scale,
          values[1] * lut.pcs_xyz_scale,
          values[2] * lut.pcs_xyz_scale,
        )
      }
    }
  }
}

///|
fn icc_pipeline_white(pipeline : IccPipeline) -> (Double, Double, Double) {
  match pipeline {
    IccMatrixGray(white, _) => (white[0], white[1], white[2])
    _ => (0.9642, 1.0, 0.8249)
  }
}

///|
fn icc_bpc_xyz(
  xyz : (Double, Double, Double),
  black : (Double, Double, Double),
) -> (Double, Double, Double) {
  let map = fn(
    value : Double,
    source_black : Double,
    white : Double,
  ) -> Double {
    (value - source_black) * white / (white - source_black)
  }
  (
    map(xyz.0, black.0, 0.9642),
    map(xyz.1, black.1, 1.0),
    map(xyz.2, black.2, 0.8249),
  )
}

///|
fn icc_bpc_valid(black : (Double, Double, Double)) -> Bool {
  let valid = fn(value : Double, white : Double) -> Bool {
    let span = white - value
    !value.is_nan() &&
    !value.is_inf() &&
    !span.is_nan() &&
    !span.is_inf() &&
    span.abs() > 1.0e-12
  }
  valid(black.0, 0.9642) && valid(black.1, 1.0) && valid(black.2, 0.8249)
}

///|
fn icc_clip_black_lightness(
  xyz : (Double, Double, Double),
) -> (Double, Double, Double) {
  let fx = fn(value : Double) -> Double {
    if value > 216.0 / 24389.0 {
      @math.pow(value, 1.0 / 3.0)
    } else {
      841.0 / 108.0 * value + 16.0 / 116.0
    }
  }
  let fx_value = fx(xyz.0 / 0.9642)
  let fy_value = fx(xyz.1)
  let fz_value = fx(xyz.2 / 0.8249)
  let l = 116.0 * fy_value - 16.0
  let clipped_l = if l > 95.0 || l < 0.0 {
    0.0
  } else if l > 50.0 {
    50.0
  } else {
    l
  }
  let fy_clipped = (clipped_l + 16.0) / 116.0
  let delta = 6.0 / 29.0
  let inverse = fn(value : Double) -> Double {
    if value > delta {
      value * value * value
    } else {
      3.0 * delta * delta * (value - 4.0 / 29.0)
    }
  }
  (
    0.9642 * inverse(fy_clipped + fx_value - fy_value),
    inverse(fy_clipped),
    0.8249 * inverse(fy_clipped + fz_value - fy_value),
  )
}

///|
fn icc_detect_black_point(
  profile : IccProfile,
  selected : IccPipeline,
  intent : IccRenderingIntent,
) -> (Double, Double, Double) {
  let perceptual = match intent {
    Perceptual | Saturation => true
    _ => false
  }
  if !profile.lab_legacy && perceptual && !profile.matrix_shaper {
    return (0.00336, 0.0034731, 0.00287)
  }
  // LittleCMS's black detector first checks the requested input intent,
  // independently of the input-LUT reader's A2B0 fallback.
  let supported = profile.matrix_shaper ||
    (match intent {
      Perceptual => profile.perceptual_tag is Some(_)
      RelativeColorimetric => icc_tag(profile.tags, ICC_SIG_A2B1) is Some(_)
      Saturation => profile.saturation_tag is Some(_)
      AbsoluteColorimetric => false
    })
  if !supported {
    return (0.0, 0.0, 0.0)
  }
  let pipeline = if !profile.lab_legacy && perceptual && profile.matrix_shaper {
    profile.pipeline
  } else {
    selected
  }
  let xyz = match pipeline {
    IccMatrixGray(_, trc) => {
      let value = icc_curve_eval(trc, 0.0)
      (0.9642 * value, value, 0.8249 * value)
    }
    _ => {
      let encoded = if profile.color_space == ICC_SIG_GRAY {
        [0.0]
      } else {
        [0.0, 0.0, 0.0]
      }
      icc_profile_xyz(pipeline, encoded)
    }
  }
  icc_clip_black_lightness(xyz)
}

///|
fn icc_profile_pixel(
  profile : IccProfile,
  pipeline : IccPipeline,
  black_point : (Double, Double, Double)?,
  absolute_white : (Double, Double, Double)?,
  r : Double,
  g : Double,
  b : Double,
) -> (Double, Double, Double) {
  let encoded = if profile.color_space == ICC_SIG_GRAY {
    [r]
  } else {
    [r, g, b]
  }
  let policy_pcs = black_point is Some(_) || absolute_white is Some(_)
  let xyz = if policy_pcs {
    match pipeline {
      IccMatrixGray(_, trc) => {
        let value = icc_curve_eval(trc, encoded[0])
        (0.9642 * value, value, 0.8249 * value)
      }
      _ => icc_profile_xyz(pipeline, encoded)
    }
  } else {
    icc_profile_xyz(pipeline, encoded)
  }
  let absolute_xyz = match absolute_white {
    Some(white) =>
      (xyz.0 * white.0 / 0.9642, xyz.1 * white.1, xyz.2 * white.2 / 0.8249)
    None => xyz
  }
  let mapped_xyz = match black_point {
    Some(black) => icc_bpc_xyz(absolute_xyz, black)
    None => absolute_xyz
  }
  let white = if policy_pcs {
    (0.9642, 1.0, 0.8249)
  } else {
    icc_pipeline_white(pipeline)
  }
  icc_xyz_to_srgb(mapped_xyz.0, mapped_xyz.1, mapped_xyz.2, white)
}

///|
fn icc_image_valid(image : Image) -> Bool {
  if image.width < 0 ||
    image.height < 0 ||
    image.width == 0 ||
    image.height == 0 {
    image.width >= 0 && image.height >= 0 && image.data.length() == 0
  } else if image.width > MAX_IMAGE_PIXELS / image.height {
    false
  } else {
    image.data.length() == image.width * image.height * 4
  }
}

///|
fn icc_image16_valid(image : Image16) -> Bool {
  if image.width < 0 ||
    image.height < 0 ||
    image.width == 0 ||
    image.height == 0 {
    image.width >= 0 && image.height >= 0 && image.data.length() == 0
  } else if image.width > MAX_IMAGE_PIXELS / image.height {
    false
  } else {
    image.data.length() == image.width * image.height * 4
  }
}

///|
fn icc_quantize8(value : Double) -> Byte {
  let clipped = icc_clamp(value)
  (clipped * 255.0 + 0.5).to_int().to_byte()
}

///|
fn icc_quantize16(value : Double) -> UInt16 {
  let clipped = icc_clamp(value)
  (clipped * 65535.0 + 0.5).to_int().to_uint16()
}

///|
/// Parse and validate a pure RGB or Gray ICC v2/v4 input/display profile.
pub fn IccProfile::parse(
  bytes : Array[Byte],
) -> Result[IccProfile, DecodeError] {
  if bytes.length() > 64 * 1024 * 1024 {
    return Err(decode_error(LimitExceeded, "icc", "ICC input exceeds 64 MiB"))
  }
  if bytes.length() < 132 {
    return Err(icc_error(IccTruncated("ICC header or tag table is truncated")))
  }
  let declared_size = match icc_u32(bytes, 0, bytes.length()) {
    Some(value) => value
    None => return Err(icc_error(IccTruncated("ICC profile size is truncated")))
  }
  if declared_size < 132 {
    return Err(icc_error(IccInvalid("ICC profile size is too small")))
  }
  if declared_size > bytes.length() {
    return Err(
      icc_error(IccTruncated("ICC profile is shorter than its declared size")),
    )
  }
  let version = bytes[8].to_int()
  if version != 2 && version != 4 {
    return Err(
      icc_error(IccUnsupported("Only ICC v2 and v4 profiles are supported")),
    )
  }
  let device_class = match icc_u32(bytes, 12, declared_size) {
    Some(value) => value
    None => return Err(icc_error(IccTruncated("ICC device class is truncated")))
  }
  if device_class != ICC_SIG_SCNR && device_class != ICC_SIG_MNTR {
    let message = if device_class == ICC_SIG_PRTR ||
      device_class == ICC_SIG_LINK {
      "Printer and device-link ICC profiles are unsupported"
    } else if device_class == ICC_SIG_SPAC || device_class == ICC_SIG_NMCL {
      "N-component and named-color ICC profiles are unsupported"
    } else {
      "ICC profile class is unsupported"
    }
    return Err(icc_error(IccUnsupported(message)))
  }
  if icc_u32(bytes, 36, declared_size).unwrap_or(0) != ICC_SIG_ACSP {
    return Err(icc_error(IccInvalid("ICC profile signature is not acsp")))
  }
  let color_space = icc_u32(bytes, 16, declared_size).unwrap_or(0)
  if color_space != ICC_SIG_RGB && color_space != ICC_SIG_GRAY {
    return Err(icc_error(IccUnsupported("ICC color space is not RGB or Gray")))
  }
  let pcs = icc_u32(bytes, 20, declared_size).unwrap_or(0)
  if pcs != ICC_SIG_XYZ && pcs != ICC_SIG_LAB {
    return Err(icc_error(IccUnsupported("ICC PCS is not XYZ or Lab")))
  }
  let tag_count = match icc_u32(bytes, 128, declared_size) {
    Some(value) => value
    None => return Err(icc_error(IccTruncated("ICC tag count is truncated")))
  }
  if tag_count > 4096 {
    return Err(decode_error(LimitExceeded, "icc", "Profile exceeds 4096 tags"))
  }
  if tag_count > (declared_size - 132) / 12 {
    return Err(icc_error(IccTruncated("ICC tag table is truncated")))
  }
  let tag_table_end = 132 + tag_count * 12
  let tags : Array[IccTag] = []
  for i in 0..<tag_count {
    let at = 132 + i * 12
    let signature = icc_u32(bytes, at, declared_size).unwrap_or(0)
    let offset = icc_u32(bytes, at + 4, declared_size).unwrap_or(-1)
    let size = icc_u32(bytes, at + 8, declared_size).unwrap_or(-1)
    if offset < tag_table_end ||
      size < 8 ||
      !icc_has_range(offset, size, declared_size) {
      return Err(icc_error(IccInvalid("ICC tag points outside the profile")))
    }
    if offset % 4 != 0 {
      return Err(
        icc_error(IccInvalid("ICC tag offset is not four-byte aligned")),
      )
    }
    if version == 2 &&
      icc_u32(bytes, offset, declared_size) == Some(ICC_SIG_PARA) {
      return Err(icc_error(IccUnsupported("Parametric curves require ICC v4")))
    }
    tags.push({ signature, offset, size, })
  }
  let lab_legacy = version == 2
  // A selected unsupported tag is an error; fallback is only for absence.
  let relative_tag = match icc_tag(tags, ICC_SIG_A2B1) {
    Some(tag) => Some(tag)
    None => icc_tag(tags, ICC_SIG_A2B0)
  }
  let pipeline = match relative_tag {
    Some(a2b) =>
      match
        icc_parse_intent_pipeline(
          bytes,
          a2b,
          declared_size,
          pcs == ICC_SIG_LAB,
          pcs == ICC_SIG_XYZ,
          lab_legacy,
        ) {
        Ok(value) => {
          let channels_match = match value {
            IccLutPipeline(lut) =>
              (color_space == ICC_SIG_RGB && lut.input_channels == 3) ||
              (color_space == ICC_SIG_GRAY && lut.input_channels == 1)
            _ => false
          }
          if !channels_match {
            return Err(
              icc_error(
                IccUnsupported(
                  "A2B0 channel count does not match the profile color space",
                ),
              ),
            )
          }
          value
        }
        Err(issue) => return Err(icc_error(issue))
      }
    None =>
      if pcs == ICC_SIG_LAB {
        return Err(icc_error(IccUnsupported("Lab PCS requires an A2B0 LUT")))
      } else if color_space == ICC_SIG_RGB {
        match icc_matrix_from_tags(bytes, tags, declared_size) {
          Ok(value) => value
          Err(issue) => return Err(icc_error(issue))
        }
      } else {
        match icc_parse_gray_pipeline(bytes, tags, declared_size) {
          Ok(value) => value
          Err(issue) => return Err(icc_error(issue))
        }
      }
  }
  let matrix_shaper = if color_space == ICC_SIG_GRAY {
    icc_tag(tags, ICC_SIG_KTRC) is Some(_)
  } else {
    icc_tag(tags, ICC_SIG_RXYZ) is Some(_) &&
    icc_tag(tags, ICC_SIG_GXYZ) is Some(_) &&
    icc_tag(tags, ICC_SIG_BXYZ) is Some(_) &&
    icc_tag(tags, ICC_SIG_RTRC) is Some(_) &&
    icc_tag(tags, ICC_SIG_GTRC) is Some(_) &&
    icc_tag(tags, ICC_SIG_BTRC) is Some(_)
  }
  let perceptual_tag = icc_tag(tags, ICC_SIG_A2B0)
  let saturation_tag = icc_tag(tags, ICC_SIG_A2B2)
  let source_bytes = bytes.copy()
  Ok({
    color_space,
    pipeline,
    source_bytes,
    declared_size,
    tags,
    perceptual_tag,
    saturation_tag,
    relative_tag,
    device_class,
    matrix_shaper,
    pcs_lab: pcs == ICC_SIG_LAB,
    pcs_xyz: pcs == ICC_SIG_XYZ,
    lab_legacy,
  })
}

///|
fn icc_absolute_white(
  profile : IccProfile,
) -> Result[(Double, Double, Double), DecodeError] {
  // ICC v2 display profiles report their adapted D50 media white.
  if profile.lab_legacy && profile.device_class == ICC_SIG_MNTR {
    return Ok((0.9642, 1.0, 0.8249))
  }
  match icc_tag(profile.tags, ICC_SIG_WTPT) {
    None => Ok((0.9642, 1.0, 0.8249))
    Some(tag) =>
      match
        icc_parse_xyz_tag(profile.source_bytes, tag, profile.declared_size) {
        Ok(white) =>
          if icc_white_valid(white) {
            Ok(white)
          } else {
            Err(
              icc_error(
                IccInvalid(
                  "Absolute intent requires a finite positive media white",
                ),
              ),
            )
          }
        Err(issue) => Err(icc_error(issue))
      }
  }
}

///|
fn icc_pipeline_for_intent(
  profile : IccProfile,
  intent : IccRenderingIntent,
) -> Result[IccPipeline, DecodeError] {
  let parse_optional = fn(tag : IccTag?) -> Result[IccPipeline?, DecodeError] {
    match tag {
      None => Ok(None)
      Some(value) => {
        if profile.relative_tag is Some(relative) &&
          value.offset == relative.offset &&
          value.size == relative.size {
          return Ok(Some(profile.pipeline))
        }
        match
          icc_parse_intent_pipeline(
            profile.source_bytes,
            value,
            profile.declared_size,
            profile.pcs_lab,
            profile.pcs_xyz,
            profile.lab_legacy,
          ) {
          Ok(pipeline) => {
            let channels_match = match pipeline {
              IccLutPipeline(lut) =>
                (profile.color_space == ICC_SIG_RGB && lut.input_channels == 3) ||
                (profile.color_space == ICC_SIG_GRAY && lut.input_channels == 1)
              _ => false
            }
            if !channels_match {
              Err(
                icc_error(
                  IccUnsupported(
                    "Intent LUT channel count does not match profile color space",
                  ),
                ),
              )
            } else {
              Ok(Some(pipeline))
            }
          }
          Err(issue) => Err(icc_error(issue))
        }
      }
    }
  }
  let matrix_fallback = fn() -> Result[IccPipeline, DecodeError] {
    match profile.pipeline {
      IccMatrixRgb(_, _, _, _) | IccMatrixGray(_, _) => Ok(profile.pipeline)
      _ => {
        if !profile.matrix_shaper || !profile.pcs_xyz {
          return Err(
            icc_error(
              IccUnsupported(
                "Requested intent has neither an A2B table nor a matrix/TRC transform",
              ),
            ),
          )
        }
        let parsed = if profile.color_space == ICC_SIG_RGB {
          icc_matrix_from_tags(
            profile.source_bytes,
            profile.tags,
            profile.declared_size,
          )
        } else {
          icc_parse_gray_pipeline(
            profile.source_bytes,
            profile.tags,
            profile.declared_size,
          )
        }
        match parsed {
          Ok(value) => Ok(value)
          Err(issue) => Err(icc_error(issue))
        }
      }
    }
  }
  match intent {
    RelativeColorimetric => Ok(profile.pipeline)
    // LittleCMS's fixed-point Device2PCS table map uses A2B0 for perceptual
    // fallback and the matrix/gray shaper when no LUT exists.
    Perceptual =>
      match parse_optional(profile.perceptual_tag) {
        Ok(Some(pipeline)) => Ok(pipeline)
        Ok(None) => matrix_fallback()
        Err(error) => Err(error)
      }
    Saturation =>
      match
        parse_optional(
          match profile.saturation_tag {
            Some(tag) => Some(tag)
            None => profile.perceptual_tag
          },
        ) {
        Ok(Some(pipeline)) => Ok(pipeline)
        Ok(None) => matrix_fallback()
        Err(error) => Err(error)
      }
    // cmsio1.c maps fixed-point absolute input transforms to A2B1. The
    // absolute media-white adaptation is applied after this shared pipeline.
    AbsoluteColorimetric => Ok(profile.pipeline)
  }
}

///|
fn icc_black_point_for_options(
  profile : IccProfile,
  pipeline : IccPipeline,
  options : IccTransformOptions,
) -> Result[(Double, Double, Double)?, DecodeError] {
  if options.intent is AbsoluteColorimetric {
    if options.black_point_compensation {
      Err(
        icc_error(
          IccUnsupported(
            "Black-point compensation is disabled for absolute colorimetric transforms",
          ),
        ),
      )
    } else {
      Ok(None)
    }
  } else {
    let forced = match options.intent {
      // The fixed sRGB destination is v4, so the connection always applies
      // perceptual/saturation black normalization, including v2 sources.
      Perceptual | Saturation => true
      _ => false
    }
    if !options.black_point_compensation && !forced {
      Ok(None)
    } else {
      let point = icc_detect_black_point(profile, pipeline, options.intent)
      if !icc_bpc_valid(point) {
        Err(
          icc_error(
            IccInvalid(
              "Black-point compensation black point has an invalid XYZ denominator",
            ),
          ),
        )
      } else {
        Ok(Some(point))
      }
    }
  }
}

///|
/// Convert straight RGBA8 to a fresh sRGB RGBA8 image, preserving alpha.
pub fn IccProfile::apply_rgba8(
  self : IccProfile,
  image : Image,
) -> Result[Image, DecodeError] {
  self.apply_rgba8_with_options(
    image,
    IccTransformOptions::relative_colorimetric(),
  )
}

///|
/// Convert straight RGBA8 using an explicitly selected ICC policy.
pub fn IccProfile::apply_rgba8_with_options(
  self : IccProfile,
  image : Image,
  options : IccTransformOptions,
) -> Result[Image, DecodeError] {
  if !icc_image_valid(image) {
    return Err(
      decode_error(
        InvalidBuffer,
        "icc/image",
        "RGBA8 image buffer does not match its dimensions",
      ),
    )
  }
  let pipeline = match icc_pipeline_for_intent(self, options.intent) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let black_point = match icc_black_point_for_options(self, pipeline, options) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let absolute_white = match options.intent {
    AbsoluteColorimetric =>
      match icc_absolute_white(self) {
        Ok(white) => Some(white)
        Err(error) => return Err(error)
      }
    _ => None
  }
  let output = FixedArray::make(image.data.length(), b'\x00')
  for i in 0..<(image.width * image.height) {
    let source = i * 4
    let converted = icc_profile_pixel(
      self,
      pipeline,
      black_point,
      absolute_white,
      image.data[source].to_int().to_double() / 255.0,
      image.data[source + 1].to_int().to_double() / 255.0,
      image.data[source + 2].to_int().to_double() / 255.0,
    )
    if converted.0.is_nan() ||
      converted.1.is_nan() ||
      converted.2.is_nan() ||
      converted.0.is_inf() ||
      converted.1.is_inf() ||
      converted.2.is_inf() {
      return Err(
        decode_error(
          InvalidData,
          "icc/transform",
          "Profile produces non-finite color",
        ),
      )
    }
    output[source] = icc_quantize8(converted.0)
    output[source + 1] = icc_quantize8(converted.1)
    output[source + 2] = icc_quantize8(converted.2)
    output[source + 3] = image.data[source + 3]
  }
  Ok({ width: image.width, height: image.height, data: output, })
}

///|
/// Convert straight RGBA16 to a fresh sRGB RGBA16 image, preserving alpha.
pub fn IccProfile::apply_rgba16(
  self : IccProfile,
  image : Image16,
) -> Result[Image16, DecodeError] {
  self.apply_rgba16_with_options(
    image,
    IccTransformOptions::relative_colorimetric(),
  )
}

///|
/// Convert straight RGBA16 using an explicitly selected ICC policy.
pub fn IccProfile::apply_rgba16_with_options(
  self : IccProfile,
  image : Image16,
  options : IccTransformOptions,
) -> Result[Image16, DecodeError] {
  if !icc_image16_valid(image) {
    return Err(
      decode_error(
        InvalidBuffer,
        "icc/image16",
        "RGBA16 image buffer does not match its dimensions",
      ),
    )
  }
  let pipeline = match icc_pipeline_for_intent(self, options.intent) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let black_point = match icc_black_point_for_options(self, pipeline, options) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let absolute_white = match options.intent {
    AbsoluteColorimetric =>
      match icc_absolute_white(self) {
        Ok(white) => Some(white)
        Err(error) => return Err(error)
      }
    _ => None
  }
  let output = FixedArray::make(image.data.length(), (0 : UInt16))
  for i in 0..<(image.width * image.height) {
    let source = i * 4
    let converted = icc_profile_pixel(
      self,
      pipeline,
      black_point,
      absolute_white,
      image.data[source].to_int().to_double() / 65535.0,
      image.data[source + 1].to_int().to_double() / 65535.0,
      image.data[source + 2].to_int().to_double() / 65535.0,
    )
    if converted.0.is_nan() ||
      converted.1.is_nan() ||
      converted.2.is_nan() ||
      converted.0.is_inf() ||
      converted.1.is_inf() ||
      converted.2.is_inf() {
      return Err(
        decode_error(
          InvalidData,
          "icc/transform",
          "Profile produces non-finite color",
        ),
      )
    }
    output[source] = icc_quantize16(converted.0)
    output[source + 1] = icc_quantize16(converted.1)
    output[source + 2] = icc_quantize16(converted.2)
    output[source + 3] = image.data[source + 3]
  }
  Ok({ width: image.width, height: image.height, data: output, })
}
