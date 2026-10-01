///|
fn av1_loop_filter_frame_test_config(
  levels : Array[Int],
) -> Av1LoopFilterConfig {
  {
    levels,
    sharpness: 0,
    delta_enabled: false,
    ref_deltas: [1, 0, 0, 0, -1, 0, -1, -1],
    mode_deltas: [0, 0],
  }
}

///|
/// Expected pixels come from unmodified pinned AOM aom_dsp/loopfilter.c.
/// Explicit C calls: vertical4 at (4,0),(4,4), then horizontal4 at (0,4),(4,4).
/// The 5x5 visible crop retains all four lanes into its 8x8 MI padding.
test "loop filter frame matches original C crossing edges at every bit depth" {
  let expected = [
    [
      100, 100, 102, 103, 105, 106, 108, 108, 100, 101, 102, 106, 109, 108, 109,
      110, 101, 102, 104, 105, 109, 109, 110, 112, 102, 105, 104, 107, 110, 109,
      113, 112, 104, 108, 108, 109, 111, 110, 116, 114, 105, 106, 108, 108, 110,
      111, 114, 114, 106, 107, 108, 112, 115, 114, 115, 116, 106, 108, 110, 110,
      114, 114, 116, 118,
    ],
    [
      400, 400, 406, 412, 420, 426, 432, 432, 400, 401, 408, 415, 424, 426, 433,
      434, 405, 407, 416, 419, 426, 430, 439, 441, 409, 412, 417, 424, 431, 435,
      444, 443, 415, 419, 423, 429, 437, 441, 451, 449, 419, 419, 425, 431, 440,
      445, 451, 451, 424, 425, 432, 439, 448, 450, 457, 458, 424, 426, 435, 438,
      446, 449, 458, 460,
    ],
    [
      1600, 1600, 1624, 1648, 1680, 1704, 1728, 1728, 1600, 1601, 1626, 1651, 1684,
      1704, 1729, 1730, 1618, 1620, 1648, 1668, 1700, 1721, 1748, 1751, 1636, 1639,
      1662, 1687, 1718, 1740, 1767, 1766, 1660, 1664, 1686, 1710, 1742, 1764, 1792,
      1790, 1678, 1678, 1701, 1726, 1758, 1782, 1806, 1805, 1696, 1697, 1722, 1747,
      1780, 1800, 1825, 1826, 1696, 1698, 1725, 1746, 1778, 1799, 1826, 1828,
    ],
  ]
  for case in 0..<3 {
    let bit_depth = 8 + 2 * case
    let scale = 1 << (bit_depth - 8)
    let pixels = Array::makei(64, i => {
      let x = i % 8
      let y = i / 8
      (100 + (if x >= 4 { 8 } else { 0 }) + (if y >= 4 { 6 } else { 0 })) *
      scale +
      x * y % 5
    })
    assert_true(
      av1_loop_filter_frame(
        av1_loop_filter_frame_test_config([32, 32, 0, 0]),
        5,
        5,
        8,
        8,
        bit_depth,
        [pixels],
        [Array::make(4, 4 | (4 << 8))],
      ),
    )
    assert_eq(pixels, expected[case])
  }
}

///|
/// C invokes only horizontal4 at (0,4): x=4 is outside the visible width.
test "loop filter frame excludes invisible edge origins but keeps full lanes" {
  let pixels = Array::makei(64, i => {
    let x = i % 8
    let y = i / 8
    100 +
    (if x >= 4 { 8 } else { 0 }) +
    (if y >= 4 { 6 } else { 0 }) +
    x * y % 5
  })
  assert_true(
    av1_loop_filter_frame(
      av1_loop_filter_frame_test_config([32, 32, 0, 0]),
      4,
      5,
      8,
      8,
      8,
      [pixels],
      [Array::make(4, 4 | (4 << 8))],
    ),
  )
  assert_eq(pixels, [
    100, 100, 100, 100, 108, 108, 108, 108, 100, 101, 102, 103, 112, 108, 109, 110,
    101, 102, 104, 101, 111, 108, 110, 112, 102, 105, 104, 105, 110, 108, 111, 109,
    104, 108, 106, 107, 115, 114, 118, 117, 105, 106, 106, 106, 114, 114, 114, 114,
    106, 107, 108, 109, 118, 114, 115, 116, 106, 108, 110, 107, 117, 114, 116, 118,
  ])
}

