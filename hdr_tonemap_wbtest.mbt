///|
fn hdr_test_neutral_frame(
  transfer : Int,
  primaries : Int,
  y_code : Int,
  alpha_code : Int?,
) -> AvifNativeImage {
  let color : Av1NativeFrame = {
    width: 1,
    height: 1,
    bit_depth: 12,
    subsampling_x: false,
    subsampling_y: false,
    full_range: true,
    matrix_coefficients: 1,
    color_primaries: primaries,
    transfer_characteristics: transfer,
    planes: [
      { width: 1, height: 1, data: [y_code], },
      { width: 1, height: 1, data: [2048], },
      { width: 1, height: 1, data: [2048], },
    ],
  }
  let alpha = alpha_code.map(value => {
    width: 1,
    height: 1,
    bit_depth: 12,
    subsampling_x: false,
    subsampling_y: false,
    full_range: true,
    matrix_coefficients: 0,
    color_primaries: 1,
    transfer_characteristics: 13,
    planes: [{ width: 1, height: 1, data: [value], }],
  })
  { color, alpha, premultiplied: alpha_code is Some(_), }
}

///|
fn hdr_test_pq_code(linear : Double) -> Int {
  (av1_color_nonlinear(linear, 16).unwrap() * 4095.0 + 0.5).to_int()
}

///|
fn hdr_test_hlg_code(scene : Double) -> Int {
  (av1_color_nonlinear(scene, 18).unwrap() * 4095.0 + 0.5).to_int()
}

///|
fn hdr_test_mono_frame(transfer : Int, y_code : Int) -> Av1NativeFrame {
  {
    width: 1,
    height: 1,
    bit_depth: 12,
    subsampling_x: false,
    subsampling_y: false,
    full_range: true,
    matrix_coefficients: 2,
    color_primaries: 2,
    transfer_characteristics: transfer,
    planes: [{ width: 1, height: 1, data: [y_code], }],
  }
}

///|
fn hdr_test_near(
  actual : Double,
  expected : Double,
  tolerance : Double,
) -> Unit raise {
  assert_true(
    actual >= expected - tolerance && actual <= expected + tolerance,
    msg="actual=\{actual}, expected=\{expected}, tolerance=\{tolerance}",
  )
}

///|
test "HDR PQ neutral conversion is finite and owned" {
  let code = hdr_test_pq_code(0.01)
  let image = hdr_test_neutral_frame(16, 1, code, None)
  let first = image.to_sdr_rgba16().unwrap()
  let second = image.to_sdr_rgba16().unwrap()
  assert_true(first.data[0].to_int() > 30000)
  assert_eq(first.data[0], first.data[1])
  assert_eq(first.data[1], first.data[2])
  first.data[0] = 0
  assert_true(second.data[0].to_int() > 30000)
}

///|
test "HDR HLG uses the configured peak in the scene-to-display OOTF" {
  let code = hdr_test_hlg_code(0.18)
  let image = hdr_test_neutral_frame(18, 1, code, None)
  let low_peak = image
    .to_sdr_rgba16(options={
      peak_luminance_nits: 600.0,
      reference_white_nits: 100.0,
      exposure_stops: 0.0,
    })
    .unwrap()
  let high_peak = image
    .to_sdr_rgba16(options={
      peak_luminance_nits: 2000.0,
      reference_white_nits: 100.0,
      exposure_stops: 0.0,
    })
    .unwrap()
  assert_true(low_peak.data[0].to_int() != high_peak.data[0].to_int())
  assert_eq(low_peak.data[0], low_peak.data[1])
  assert_eq(high_peak.data[1], high_peak.data[2])
}

///|
test "HDR HLG scene luminance follows declared primaries" {
  let p3_red = hdr_hlg_scene_weights(12, false).unwrap().0
  let bt2020_red = hdr_hlg_scene_weights(9, false).unwrap().0
  let xyz = hdr_hlg_scene_weights(10, false).unwrap()
  hdr_test_near(p3_red, 0.22897456406974875, 1.0e-12)
  hdr_test_near(bt2020_red, 0.2627, 1.0e-12)
  assert_eq(xyz, (0.0, 1.0, 0.0))
  assert_true((p3_red - bt2020_red).abs() > 0.02)
}

