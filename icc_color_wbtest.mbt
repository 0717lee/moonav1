///|
/// Focused white-box checks for ICC curve and PCS math. Public parser and
/// image-ownership behavior is covered by the appended public fixture tests.
test "ICC curve joins and legacy Lab neutral encoding" {
  let gamma_difference = icc_curve_eval(IccGamma(2.0), 0.5) - 0.25
  assert_true(gamma_difference > -0.000001 && gamma_difference < 0.000001)
  let sampled = IccSampled([0.0, 0.25, 1.0])
  let sampled_difference = icc_curve_eval(sampled, 0.75) - 0.625
  assert_true(sampled_difference > -0.000001 && sampled_difference < 0.000001)
  let legacy = icc_lab_to_xyz(0.0, 32768.0 / 65535.0, 32768.0 / 65535.0, true)
  let modern = icc_lab_to_xyz(0.0, 32768.0 / 65535.0, 32768.0 / 65535.0, false)
  let extended = icc_lab_to_xyz(1.0, 32768.0 / 65535.0, 32768.0 / 65535.0, true)
  assert_true(legacy.0 > -0.001 && legacy.0 < 0.001)
  assert_true(modern.0 > -0.001 && modern.0 < 0.001)
  assert_true(extended.1 > 1.0)
}

///|
test "ICC parametric curve branches clip and reject v2 parameter tags" {
  let type3 = IccParametric(3, [2.0, 1.0, 0.0, 0.5, 0.25])
  assert_true((icc_curve_eval(type3, 0.2) - 0.1).abs() < 1.0e-12)
  assert_true((icc_curve_eval(type3, 0.5) - 0.25).abs() < 1.0e-12)
  let type4 = IccParametric(4, [2.0, 1.0, 0.0, 0.5, 0.25, 0.1, 0.02])
  assert_true((icc_curve_eval(type4, 0.2) - 0.12).abs() < 1.0e-12)
  assert_true((icc_curve_eval(type4, 0.5) - 0.35).abs() < 1.0e-12)
  assert_eq(
    icc_curve_eval(IccParametric(1, [32767.0, 32767.0, 32767.0]), 1.0),
    1.0,
  )
  let bytes = icc_test_profile(ICC_SIG_MNTR, ICC_SIG_GRAY, ICC_SIG_XYZ, [
    (ICC_SIG_WTPT, icc_test_xyz(0.9642, 1.0, 0.8249)),
    (ICC_SIG_KTRC, icc_test_para_type0(2.0)),
  ])
  assert_true(IccProfile::parse(bytes) is Ok(_))
  bytes[8] = 2
  assert_eq(demux_test_error(IccProfile::parse(bytes)), Unsupported)
}

///|
/// Helpers below build small, self-contained ICC fixtures. They deliberately
/// use only public byte-level profile structures so the tests exercise the
/// parser rather than private pipeline constructors.
fn icc_test_u16(data : Array[Byte], at : Int, value : Int) -> Unit {
  data[at] = (value >> 8).to_byte()
  data[at + 1] = (value & 255).to_byte()
}

///|
fn icc_test_u32(data : Array[Byte], at : Int, value : Int) -> Unit {
  data[at] = ((value >> 24) & 255).to_byte()
  data[at + 1] = ((value >> 16) & 255).to_byte()
  data[at + 2] = ((value >> 8) & 255).to_byte()
  data[at + 3] = (value & 255).to_byte()
}

///|
fn icc_test_s15f16(data : Array[Byte], at : Int, value : Double) -> Unit {
  let fixed = (value * 65536.0).to_int()
  icc_test_u32(data, at, fixed)
}

///|
fn icc_test_sig(data : Array[Byte], at : Int, value : Int) -> Unit {
  icc_test_u32(data, at, value)
}

///|
fn icc_test_xyz(x : Double, y : Double, z : Double) -> Array[Byte] {
  let data = Array::make(20, b'\x00')
  icc_test_sig(data, 0, ICC_SIG_XYZ_TYPE)
  icc_test_s15f16(data, 8, x)
  icc_test_s15f16(data, 12, y)
  icc_test_s15f16(data, 16, z)
  data
}

