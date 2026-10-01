///|
/// Parameters for `to_sdr_rgba16`.
///
/// `peak_luminance_nits` is the nominal display peak used for HLG's reference
/// display OOTF and as the extended-Reinhard shoulder.  `reference_white_nits`
/// is the linear-light normalization anchor.  Both values are absolute cd/m2
/// (nits), and `reference_white_nits` must not exceed the peak.  `exposure_stops`
/// is a base-2 gain applied before tone mapping.  The default is a 1000-nit
/// HLG reference-display peak and tone-map shoulder, with a 100-nit reference
/// white and zero exposure. The output remains normalized SDR.
pub(all) struct HdrToneMapOptions {
  peak_luminance_nits : Double
  reference_white_nits : Double
  exposure_stops : Double
}

///|
pub fn HdrToneMapOptions::default() -> HdrToneMapOptions {
  {
    peak_luminance_nits: 1000.0,
    reference_white_nits: 100.0,
    exposure_stops: 0.0,
  }
}

///|
priv struct HdrRgbMatrix {
  m00 : Double
  m01 : Double
  m02 : Double
  m10 : Double
  m11 : Double
  m12 : Double
  m20 : Double
  m21 : Double
  m22 : Double
}

///|
fn hdr_identity_matrix() -> HdrRgbMatrix {
  {
    m00: 1.0,
    m01: 0.0,
    m02: 0.0,
    m10: 0.0,
    m11: 1.0,
    m12: 0.0,
    m20: 0.0,
    m21: 0.0,
    m22: 1.0,
  }
}

///|
fn hdr_matrix_apply(
  m : HdrRgbMatrix,
  r : Double,
  g : Double,
  b : Double,
) -> (Double, Double, Double) {
  (
    m.m00 * r + m.m01 * g + m.m02 * b,
    m.m10 * r + m.m11 * g + m.m12 * b,
    m.m20 * r + m.m21 * g + m.m22 * b,
  )
}

///|
fn hdr_matrix_mul(a : HdrRgbMatrix, b : HdrRgbMatrix) -> HdrRgbMatrix {
  {
    m00: a.m00 * b.m00 + a.m01 * b.m10 + a.m02 * b.m20,
    m01: a.m00 * b.m01 + a.m01 * b.m11 + a.m02 * b.m21,
    m02: a.m00 * b.m02 + a.m01 * b.m12 + a.m02 * b.m22,
    m10: a.m10 * b.m00 + a.m11 * b.m10 + a.m12 * b.m20,
    m11: a.m10 * b.m01 + a.m11 * b.m11 + a.m12 * b.m21,
    m12: a.m10 * b.m02 + a.m11 * b.m12 + a.m12 * b.m22,
    m20: a.m20 * b.m00 + a.m21 * b.m10 + a.m22 * b.m20,
    m21: a.m20 * b.m01 + a.m21 * b.m11 + a.m22 * b.m21,
    m22: a.m20 * b.m02 + a.m21 * b.m12 + a.m22 * b.m22,
  }
}

///|
fn hdr_matrix_inverse(m : HdrRgbMatrix) -> HdrRgbMatrix? {
  let determinant = m.m00 * (m.m11 * m.m22 - m.m12 * m.m21) -
    m.m01 * (m.m10 * m.m22 - m.m12 * m.m20) +
    m.m02 * (m.m10 * m.m21 - m.m11 * m.m20)
  if determinant.is_nan() || determinant.is_inf() || determinant.abs() < 1.0e-12 {
    return None
  }
  Some({
    m00: (m.m11 * m.m22 - m.m12 * m.m21) / determinant,
    m01: (m.m02 * m.m21 - m.m01 * m.m22) / determinant,
    m02: (m.m01 * m.m12 - m.m02 * m.m11) / determinant,
    m10: (m.m12 * m.m20 - m.m10 * m.m22) / determinant,
    m11: (m.m00 * m.m22 - m.m02 * m.m20) / determinant,
    m12: (m.m02 * m.m10 - m.m00 * m.m12) / determinant,
    m20: (m.m10 * m.m21 - m.m11 * m.m20) / determinant,
    m21: (m.m01 * m.m20 - m.m00 * m.m21) / determinant,
    m22: (m.m00 * m.m11 - m.m01 * m.m10) / determinant,
  })
}

