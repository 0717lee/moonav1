///|
test "CfL uses reconstructed inter neighbours in a shared 8x8 luma group" {
  for variant in 0..<6 {
    let depth = [8, 10, 12][variant % 3]
    let scale = 1 << (depth - 8)
    let state = av1_intra_state(8, 8, 32, depth, false, false, false, false)
    let luma = Array::makei(64, i => (3 + i % 8 * 5 + i / 8 * 9) * scale)
    for i in 0..<64 {
      state.planes[0].pixels[i] = luma[i]
    }
    let decoder = av1_msac_new([b'\x00', b'\x00'], true)
    // Three motion-compensated 4x4 neighbours precede an intra CfL owner.
    for position in [(0, 0), (4, 0), (0, 4)] {
      let (x, y) = position
      let tile : Av1SbBlock = { row: y, col: x, width: 4, height: 4, }
      let block = av1_inter_block(
        y / 4,
        x / 4,
        1,
        1,
        av1_intra_block_index(4, 4).unwrap(),
        y > 0,
        x > 0,
      )
      block.skip = 1
      assert_true(
        if variant < 3 {
          av1_inter_residual(decoder, state, block, tile, 4, 4, [])
        } else {
          av1_intrabc_residual(decoder, state, block, tile, 4, 4, [])
        },
      )
    }
    av1_cfl_begin_block(
      state.cfl,
      { row: 4, col: 4, width: 4, height: 4, },
      true,
    )
    assert_true(
      av1_cfl_store_tx(
        state.cfl,
        4,
        4,
        4,
        4,
        Array::makei(16, i => luma[(4 + i / 4) * 8 + 4 + i % 4]),
      ),
    )
    let prediction = Array::make(16, 128 * scale)
    assert_true(av1_cfl_predict(state.cfl, prediction, 4, 4, -3, depth))
    // Independent whole-footprint mean: Q3 of this linear 8x8 source is
    // 8*(3+7/2*5+7/2*9)*scale = 416*scale.
    for y in 0..<4 {
      for x in 0..<4 {
        let q3 = (10 + x * 10 + y * 18) * 8 * scale
        let product = -3 * (q3 - 416 * scale)
        let magnitude = (product.abs() + 32) / 64
        let expected = 128 * scale +
          (if product < 0 { -magnitude } else { magnitude })
        assert_eq(prediction[y * 4 + x], expected)
      }
    }
  }
}

///|
test "motion variation eligibility follows odd-MI overlappable neighbours" {
  for vertical in [false, true] {
    let info = av1_inter_regression_info()
    let block = av1_inter_block(2, 2, 2, 2, 3, vertical, !vertical)
    block.ref_frame = av1_last_frame
    let (row, col) = if vertical { (1, 2) } else { (2, 1) }
    av1_motion_field_store(
      info.field,
      row,
      col,
      1,
      1,
      13,
      [av1_last_frame, av1_none_frame],
      [0, 0],
      [0, 0],
    )
    assert_false(av1_has_overlappable_candidates(info.field, block))
    let decoder = av1_msac_new([b'\x00', b'\x00'], true)
    let before = (decoder.bit_pos, decoder.symbol_range)
    assert_true(av1_read_motion_mode(decoder, info, block))
    assert_eq((decoder.bit_pos, decoder.symbol_range), before)
    assert_eq(block.motion_mode, 0)
    let (next_row, next_col) = if vertical { (1, 3) } else { (3, 1) }
    av1_motion_field_store(
      info.field,
      next_row,
      next_col,
      1,
      1,
      13,
      [av1_last_frame, av1_none_frame],
      [0, 0],
      [0, 0],
    )
    assert_true(av1_has_overlappable_candidates(info.field, block))
  }
}

///|
test "sub-eight inter chroma uses owner vector when any shared neighbour is intra" {
  let state = av1_intra_state(32, 32, 100, 8, false, false, false, false)
  let info = av1_inter_regression_info()
  let block = av1_inter_block(3, 3, 1, 1, 0, true, true)
  block.ref_frame = av1_last_frame
  block.mv_col = 16
  av1_motion_field_store(
    info.field,
    3,
    3,
    1,
    1,
    block.y_mode,
    [av1_last_frame, av1_none_frame],
    [0, 0],
    [16, 0],
    interp=[0, 0],
  )
  // Two different inter neighbours, plus one intra neighbour. The whole
  // chroma group must use the owner, not a per-quadrant mixture.
  for pos in [(2, 2), (2, 3)] {
    let (row, col) = pos
    av1_motion_field_store(
      info.field,
      row,
      col,
      1,
      1,
      block.y_mode,
      [av1_last_frame, av1_none_frame],
      [0, 0],
      [-16, 0],
      interp=[0, 0],
    )
  }
  assert_true(
    av1_inter_predict(state, info, block, {
      row: 12,
      col: 12,
      width: 4,
      height: 4,
    }),
  )
  for plane in [1, 2] {
    let expected = av1_motion_compensate({
      reference: info.refs[av1_last_frame].unwrap(),
      frame_width: 32,
      frame_height: 32,
      plane,
      x: 4,
      y: 4,
      width: 4,
      height: 4,
      mv_row: 0,
      mv_col: 16,
      filter_vertical: 0,
      filter_horizontal: 0,
      compound: false,
    })
    for y in 0..<4 {
      for x in 0..<4 {
        assert_eq(
          state.planes[plane].pixels[(4 + y) * 16 + 4 + x],
          expected[y * 4 + x],
        )
      }
    }
  }
}