///|
test "HDR source primaries map neutral and chromatic P3 through BT.709" {
  let neutral = hdr_test_neutral_frame(16, 12, hdr_test_pq_code(0.01), None)
  let output = neutral.to_sdr_rgba16().unwrap()
  assert_true((output.data[0].to_int() - output.data[1].to_int()).abs() <= 1)
  assert_true((output.data[1].to_int() - output.data[2].to_int()).abs() <= 1)
  let gamut = match hdr_source_to_bt709(12) {
    Some(value) => value
    None => abort("P3-D65 gamut matrix is unavailable")
  }
  let (r, g, b) = hdr_matrix_apply(gamut, 1.0, 0.0, 0.0)
  // Independent solve of the Display-P3/D65 and BT.709/D65 primary matrices
  // (with Bradford adaptation) for a linear P3 red sample.
  hdr_test_near(r, 1.22494018, 1.0e-6)
  hdr_test_near(g, -0.04205695, 1.0e-6)
  hdr_test_near(b, -0.01963755, 1.0e-6)
}

///|
test "HDR alpha remains native-precision and premultiplication is undone" {
  let code = hdr_test_pq_code(0.01)
  let image = hdr_test_neutral_frame(16, 1, code, Some(2048))
  let output = image.to_sdr_rgba16().unwrap()
  assert_true(output.data[0].to_int() > 30000)
  assert_eq(output.data[0], output.data[1])
  assert_eq(output.data[1], output.data[2])
  // Exact 12-bit alpha expansion: round(2048 * 65535 / 4095).
  assert_eq(output.data[3].to_int(), 32776)
}

///|
test "HDR rejects invalid options and unsupported metadata" {
  let image = hdr_test_neutral_frame(16, 1, hdr_test_pq_code(0.01), None)
  let invalid = image.to_sdr_rgba16(options={
    peak_luminance_nits: 100.0,
    reference_white_nits: 200.0,
    exposure_stops: 0.0,
  })
  assert_true(invalid is Err(_))
  let bad_transfer = hdr_test_neutral_frame(2, 1, 2048, None)
  match bad_transfer.to_sdr_rgba16() {
    Ok(_) => abort("unsupported transfer unexpectedly succeeded")
    Err(error) => assert_eq(error.kind, Unsupported)
  }
  let bad_ictcp : AvifNativeImage = {
    ..bad_transfer,
    color: {
      ..bad_transfer.color,
      matrix_coefficients: 14,
      transfer_characteristics: 13,
    },
  }
  match bad_ictcp.to_sdr_rgba16() {
    Ok(_) => abort("ICTCP with SDR transfer unexpectedly succeeded")
    Err(error) => assert_eq(error.kind, Unsupported)
  }
  let bad_primaries = hdr_test_neutral_frame(
    16,
    2,
    hdr_test_pq_code(0.01),
    None,
  )
  match bad_primaries.to_sdr_rgba16() {
    Ok(_) => abort("unspecified primaries unexpectedly succeeded")
    Err(error) => assert_eq(error.kind, Unsupported)
  }
}

///|
test "HDR monochrome permits unspecified primaries for PQ and HLG" {
  let pq = hdr_test_mono_frame(16, hdr_test_pq_code(0.01))
    .to_sdr_rgba16()
    .unwrap()
  assert_eq(pq.data[0], pq.data[1])
  assert_eq(pq.data[1], pq.data[2])
  let hlg = hdr_test_mono_frame(18, hdr_test_hlg_code(0.18))
    .to_sdr_rgba16()
    .unwrap()
  assert_eq(hlg.data[0], hlg.data[1])
  assert_eq(hlg.data[1], hlg.data[2])
}

///|
test "HDR XYZ primaries use matrix 11 and the XYZ Y channel" {
  let source = hdr_test_neutral_frame(16, 10, hdr_test_pq_code(0.01), None)
  let xyz : AvifNativeImage = {
    ..source,
    color: { ..source.color, matrix_coefficients: 11, color_primaries: 10, },
  }
  assert_true(xyz.to_sdr_rgba16() is Ok(_))
}

///|
test "HDR rejects nonmonotonic HLG peaks and subsampled identity RGB" {
  let hlg = hdr_test_mono_frame(18, 1)
  assert_eq(
    demux_test_error(
      hlg.to_sdr_rgba16(options={
        peak_luminance_nits: 1.0,
        reference_white_nits: 1.0,
        exposure_stops: 0.0,
      }),
    ),
    InvalidData,
  )
  let rgb = hdr_test_neutral_frame(16, 9, 2048, None).color
  let invalid = { ..rgb, matrix_coefficients: 0, subsampling_x: true, }
  assert_eq(demux_test_error(invalid.to_sdr_rgba16()), Unsupported)
}