///|
fn icc_test_gamma(gamma : Double) -> Array[Byte] {
  let data = Array::make(16, b'\x00')
  icc_test_sig(data, 0, ICC_SIG_CURV)
  icc_test_u32(data, 8, 1)
  icc_test_u16(data, 12, (gamma * 256.0).to_int())
  data
}

///|
fn icc_test_sampled(values : Array[Int]) -> Array[Byte] {
  let data = Array::make(12 + values.length() * 2, b'\x00')
  icc_test_sig(data, 0, ICC_SIG_CURV)
  icc_test_u32(data, 8, values.length())
  for i in 0..<values.length() {
    icc_test_u16(data, 12 + i * 2, values[i])
  }
  data
}

///|
fn icc_test_para_type0(gamma : Double) -> Array[Byte] {
  let data = Array::make(16, b'\x00')
  icc_test_sig(data, 0, ICC_SIG_PARA)
  icc_test_u16(data, 8, 0)
  icc_test_s15f16(data, 12, gamma)
  data
}

///|
fn icc_test_profile(
  device_class : Int,
  color_space : Int,
  pcs : Int,
  tags : Array[(Int, Array[Byte])],
) -> Array[Byte] {
  let table_end = 132 + tags.length() * 12
  let mut payload_size = table_end
  for item in tags {
    let bytes = item.1
    payload_size = (payload_size + 3) / 4 * 4 + bytes.length()
  }
  let profile = Array::make(payload_size, b'\x00')
  icc_test_u32(profile, 0, payload_size)
  profile[8] = b'\x04'
  icc_test_sig(profile, 12, device_class)
  icc_test_sig(profile, 16, color_space)
  icc_test_sig(profile, 20, pcs)
  icc_test_sig(profile, 36, ICC_SIG_ACSP)
  icc_test_u32(profile, 128, tags.length())
  let mut payload = table_end
  for i in 0..<tags.length() {
    let (signature, bytes) = tags[i]
    payload = (payload + 3) / 4 * 4
    icc_test_sig(profile, 132 + i * 12, signature)
    icc_test_u32(profile, 136 + i * 12, payload)
    icc_test_u32(profile, 140 + i * 12, bytes.length())
    for j in 0..<bytes.length() {
      profile[payload + j] = bytes[j]
    }
    payload += bytes.length()
  }
  profile
}

///|
fn icc_test_srgb_matrix_profile() -> Array[Byte] {
  icc_test_profile(ICC_SIG_MNTR, ICC_SIG_RGB, ICC_SIG_XYZ, [
    (
      ICC_SIG_RXYZ,
      icc_test_xyz(
        (0x6FA0).to_double() / 65536.0,
        (0x38F5).to_double() / 65536.0,
        (0x0390).to_double() / 65536.0,
      ),
    ),
    (
      ICC_SIG_GXYZ,
      icc_test_xyz(
        (0x6297).to_double() / 65536.0,
        (0xB787).to_double() / 65536.0,
        (0x18D9).to_double() / 65536.0,
      ),
    ),
    (
      ICC_SIG_BXYZ,
      icc_test_xyz(
        (0x249F).to_double() / 65536.0,
        (0x0F84).to_double() / 65536.0,
        (0xB6C3).to_double() / 65536.0,
      ),
    ),
    (ICC_SIG_RTRC, icc_test_gamma(1.0)),
    (ICC_SIG_GTRC, icc_test_gamma(1.0)),
    (ICC_SIG_BTRC, icc_test_gamma(1.0)),
  ])
}

///|
fn icc_test_gray_profile(
  gamma : Double,
  white : (Double, Double, Double),
) -> Array[Byte] {
  icc_test_profile(ICC_SIG_SCNR, ICC_SIG_GRAY, ICC_SIG_XYZ, [
    (ICC_SIG_WTPT, icc_test_xyz(white.0, white.1, white.2)),
    (ICC_SIG_KTRC, icc_test_gamma(gamma)),
  ])
}