///|
/// C vertical rows: mixed4/8 uses width4 at x4,x8; uniform8 uses width8
/// at x8; TX16x8 uses width14 at x16. No internal x12/x20 edges exist.
test "loop filter frame uses adjacent normal TX dimensions and real boundaries" {
  let expected_rows = [
    [
      100, 100, 101, 101, 102, 103, 105, 105, 106, 107, 108, 108, 108, 108, 108,
      108,
    ],
    [
      100, 100, 100, 100, 100, 101, 102, 103, 105, 106, 107, 108, 108, 108, 108,
      108,
    ],
    [
      100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 101, 101, 102, 102, 103,
      104, 105, 106, 106, 107, 107, 108, 108, 108, 108, 108, 108, 108, 108, 108,
      108, 108,
    ],
  ]
  for case in 0..<3 {
    let width = if case == 2 { 32 } else { 16 }
    let pixels = Array::makei(width * 8, i => {
      let x = i % width
      if case == 0 {
        100 + (if x >= 4 { 4 } else { 0 }) + (if x >= 8 { 4 } else { 0 })
      } else {
        100 + (if x >= width / 2 { 8 } else { 0 })
      }
    })
    let map = Array::makei(width / 4 * 2, i => {
      let tx_width = if case == 0 && i % (width / 4) < 2 {
        4
      } else {
        width / 2
      }
      tx_width | (8 << 8)
    })
    assert_true(
      av1_loop_filter_frame(
        av1_loop_filter_frame_test_config([32, 32, 0, 0]),
        width,
        8,
        width,
        8,
        8,
        [pixels],
        [map],
      ),
    )
    assert_eq(
      pixels,
      Array::makei(width * 8, i => expected_rows[case][i % width]),
    )
  }
}

///|
test "loop filter frame chroma selects six taps and independent plane levels" {
  let y = Array::make(32 * 16, 128)
  let u = Array::makei(16 * 8, i => if i % 16 < 8 { 100 } else { 108 })
  let v = u.copy()
  let before_v = v.copy()
  assert_true(
    av1_loop_filter_frame(
      av1_loop_filter_frame_test_config([32, 0, 32, 0]),
      32,
      16,
      32,
      16,
      8,
      [y, u, v],
      [
        Array::make(32, 16 | (8 << 8)),
        Array::make(8, 8 | (4 << 8)),
        Array::make(8, 8 | (4 << 8)),
      ],
    ),
  )
  // Original C vertical6 at (8,0) and (8,4).
  let row = [
    100, 100, 100, 100, 100, 100, 101, 103, 105, 107, 108, 108, 108, 108, 108, 108,
  ]
  assert_eq(u, Array::makei(128, i => row[i % 16]))
  assert_eq(v, before_v)
  assert_eq(y, Array::make(512, 128))
}

///|
test "loop filter TX metadata is optional and includes skipped clipped transforms" {
  let disabled = av1_intra_state(8, 8, 32, 8, false, false, false, false)
  for plane in disabled.planes {
    assert_eq(plane.tx_sizes, [])
  }
  let state = av1_intra_state(
    8,
    8,
    32,
    8,
    false,
    false,
    false,
    false,
    track_loop_filter=true,
  )
  let decoder = av1_msac_new(Array::make(8, b'\xff'), true)
  assert_true(
    av1_intra_transform(decoder, state, 0, AV1_INTRA_DC, 0, 0, 16, 8, 16, 8, 1),
  )
  assert_eq(state.planes[0].tx_sizes, Array::make(4, 16 | (8 << 8)))
  assert_eq(state.planes[1].tx_sizes, [0])
  // All-zero txb_skip also records the actual geometry when block skip is 0.
  assert_true(
    av1_intra_transform(decoder, state, 1, AV1_INTRA_DC, 0, 0, 4, 4, 4, 4, 0),
  )
  assert_eq(state.planes[1].tx_sizes, [4 | (4 << 8)])
  assert_eq(state.planes[1].above_level, [0])
}