///|
/// H.273 Table 2 chromaticities for every RGB primary set already recognized
/// by the decoder.  Value 10 is CIE XYZ, handled as an identity XYZ source.
fn hdr_primary_chromaticities(
  primaries : Int,
) -> (Double, Double, Double, Double, Double, Double, Double, Double)? {
  match primaries {
    // BT.709 / sRGB, D65.
    1 => Some((0.640, 0.330, 0.300, 0.600, 0.150, 0.060, 0.3127, 0.3290))
    // BT.470 System M, C white.
    4 => Some((0.670, 0.330, 0.210, 0.710, 0.140, 0.080, 0.310, 0.316))
    // BT.470 System B, G, D65.
    5 => Some((0.640, 0.330, 0.290, 0.600, 0.150, 0.060, 0.3127, 0.3290))
    // SMPTE 170M / BT.601, D65.
    6 => Some((0.630, 0.340, 0.310, 0.595, 0.155, 0.070, 0.3127, 0.3290))
    // SMPTE 240M, D65.
    7 => Some((0.630, 0.340, 0.310, 0.595, 0.155, 0.070, 0.3127, 0.3290))
    // Generic film, C white.
    8 => Some((0.681, 0.319, 0.243, 0.692, 0.145, 0.049, 0.310, 0.316))
    // BT.2020, D65.
    9 => Some((0.708, 0.292, 0.170, 0.797, 0.131, 0.046, 0.3127, 0.3290))
    // CIE XYZ has no RGB chromaticities.
    10 => None
    // SMPTE RP 431-2 / DCI-P3, DCI white.
    11 => Some((0.680, 0.320, 0.265, 0.690, 0.150, 0.060, 0.314, 0.351))
    // SMPTE EG 432-1 / Display-P3, D65.
    12 => Some((0.680, 0.320, 0.265, 0.690, 0.150, 0.060, 0.3127, 0.3290))
    // EBU Tech. 3213-E, D65.
    22 => Some((0.630, 0.340, 0.295, 0.605, 0.155, 0.077, 0.3127, 0.3290))
    _ => None
  }
}

///|
/// Build the RGB-to-XYZ matrix from the primary and reference-white
/// chromaticities in H.273 Table 2.
fn hdr_rgb_to_xyz(primaries : Int) -> HdrRgbMatrix? {
  let (rx, ry, gx, gy, bx, by, wx, wy) = match
    hdr_primary_chromaticities(primaries) {
    Some(value) => value
    None => return None
  }
  let p = {
    m00: rx / ry,
    m01: gx / gy,
    m02: bx / by,
    m10: 1.0,
    m11: 1.0,
    m12: 1.0,
    m20: (1.0 - rx - ry) / ry,
    m21: (1.0 - gx - gy) / gy,
    m22: (1.0 - bx - by) / by,
  }
  let inverse = match hdr_matrix_inverse(p) {
    Some(value) => value
    None => return None
  }
  let white = (wx / wy, 1.0, (1.0 - wx - wy) / wy)
  let (sr, sg, sb) = hdr_matrix_apply(inverse, white.0, white.1, white.2)
  Some({
    m00: p.m00 * sr,
    m01: p.m01 * sg,
    m02: p.m02 * sb,
    m10: p.m10 * sr,
    m11: p.m11 * sg,
    m12: p.m12 * sb,
    m20: p.m20 * sr,
    m21: p.m21 * sg,
    m22: p.m22 * sb,
  })
}