///|
fn icc_test_mft2(identity : Bool, pcs_lab : Bool) -> Array[Byte] {
  // One-entry input/output tables would be legal only as degenerate tables;
  // two entries keep the fixture small while testing interpolation.
  let clut_values = 8 * 3
  let data = Array::make(52 + 3 * 4 + clut_values * 2 + 3 * 4, b'\x00')
  icc_test_sig(data, 0, ICC_SIG_MFT2)
  data[8] = b'\x03'
  data[9] = b'\x03'
  data[10] = b'\x02'
  for i in 0..<9 {
    icc_test_s15f16(data, 12 + i * 4, if i % 4 == 0 { 1.0 } else { 0.0 })
  }
  icc_test_u16(data, 48, 2)
  icc_test_u16(data, 50, 2)
  let input_start = 52
  for channel in 0..<3 {
    icc_test_u16(data, input_start + channel * 4, 0)
    icc_test_u16(data, input_start + channel * 4 + 2, 65535)
  }
  let clut_start = input_start + 12
  for cell in 0..<8 {
    let r = if (cell & 4) != 0 { 32768 } else { 0 }
    let g = if (cell & 2) != 0 { 32768 } else { 0 }
    let b = if (cell & 1) != 0 { 32768 } else { 0 }
    let values = if pcs_lab && !identity {
      [65280, 32768, 32768]
    } else {
      [r, g, b]
    }
    for channel in 0..<3 {
      icc_test_u16(data, clut_start + (cell * 3 + channel) * 2, values[channel])
    }
  }
  let output_start = clut_start + clut_values * 2
  for channel in 0..<3 {
    icc_test_u16(data, output_start + channel * 4, 0)
    icc_test_u16(data, output_start + channel * 4 + 2, 65535)
  }
  icc_test_profile(
    ICC_SIG_MNTR,
    ICC_SIG_RGB,
    if pcs_lab {
      ICC_SIG_LAB
    } else {
      ICC_SIG_XYZ
    },
    [(ICC_SIG_A2B0, data)],
  )
}

///|
fn icc_test_mab_identity() -> Array[Byte] {
  let data = Array::make(32 + 20 + 8 * 3 * 2 + 6 * 12, b'\x00')
  icc_test_sig(data, 0, ICC_SIG_MAB)
  data[8] = b'\x03'
  data[9] = b'\x03'
  icc_test_u32(data, 24, 32)
  icc_test_u32(data, 12, 100)
  icc_test_u32(data, 28, 136)
  for i in 0..<6 {
    icc_test_sig(data, 100 + i * 12, ICC_SIG_CURV)
  }
  let clut = 32
  data[clut] = b'\x02'
  data[clut + 1] = b'\x02'
  data[clut + 2] = b'\x02'
  data[clut + 16] = b'\x02'
  for cell in 0..<8 {
    let values = [
      if (cell & 1) != 0 {
        32768
      } else {
        0
      },
      if (cell & 2) != 0 {
        32768
      } else {
        0
      },
      if (cell & 4) != 0 {
        32768
      } else {
        0
      },
    ]
    for channel in 0..<3 {
      icc_test_u16(data, clut + 20 + (cell * 3 + channel) * 2, values[channel])
    }
  }
  icc_test_profile(ICC_SIG_MNTR, ICC_SIG_RGB, ICC_SIG_XYZ, [
    (ICC_SIG_A2B0, data),
  ])
}