///|
test "loop filter TX metadata follows sub8 chroma owners and SELECT rectangles" {
  let state = av1_intra_state(
    8,
    8,
    32,
    8,
    false,
    false,
    false,
    false,
    track_loop_filter=true,
  )
  let decoder = av1_msac_new(Array::make(8, b'\x00'), true)
  for row in 0..<2 {
    for col in 0..<2 {
      assert_true(
        av1_intra_residuals(
          decoder,
          state,
          { row: row * 4, col: col * 4, width: 4, height: 4, },
          AV1_INTRA_DC,
          AV1_INTRA_DC,
          4,
          4,
          1,
        ),
      )
      assert_eq(state.planes[1].tx_sizes, [
        if row == 1 && col == 1 {
          4 | (4 << 8)
        } else {
          0
        },
      ])
    }
  }
  assert_eq(state.planes[0].tx_sizes, Array::make(4, 4 | (4 << 8)))
  assert_eq(state.planes[2].tx_sizes, [4 | (4 << 8)])
  let rectangle = av1_intra_state(
    32,
    8,
    32,
    8,
    false,
    false,
    false,
    true,
    track_loop_filter=true,
  )
  assert_true(
    av1_intra_residuals(
      decoder,
      rectangle,
      { row: 0, col: 0, width: 32, height: 8, },
      AV1_INTRA_DC,
      AV1_INTRA_DC,
      8,
      4,
      1,
    ),
  )
  assert_eq(rectangle.planes[0].tx_sizes, Array::make(16, 8 | (4 << 8)))
  for plane in 1..<3 {
    assert_eq(rectangle.planes[plane].tx_sizes, Array::make(4, 16 | (4 << 8)))
  }
}

///|
test "loop filter frame validates all map geometry before changing pixels" {
  for invalid in [0, 3 | (4 << 8), 64 | (4 << 8), 128 | (128 << 8)] {
    let pixels = Array::makei(64, i => if i % 8 < 4 { 100 } else { 108 })
    let before = pixels.copy()
    assert_false(
      av1_loop_filter_frame(
        av1_loop_filter_frame_test_config([32, 32, 0, 0]),
        8,
        8,
        8,
        8,
        8,
        [pixels],
        [[4 | (4 << 8), 4 | (4 << 8), 4 | (4 << 8), invalid]],
      ),
    )
    assert_eq(pixels, before)
  }
}

///|
/// A skipped 128x128 inter prediction has no residual at its internal maximum
/// TX boundaries (64 luma, 32 chroma). These sample steps must remain intact.
test "loop filter preserves internal edges of skipped inter blocks" {
  for depth in [8, 10, 12] {
    for sampling in [(1, 1), (1, 0), (0, 0)] {
      for direction in 0..<2 {
        let (sx, sy) = sampling
        let field = av1_motion_field(32, 32)
        av1_motion_field_store(
          field,
          0,
          0,
          32,
          32,
          av1_mode_nearest_mv,
          [1, -1],
          [0, 0],
          [0, 0],
          skip=1,
        )
        let planes = Array::makei(3, plane => {
          let width = 128 >> (if plane == 0 { 0 } else { sx })
          let height = 128 >> (if plane == 0 { 0 } else { sy })
          let edge = if plane == 0 { 64 } else { 32 }
          Array::makei(width * height, i => {
            let normal = if direction == 0 { i % width } else { i / width }
            (100 + (if normal >= edge { 8 } else { 0 })) << (depth - 8)
          })
        })
        let before = planes.map(p => p.copy())
        let maps = Array::makei(3, plane => {
          let width = 128 >> (if plane == 0 { 0 } else { sx })
          let height = 128 >> (if plane == 0 { 0 } else { sy })
          let tx = if plane == 0 { 64 } else { 32 }
          Array::make(width / 4 * (height / 4), tx | (tx << 8))
        })
        assert_true(
          av1_loop_filter_frame(
            av1_loop_filter_frame_test_config([32, 32, 32, 32]),
            128,
            128,
            128,
            128,
            depth,
            planes,
            maps,
            sub_x=sx,
            sub_y=sy,
            field=Some(field),
          ),
        )
        assert_eq(planes, before)
      }
    }
  }
}