///|
fn hdr_adapt_source_white_to_d65(primaries : Int) -> HdrRgbMatrix? {
  let (_, _, _, _, _, _, wx, wy) = match hdr_primary_chromaticities(primaries) {
    Some(value) => value
    None => return None
  }
  let source_white = (wx / wy, 1.0, (1.0 - wx - wy) / wy)
  let target_white = (0.3127 / 0.3290, 1.0, (1.0 - 0.3127 - 0.3290) / 0.3290)
  // Bradford chromatic adaptation.  It is identity (within rounding) for
  // the D65 primary sets, while keeping C/DCI-P3 sources neutral in BT.709.
  let bradford = {
    m00: 0.8951,
    m01: 0.2664,
    m02: -0.1614,
    m10: -0.7502,
    m11: 1.7135,
    m12: 0.0367,
    m20: 0.0389,
    m21: -0.0685,
    m22: 1.0296,
  }
  let inverse = match hdr_matrix_inverse(bradford) {
    Some(value) => value
    None => return None
  }
  let source_lms = hdr_matrix_apply(
    bradford,
    source_white.0,
    source_white.1,
    source_white.2,
  )
  let target_lms = hdr_matrix_apply(
    bradford,
    target_white.0,
    target_white.1,
    target_white.2,
  )
  if source_lms.0 == 0.0 ||
    source_lms.1 == 0.0 ||
    source_lms.2 == 0.0 ||
    !hdr_finite(source_lms.0) ||
    !hdr_finite(source_lms.1) ||
    !hdr_finite(source_lms.2) ||
    !hdr_finite(target_lms.0) ||
    !hdr_finite(target_lms.1) ||
    !hdr_finite(target_lms.2) {
    return None
  }
  let scale = {
    m00: target_lms.0 / source_lms.0,
    m01: 0.0,
    m02: 0.0,
    m10: 0.0,
    m11: target_lms.1 / source_lms.1,
    m12: 0.0,
    m20: 0.0,
    m21: 0.0,
    m22: target_lms.2 / source_lms.2,
  }
  Some(hdr_matrix_mul(inverse, hdr_matrix_mul(scale, bradford)))
}

///|
fn hdr_source_to_bt709(primaries : Int) -> HdrRgbMatrix? {
  let target = match hdr_rgb_to_xyz(1) {
    Some(value) => value
    None => return None
  }
  let target_inverse = match hdr_matrix_inverse(target) {
    Some(value) => value
    None => return None
  }
  if primaries == 10 {
    // CICP 10 is CIE XYZ, so no source RGB-to-XYZ matrix is required.
    return Some(target_inverse)
  }
  let source = match hdr_rgb_to_xyz(primaries) {
    Some(value) => value
    None => return None
  }
  let adaptation = match hdr_adapt_source_white_to_d65(primaries) {
    Some(value) => value
    None => return None
  }
  Some(hdr_matrix_mul(target_inverse, hdr_matrix_mul(adaptation, source)))
}

///|
fn hdr_finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
fn hdr_options_valid(options : HdrToneMapOptions) -> Bool {
  hdr_finite(options.peak_luminance_nits) &&
  hdr_finite(options.reference_white_nits) &&
  hdr_finite(options.exposure_stops) &&
  options.peak_luminance_nits >= 1.0 &&
  options.peak_luminance_nits <= 10000.0 &&
  options.reference_white_nits >= 1.0 &&
  options.reference_white_nits <= options.peak_luminance_nits &&
  options.exposure_stops >= -16.0 &&
  options.exposure_stops <= 16.0
}

///|
fn hdr_matrix_metadata_valid(frame : Av1NativeFrame) -> Bool {
  if frame.planes.length() == 1 {
    return av1_color_transfer_supported(frame.transfer_characteristics)
  }
  if frame.matrix_coefficients == 0 &&
    (frame.subsampling_x || frame.subsampling_y) {
    return false
  }
  av1_color_supported(
    frame.matrix_coefficients,
    frame.color_primaries,
    frame.transfer_characteristics,
  ) &&
  av1_color_transfer_supported(frame.transfer_characteristics) &&
  (if frame.color_primaries == 10 {
    frame.matrix_coefficients == 11
  } else {
    hdr_primary_chromaticities(frame.color_primaries) is Some(_)
  }) &&
  !((frame.matrix_coefficients == 12 || frame.matrix_coefficients == 13) &&
  av1_color_derived_coefficients(frame.color_primaries) is None)
}

///|
fn hdr_decode_transfer(value : Double, transfer : Int) -> Double? {
  match av1_color_linear(value, transfer) {
    Some(linear) => if hdr_finite(linear) { Some(linear) } else { None }
    None => None
  }
}

///|
fn hdr_unpremultiply(
  value : Double,
  maximum : Double,
  coverage : Double,
) -> Double {
  if coverage <= 0.0 || value <= 0.0 {
    0.0
  } else {
    value * maximum / coverage
  }
}

