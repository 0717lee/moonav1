///|
test "RGBA16 limited alpha keeps low native bits" {
  let color = av1_frame_to_native(
    avif_alpha_precision_frame(12, true, 2, [
      [1024, 1024, 1024, 1024, 1024, 1024],
    ]),
  )
  let alpha = av1_frame_to_native(
    avif_alpha_precision_frame(12, false, 2, [[0, 256, 263, 264, 3760, 4095]]),
  )
  let image : AvifNativeImage = {
    color,
    alpha: Some(alpha),
    premultiplied: false,
  }
  let rgba = image.to_rgba16().unwrap()
  // Limited12 expands 263/264 to 8/9. UNORM16 preserves them as 128/144;
  // narrowing alpha to eight bits first would instead produce 0/257.
  let expected = [0, 0, 128, 144, 65535, 65535]
  for i in 0..<6 {
    for c in 0..<3 {
      assert_eq(rgba.data[i * 4 + c].to_int(), 16388)
    }
    assert_eq(rgba.data[i * 4 + 3].to_int(), expected[i])
  }
  assert_eq(alpha.planes[0].data[2], 263)
}

///|
test "RGBA16 unpremultiplies before RGB integer quantization" {
  // BT.601 full range: B=2*(1-0.114)/4095, alpha=25/4095.
  // Exact B16=round(1.772/25*65535)=4645. An RGB16-first pipeline gives 4587.
  let color = av1_frame_to_native(
    avif_alpha_precision_frame(12, true, 6, [[0], [2049], [2048]]),
  )
  let alpha = av1_frame_to_native(
    avif_alpha_precision_frame(12, true, 2, [[25]]),
  )
  let image : AvifNativeImage = {
    color,
    alpha: Some(alpha),
    premultiplied: true,
  }
  let result = image.to_rgba16().unwrap()
  assert_eq(result.data.map(x => x.to_int()), [0, 0, 4645, 400])
}

///|
test "RGBA16 zero alpha and output ownership" {
  let color = av1_frame_to_native(
    avif_alpha_precision_frame(12, true, 0, [[0, 0], [1, 0], [1, 1]]),
  )
  let alpha = av1_frame_to_native(
    avif_alpha_precision_frame(12, true, 2, [[1, 0]]),
  )
  let prem : AvifNativeImage = {
    color,
    alpha: Some(alpha),
    premultiplied: true,
  }
  let straight = AvifNativeImage::{ ..prem, premultiplied: false, }
  let a = prem.to_rgba16().unwrap()
  let b = prem.to_rgba16().unwrap()
  assert_eq(a.data.map(x => x.to_int()), [65535, 0, 65535, 16, 0, 0, 0, 0])
  assert_eq(straight.to_rgba16().unwrap().data[4].to_int(), 16)
  a.data[0] = 0
  assert_eq(b.data[0].to_int(), 65535)
  assert_eq(color.planes[2].data[0], 1)
  alpha.planes[0].data[0] = 0
  assert_eq(b.data[3].to_int(), 16)
}

///|
test "RGBA16 rejects edited planes and unsupported metadata" {
  let color = av1_frame_to_native(
    avif_alpha_precision_frame(10, true, 6, [[100], [512], [512]]),
  )
  assert_true(color.to_rgba16() is Some(_))
  color.planes[0].data[0] = 1024
  assert_true(color.to_rgba16() is None)
  color.planes[0].data[0] = -1
  assert_true(color.to_rgba16() is None)
  color.planes[0].data[0] = 100
  let bad_matrix : Av1NativeFrame = { ..color, matrix_coefficients: 3, }
  assert_true(bad_matrix.to_rgba16() is None)
  let bad_transfer : Av1NativeFrame = {
    ..color,
    matrix_coefficients: 14,
    transfer_characteristics: 2,
  }
  assert_true(bad_transfer.to_rgba16() is None)
  let wrong_depth = av1_frame_to_native(
    avif_alpha_precision_frame(12, true, 2, [[1]]),
  )
  let mismatch : AvifNativeImage = {
    color,
    alpha: Some(wrong_depth),
    premultiplied: false,
  }
  assert_true(mismatch.to_rgba16() is None)
  let wide = av1_frame_to_native(
    avif_alpha_precision_frame(10, true, 2, [[1, 2]]),
  )
  color.planes[1] = wide.planes[0]
  assert_true(color.to_rgba16() is None)
  assert_true(av1_decode_rgba16([]) is None)
  assert_true(avif_decode_rgba16([]) is None)
}

///|
test "RGBA16 nearest chroma crosses odd row boundaries" {
  // With full-range YCgCo, Y=128 and Co=128, the integer RGB values
  // are (256-Cg, Cg, 256-Cg). Eight-bit samples scale exactly by 257.
  let layouts = [
    (
      true,
      true,
      2,
      2,
      [128, 129, 130, 131],
      [128, 128, 129, 128, 128, 129, 130, 130, 131],
    ),
    (
      true,
      false,
      2,
      3,
      [128, 129, 130, 131, 132, 133],
      [128, 128, 129, 130, 130, 131, 132, 132, 133],
    ),
    (
      false,
      false,
      3,
      3,
      [128, 129, 130, 131, 132, 133, 134, 135, 136],
      [128, 129, 130, 131, 132, 133, 134, 135, 136],
    ),
  ]
  for layout in layouts {
    let (sx, sy, cw, ch, cg, expected) = layout
    let frame : Av1NativeFrame = {
      width: 3,
      height: 3,
      bit_depth: 8,
      subsampling_x: sx,
      subsampling_y: sy,
      full_range: true,
      matrix_coefficients: 8,
      color_primaries: 1,
      transfer_characteristics: 13,
      planes: [
        { width: 3, height: 3, data: FixedArray::make(9, 128), },
        { width: cw, height: ch, data: FixedArray::makei(cw * ch, i => cg[i]), },
        { width: cw, height: ch, data: FixedArray::make(cw * ch, 128), },
      ],
    }
    let rgba = frame.to_rgba16().unwrap()
    for i in 0..<9 {
      assert_eq(rgba.data[i * 4].to_int(), (256 - expected[i]) * 257)
      assert_eq(rgba.data[i * 4 + 1].to_int(), expected[i] * 257)
      assert_eq(rgba.data[i * 4 + 2].to_int(), (256 - expected[i]) * 257)
      assert_eq(rgba.data[i * 4 + 3].to_int(), 65535)
    }
  }
}