///|
/// Equal motion/reference/skip state on two adjacent 64x64 predictions must
/// not erase their coding boundary. Only internal chroma TX edges are skipped.
test "loop filter retains boundaries between identical skipped inter blocks" {
  for direction in 0..<2 {
    let width = if direction == 0 { 128 } else { 64 }
    let height = if direction == 0 { 64 } else { 128 }
    let field = av1_motion_field(width / 4, height / 4)
    for block in 0..<2 {
      av1_motion_field_store(
        field,
        if direction == 0 {
          0
        } else {
          block * 16
        },
        if direction == 0 {
          block * 16
        } else {
          0
        },
        16,
        16,
        av1_mode_nearest_mv,
        [1, -1],
        [0, 0],
        [0, 0],
        skip=1,
      )
    }
    let uv = Array::makei(width * height, i => {
      let normal = if direction == 0 { i % width } else { i / width }
      100 + normal / 32 * 4
    })
    let before = uv.copy()
    let planes = [Array::make(width * height, 128), uv, uv.copy()]
    assert_true(
      av1_loop_filter_frame(
        av1_loop_filter_frame_test_config([32, 32, 32, 32]),
        width,
        height,
        width,
        height,
        8,
        planes,
        [
          Array::make(width * height / 16, 64 | (64 << 8)),
          Array::make(width * height / 16, 32 | (32 << 8)),
          Array::make(width * height / 16, 32 | (32 << 8)),
        ],
        sub_x=0,
        sub_y=0,
        field=Some(field),
      ),
    )
    for i in 0..<uv.length() {
      let normal = if direction == 0 { i % width } else { i / width }
      if normal < 61 || normal > 66 {
        assert_eq(uv[i], before[i])
      }
      if normal == 63 {
        assert_true(uv[i] > before[i])
      }
      if normal == 64 {
        assert_true(uv[i] < before[i])
      }
    }
  }
}

///|
test "loop filter keeps internal edges for intra skip and inter residuals" {
  for intra in [true, false] {
    for direction in 0..<2 {
      let field = av1_motion_field(16, 16)
      av1_motion_field_store(
        field,
        0,
        0,
        16,
        16,
        if intra {
          AV1_INTRA_DC
        } else {
          av1_mode_nearest_mv
        },
        [if intra { 0 } else { 1 }, -1],
        [0, 0],
        [0, 0],
        skip=if intra { 1 } else { 0 },
      )
      let uv = Array::makei(64 * 64, i => {
        let normal = if direction == 0 { i % 64 } else { i / 64 }
        if normal < 32 {
          100
        } else {
          108
        }
      })
      let before = uv.copy()
      assert_true(
        av1_loop_filter_frame(
          av1_loop_filter_frame_test_config([32, 32, 32, 32]),
          64,
          64,
          64,
          64,
          8,
          [Array::make(64 * 64, 128), uv, uv.copy()],
          [
            Array::make(256, 64 | (64 << 8)),
            Array::make(256, 32 | (32 << 8)),
            Array::make(256, 32 | (32 << 8)),
          ],
          sub_x=0,
          sub_y=0,
          field=Some(field),
        ),
      )
      let left = if direction == 0 { 31 } else { 31 * 64 }
      let right = if direction == 0 { 32 } else { 32 * 64 }
      assert_true(uv[left] > before[left])
      assert_true(uv[right] < before[right])
    }
  }
}