///|
fn hdr_decode_yuv(
  color : Av1NativeFrame,
  x : Int,
  y_index : Int,
) -> (Double, Double, Double)? {
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
  let luma = color.planes[0].data[y_index * color.width + x].to_double()
  let y_value = (luma - black) / luma_span
  if mono {
    return Some((y_value, y_value, y_value))
  }
  let u_plane = color.planes[1]
  let v_plane = color.planes[2]
  let cx = if color.subsampling_x { x / 2 } else { x }
  let cy = if color.subsampling_y { y_index / 2 } else { y_index }
  let ci = cy * u_plane.width + cx
  let u = u_plane.data[ci].to_double()
  let v = v_plane.data[ci].to_double()
  if color.matrix_coefficients == 0 {
    Some(((v - black) / luma_span, y_value, (u - black) / luma_span))
  } else {
    av1_color_rgb(
      y_value,
      (u - midpoint) / chroma_span,
      (v - midpoint) / chroma_span,
      color.matrix_coefficients,
      color.color_primaries,
      color.transfer_characteristics,
    )
  }
}

///|
fn hdr_hlg_scene_weights(
  primaries : Int,
  mono : Bool,
) -> (Double, Double, Double)? {
  if mono {
    // Monochrome has no RGB primary set; its scalar channel is its scene
    // luminance by definition.
    Some((1.0, 0.0, 0.0))
  } else if primaries == 10 {
    // CICP 10 carries CIE XYZ, whose Y component is scene luminance.
    Some((0.0, 1.0, 0.0))
  } else if primaries == 9 {
    // BT.2100 explicitly defines the HLG OOTF with these BT.2020 weights.
    Some((0.2627, 0.6780, 0.0593))
  } else {
    // Other declared RGB primaries use their own XYZ Y row. This avoids
    // silently applying BT.2020 weights to BT.709, P3, or legacy RGB sets.
    match hdr_rgb_to_xyz(primaries) {
      Some(matrix) => Some((matrix.m10, matrix.m11, matrix.m12))
      None => None
    }
  }
}

///|
fn hdr_to_display_nits(
  r : Double,
  g : Double,
  b : Double,
  transfer : Int,
  peak_luminance_nits : Double,
  reference_white_nits : Double,
  scene_weights : (Double, Double, Double),
) -> (Double, Double, Double)? {
  let lr = match hdr_decode_transfer(r, transfer) {
    Some(value) => value
    None => return None
  }
  let lg = match hdr_decode_transfer(g, transfer) {
    Some(value) => value
    None => return None
  }
  let lb = match hdr_decode_transfer(b, transfer) {
    Some(value) => value
    None => return None
  }
  if transfer == 16 {
    Some((lr * 10000.0, lg * 10000.0, lb * 10000.0))
  } else if transfer == 18 {
    // BT.2100 Table 5: HLG's inverse OETF yields scene-linear E; the
    // reference display OOTF applies alpha * E * Ys^(gamma-1), with alpha
    // equal to the nominal peak luminance in cd/m2.
    let ys = scene_weights.0 * lr + scene_weights.1 * lg + scene_weights.2 * lb
    let gamma = 1.2 + 0.42 * @math.log10(peak_luminance_nits / 1000.0)
    let ootf = if ys <= 0.0 { 0.0 } else { @math.pow(ys, gamma - 1.0) }
    Some(
      (
        peak_luminance_nits * lr * ootf,
        peak_luminance_nits * lg * ootf,
        peak_luminance_nits * lb * ootf,
      ),
    )
  } else {
    // SDR and scene-linear CICP transfers use the declared reference white as
    // their absolute anchor.  PQ is the only absolute transfer in H.273.
    Some(
      (
        lr * reference_white_nits,
        lg * reference_white_nits,
        lb * reference_white_nits,
      ),
    )
  }
}

///|
fn hdr_tone_map_luminance(
  luminance : Double,
  options : HdrToneMapOptions,
) -> Double {
  if luminance <= 0.0 {
    return 0.0
  }
  let exposed = luminance * @math.pow(2.0, options.exposure_stops)
  let x = exposed / options.reference_white_nits
  let white = options.peak_luminance_nits / options.reference_white_nits
  // Extended Reinhard, with white equal to the configured peak. Values above
  // the shoulder are clipped only at the final normalized output.
  let mapped = x * (1.0 + x / (white * white)) / (1.0 + x)
  if mapped <= 0.0 {
    0.0
  } else if mapped >= 1.0 {
    1.0
  } else {
    mapped
  }
}