///|
fn icc_test_mft1_identity() -> Array[Byte] {
  let data = Array::make(48 + 3 * 256 + 8 * 3 + 3 * 256, b'\x00')
  icc_test_sig(data, 0, ICC_SIG_MFT1)
  data[8] = b'\x03'
  data[9] = b'\x03'
  data[10] = b'\x02'
  for i in 0..<9 {
    icc_test_s15f16(data, 12 + i * 4, if i % 4 == 0 { 1.0 } else { 0.0 })
  }
  let input_start = 48
  for channel in 0..<3 {
    for sample in 0..<256 {
      data[input_start + channel * 256 + sample] = sample.to_byte()
    }
  }
  let clut_start = input_start + 3 * 256
  for cell in 0..<8 {
    data[clut_start + cell * 3] = (if (cell & 4) != 0 { 128 } else { 64 }).to_byte()
    data[clut_start + cell * 3 + 1] = (if (cell & 2) != 0 { 144 } else { 112 }).to_byte()
    data[clut_start + cell * 3 + 2] = (if (cell & 1) != 0 { 144 } else { 112 }).to_byte()
  }
  let output_start = clut_start + 8 * 3
  for channel in 0..<3 {
    for sample in 0..<256 {
      data[output_start + channel * 256 + sample] = sample.to_byte()
    }
  }
  icc_test_profile(ICC_SIG_MNTR, ICC_SIG_RGB, ICC_SIG_LAB, [
    (ICC_SIG_A2B0, data),
  ])
}

///|
test "ICC matrix/TRC preserves alpha and owns RGBA8 output" {
  let profile = IccProfile::parse(icc_test_srgb_matrix_profile()).unwrap()
  let source = Image::from_bytes(
    2,
    1,
    FixedArray::makei(8, i => {
      [b'\x00', b'\x80', b'\xFF', b'\x12', b'\xFF', b'\x00', b'\x00', b'\xA7'][i]
    }),
  )
  let result = profile.apply_rgba8(source).unwrap()
  assert_eq(result.get_pixel(0, 0), (b'\x00', b'\xBC', b'\xFF', b'\x12'))
  assert_eq(result.get_pixel(1, 0), (b'\xFF', b'\x00', b'\x00', b'\xA7'))
  result.data[0] = b'\x7F'
  assert_eq(source.get_pixel(0, 0).0, b'\x00')
}

///|
test "ICC gray parametric and D65 white conversion" {
  let profile = IccProfile::parse(
    icc_test_gray_profile(2.0, (0.95047, 1.0, 1.08883)),
  ).unwrap()
  let image = Image::from_bytes(
    1,
    1,
    FixedArray::makei(4, i => [b'\x80', b'\x04', b'\xE1', b'\x39'][i]),
  )
  let result = profile.apply_rgba8(image).unwrap()
  // Gray input uses the R channel; D65 white must not be adapted as if it
  // were D50, and gamma 2 maps 0.5 to linear 0.25 (~137 sRGB).
  assert_true(result.data[0].to_int() >= 136 && result.data[0].to_int() <= 138)
  assert_eq(result.data[0], result.data[1])
  assert_eq(result.data[1], result.data[2])
  assert_eq(result.data[3], b'\x39')
}

///|
test "ICC sampled TRC and RGBA16 keep native precision" {
  let profile = IccProfile::parse(
    icc_test_profile(ICC_SIG_MNTR, ICC_SIG_GRAY, ICC_SIG_XYZ, [
      (ICC_SIG_WTPT, icc_test_xyz(0.96422, 1.0, 0.82521)),
      (ICC_SIG_KTRC, icc_test_sampled([0, 16384, 65535])),
    ]),
  ).unwrap()
  let source = av1_frame_to_native(
      avif_alpha_precision_frame(12, true, 2, [[2048]]),
    )
    .to_rgba16()
    .unwrap()
  let result = profile.apply_rgba16(source).unwrap()
  // The three-entry curve reaches its middle entry at 0.5. Alpha is copied
  // exactly in the 16-bit domain; the input retains the native quantization.
  assert_true(
    result.data[0].to_int() > 35000 && result.data[0].to_int() < 35500,
  )
  assert_eq(result.data[0], result.data[1])
  assert_eq(result.data[1], result.data[2])
  assert_eq(result.data[3], 65535)
}