///|
fn hdr_clamp01(value : Double) -> Double {
  if value <= 0.0 {
    0.0
  } else if value >= 1.0 {
    1.0
  } else {
    value
  }
}

///|
fn hdr_quantize(value : Double) -> UInt16 {
  (hdr_clamp01(value) * 65535.0 + 0.5).to_int().to_uint16()
}

///|
fn hdr_alpha16(coverage : Int, maximum : Int) -> UInt16 {
  ((coverage * 65535 + maximum / 2) / maximum).to_uint16()
}

///|
fn hdr_write_sdr_rgba16(
  color : Av1NativeFrame,
  alpha : Av1NativeFrame?,
  premultiplied : Bool,
  options : HdrToneMapOptions,
  source_to_bt709 : HdrRgbMatrix,
  scene_weights : (Double, Double, Double),
  out : FixedArray[UInt16],
) -> Result[Unit, DecodeError] {
  let maximum = (1 << color.bit_depth) - 1
  let maximum_f = maximum.to_double()
  let transfer = color.transfer_characteristics
  for y in 0..<color.height {
    for x in 0..<color.width {
      let encoded = match hdr_decode_yuv(color, x, y) {
        Some(value) => value
        None =>
          return Err(
            decode_error(
              InvalidData,
              "hdr/color",
              "Color matrix reconstruction produced invalid values",
            ),
          )
      }
      let (encoded_r0, encoded_g0, encoded_b0) = encoded
      let mut r = encoded_r0
      let mut g = encoded_g0
      let mut b = encoded_b0
      let coverage = match alpha {
        None => maximum
        Some(frame) => {
          let sample = frame.planes[0].data[y * color.width + x]
          if frame.full_range {
            sample
          } else {
            av1_alpha_expand_limited_sample(sample, frame.bit_depth)
          }
        }
      }
      if premultiplied {
        let coverage_f = coverage.to_double()
        r = hdr_unpremultiply(r, maximum_f, coverage_f)
        g = hdr_unpremultiply(g, maximum_f, coverage_f)
        b = hdr_unpremultiply(b, maximum_f, coverage_f)
      }
      let (lr, lg, lb) = match
        hdr_to_display_nits(
          r,
          g,
          b,
          transfer,
          options.peak_luminance_nits,
          options.reference_white_nits,
          scene_weights,
        ) {
        Some(value) => value
        None =>
          return Err(
            decode_error(
              InvalidData,
              "hdr/transfer",
              "Transfer inverse produced a non-finite value",
            ),
          )
      }
      let (rr0, gg0, bb0) = hdr_matrix_apply(source_to_bt709, lr, lg, lb)
      let mut rr = rr0
      let mut gg = gg0
      let mut bb = bb0
      if !hdr_finite(rr) || !hdr_finite(gg) || !hdr_finite(bb) {
        return Err(
          decode_error(
            InvalidData,
            "hdr/color",
            "Gamut conversion produced a non-finite value",
          ),
        )
      }
      let luminance = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb
      let mapped = hdr_tone_map_luminance(luminance, options)
      if luminance > 0.0 {
        let scale = mapped / luminance
        rr *= scale
        gg *= scale
        bb *= scale
      } else {
        rr = 0.0
        gg = 0.0
        bb = 0.0
      }
      // SDR output uses the IEC 61966-2-1 / H.273 transfer (CICP 13).
      let encoded_r = match av1_color_nonlinear(hdr_clamp01(rr), 13) {
        Some(value) => value
        None =>
          return Err(
            decode_error(InvalidData, "hdr/output", "sRGB encoding failed"),
          )
      }
      let encoded_g = match av1_color_nonlinear(hdr_clamp01(gg), 13) {
        Some(value) => value
        None =>
          return Err(
            decode_error(InvalidData, "hdr/output", "sRGB encoding failed"),
          )
      }
      let encoded_b = match av1_color_nonlinear(hdr_clamp01(bb), 13) {
        Some(value) => value
        None =>
          return Err(
            decode_error(InvalidData, "hdr/output", "sRGB encoding failed"),
          )
      }
      let destination = (y * color.width + x) * 4
      out[destination] = hdr_quantize(encoded_r)
      out[destination + 1] = hdr_quantize(encoded_g)
      out[destination + 2] = hdr_quantize(encoded_b)
      out[destination + 3] = hdr_alpha16(coverage, maximum)
    }
  }
  Ok(())
}

///|
fn av1_native_to_sdr_rgba16(
  color : Av1NativeFrame,
  alpha : Av1NativeFrame?,
  premultiplied : Bool,
  options : HdrToneMapOptions,
) -> Result[Image16, DecodeError] {
  if !hdr_options_valid(options) {
    return Err(
      decode_error(
        InvalidData,
        "hdr/options",
        "HDR options must be finite, peak/reference white must be 1..10000 nits with reference <= peak, and exposure must be within +/-16 stops",
      ),
    )
  }
  if !av1_native_pixels_valid(color) || (premultiplied && alpha is None) {
    return Err(
      decode_error(
        InvalidBuffer,
        "hdr/input",
        "Native color or alpha planes are malformed",
      ),
    )
  }
  if alpha is Some(plane) {
    if !av1_native_pixels_valid(plane) ||
      plane.width != color.width ||
      plane.height != color.height ||
      plane.bit_depth != color.bit_depth ||
      plane.planes.length() != 1 {
      return Err(
        decode_error(
          InvalidBuffer,
          "hdr/alpha",
          "Alpha plane does not match the native color image",
        ),
      )
    }
  }
  if !hdr_matrix_metadata_valid(color) {
    return Err(
      decode_error(
        Unsupported,
        "hdr/color",
        "Color matrix, transfer, or primaries are unsupported for HDR conversion",
      ),
    )
  }
  if color.transfer_characteristics == 18 &&
    1.2 + 0.42 * @math.log10(options.peak_luminance_nits / 1000.0) <= 0.0 {
    return Err(
      decode_error(
        InvalidData,
        "hdr/options",
        "HLG peak must give a positive system gamma",
      ),
    )
  }
  let source_to_bt709 = if color.planes.length() == 1 {
    // Monochrome is scalar and does not depend on an RGB primary set.
    hdr_identity_matrix()
  } else {
    match hdr_source_to_bt709(color.color_primaries) {
      Some(value) => value
      None =>
        return Err(
          decode_error(
            Unsupported,
            "hdr/primaries",
            "No finite RGB-to-BT.709 gamut conversion is defined",
          ),
        )
    }
  }
  let scene_weights = match
    hdr_hlg_scene_weights(color.color_primaries, color.planes.length() == 1) {
    Some(value) => value
    None =>
      return Err(
        decode_error(
          Unsupported,
          "hdr/primaries",
          "No scene luminance weights for these primaries",
        ),
      )
  }
  let out = FixedArray::make(color.width * color.height * 4, (0 : UInt16))
  match
    hdr_write_sdr_rgba16(
      color, alpha, premultiplied, options, source_to_bt709, scene_weights, out,
    ) {
    Err(error) => Err(error)
    Ok(_) => Ok({ width: color.width, height: color.height, data: out, })
  }
}

///|
/// Convert an owned native AV1 frame to straight SDR RGBA16.  PQ samples are
/// interpreted as absolute luminance up to 10,000 nits; HLG samples use the
/// BT.2100 scene-to-display OOTF.  The conversion is performed directly from
/// native-depth planes and returns a newly owned buffer.
pub fn Av1NativeFrame::to_sdr_rgba16(
  self : Av1NativeFrame,
  options? : HdrToneMapOptions = HdrToneMapOptions::default(),
) -> Result[Image16, DecodeError] {
  av1_native_to_sdr_rgba16(self, None, false, options)
}

///|
/// Convert an AVIF native image to straight SDR RGBA16, preserving native
/// alpha precision and undoing color premultiplication before tone mapping.
pub fn AvifNativeImage::to_sdr_rgba16(
  self : AvifNativeImage,
  options? : HdrToneMapOptions = HdrToneMapOptions::default(),
) -> Result[Image16, DecodeError] {
  av1_native_to_sdr_rgba16(self.color, self.alpha, self.premultiplied, options)
}