///|
test "ICC mft2 LUT supports XYZ and Lab PCS" {
  let xyz = IccProfile::parse(icc_test_mft2(true, false)).unwrap()
  let lab = IccProfile::parse(icc_test_mft2(false, true)).unwrap()
  let legacy_bytes = icc_test_mft2(false, true)
  legacy_bytes[8] = b'\x02'
  let legacy_lab = IccProfile::parse(legacy_bytes).unwrap()
  let source = Image::from_bytes(
    1,
    1,
    FixedArray::makei(4, i => [b'\x80', b'\x40', b'\x20', b'\xD5'][i]),
  )
  let xyz_result = xyz.apply_rgba8(source).unwrap()
  assert_true(xyz_result.data[0].to_int() > 240)
  assert_true(xyz_result.data[1].to_int() < 20)
  assert_true(xyz_result.data[2].to_int() > 50)
  let lab_result = lab.apply_rgba8(source).unwrap()
  assert_true(lab_result.data[0].to_int() > 250)
  assert_true(lab_result.data[1].to_int() > 250)
  assert_true(lab_result.data[2].to_int() > 250)
  assert_eq(lab_result.data[3], b'\xD5')
  let legacy_result = legacy_lab.apply_rgba8(source).unwrap()
  assert_true(legacy_result.data[0].to_int() > 250)
  assert_true(legacy_result.data[1].to_int() > 250)
  assert_true(legacy_result.data[2].to_int() > 250)
}

///|
test "ICC mft1 LUT parses 8-bit tables and CLUT order" {
  let profile = IccProfile::parse(icc_test_mft1_identity()).unwrap()
  let source = Image::from_bytes(
    1,
    1,
    FixedArray::makei(4, i => [b'\x40', b'\x80', b'\xC0', b'\xEF'][i]),
  )
  let result = profile.apply_rgba8(source).unwrap()
  // LittleCMS relative-colorimetric UInt16 oracle [19999, 18904, 15729].
  assert_eq(result.get_pixel(0, 0), (b'\x4E', b'\x4A', b'\x3D', b'\xEF'))
}

///|
test "ICC rejects malformed and unsupported profiles without indexing" {
  let short = IccProfile::parse([])
  assert_true(short is Err(_))
  let malformed = icc_test_srgb_matrix_profile()
  icc_test_u32(malformed, 136, malformed.length() + 4)
  match IccProfile::parse(malformed) {
    Err(error) => assert_true(error.kind == InvalidData)
    Ok(_) => assert_true(false)
  }
  let unsupported = icc_test_profile(ICC_SIG_PRTR, ICC_SIG_RGB, ICC_SIG_XYZ, [])
  match IccProfile::parse(unsupported) {
    Err(error) => assert_true(error.kind == Unsupported)
    Ok(_) => assert_true(false)
  }
  let mft1_xyz = icc_test_mft1_identity()
  icc_test_sig(mft1_xyz, 20, ICC_SIG_XYZ)
  assert_true(IccProfile::parse(mft1_xyz) is Err(_))
  let mab_v2 = icc_test_mab_identity()
  mab_v2[8] = b'\x02'
  assert_true(IccProfile::parse(mab_v2) is Err(_))
  let profile = IccProfile::parse(icc_test_srgb_matrix_profile()).unwrap()
  let bad : Image = { width: 1, height: 1, data: FixedArray::make(3, b'\x00'), }
  match profile.apply_rgba8(bad) {
    Err(error) => assert_true(error.kind == InvalidBuffer)
    Ok(_) => assert_true(false)
  }
}

///|
test "ICC relative transform selection and resource caps are explicit" {
  let good = icc_test_mft2(false, true)
  let at = icc_u32(good, 136, good.length()).unwrap()
  let size = icc_u32(good, 140, good.length()).unwrap()
  let lut = Array::makei(size, i => good[at + i])
  let bad : Array[Byte] = [b'x', b'x', b'x', b'x', 0, 0, 0, 0]
  let selected = icc_test_profile(ICC_SIG_MNTR, ICC_SIG_RGB, ICC_SIG_LAB, [
    (ICC_SIG_A2B0, bad),
    (ICC_SIG_A2B1, lut),
  ])
  let image = Image::from_bytes(1, 1, [0, 0, 0, 91])
  assert_eq(
    IccProfile::parse(selected)
    .unwrap()
    .apply_rgba8(image)
    .unwrap()
    .get_pixel(0, 0),
    (b'\xFF', b'\xFF', b'\xFF', b'\x5B'),
  )
  let unsupported = icc_test_profile(ICC_SIG_MNTR, ICC_SIG_RGB, ICC_SIG_LAB, [
    (ICC_SIG_A2B0, lut),
    (ICC_SIG_A2B1, bad),
  ])
  assert_eq(demux_test_error(IccProfile::parse(unsupported)), Unsupported)
  let saturation = icc_test_profile(ICC_SIG_MNTR, ICC_SIG_RGB, ICC_SIG_LAB, [
    (ICC_SIG_A2B2, lut),
  ])
  assert_eq(demux_test_error(IccProfile::parse(saturation)), Unsupported)
  let tag_count = icc_test_srgb_matrix_profile()
  icc_test_u32(tag_count, 128, 4097)
  assert_eq(demux_test_error(IccProfile::parse(tag_count)), LimitExceeded)
  let curve = icc_test_sampled([0, 65535])
  icc_test_u32(curve, 8, 65537)
  match icc_parse_curve_at(curve, 0, curve.length()) {
    Err(IccLimit(_)) => ()
    _ => fail("Oversized curve did not stop before allocation")
  }
}

///|
test "ICC policy options use real intent tables and derive BPC without bkpt" {
  let profile = IccProfile::parse(icc_test_mft2(false, true)).unwrap()
  let source : Image16 = {
    width: 1,
    height: 1,
    data: [32768, 16384, 8192, 54321],
  }
  let perceptual = profile.apply_rgba16_with_options(
    source,
    IccTransformOptions::new(Perceptual, false),
  )
  assert_true(perceptual is Ok(_))
  let saturation = profile
    .apply_rgba16_with_options(
      source,
      IccTransformOptions::new(Saturation, false),
    )
    .unwrap()
  assert_eq(saturation.data, perceptual.unwrap().data)
  let compensated = profile
    .apply_rgba16_with_options(
      source,
      IccTransformOptions::new(RelativeColorimetric, true),
    )
    .unwrap()
  assert_eq(compensated.data[3], 54321)
  let source8 = Image::from_bytes(1, 1, [b'\x20', b'\x40', b'\x60', b'\xA5'])
  let output8 = profile
    .apply_rgba8_with_options(
      source8,
      IccTransformOptions::new(RelativeColorimetric, false),
    )
    .unwrap()
  assert_eq(output8.data[3], b'\xA5')
  output8.data[0] = b'\x00'
  assert_eq(source8.data[0], b'\x20')
}

///|
test "ICC optional intent validates channels before evaluation" {
  let rgb_profile = icc_test_mft2(true, false)
  let at = icc_u32(rgb_profile, 136, rgb_profile.length()).unwrap()
  let size = icc_u32(rgb_profile, 140, rgb_profile.length()).unwrap()
  let lut = Array::makei(size, i => rgb_profile[at + i])
  let gray_profile = icc_test_profile(ICC_SIG_MNTR, ICC_SIG_GRAY, ICC_SIG_XYZ, [
    (ICC_SIG_WTPT, icc_test_xyz(0.9642, 1.0, 0.8249)),
    (ICC_SIG_KTRC, icc_test_gamma(1.0)),
    (ICC_SIG_A2B2, lut),
  ])
  let parsed = IccProfile::parse(gray_profile).unwrap()
  let source : Image16 = { width: 1, height: 1, data: [0, 0, 0, 65535], }
  match
    parsed.apply_rgba16_with_options(
      source,
      IccTransformOptions::new(Saturation, false),
    ) {
    Err(error) => assert_eq(error.kind, Unsupported)
    Ok(_) => fail("three-input LUT was accepted for Gray")
  }
}
