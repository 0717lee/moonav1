/// Regression for the 1080p reordered stream: compound spatial candidates
/// from GLOBAL_GLOBALMV neighbours use the current block's global vectors.
/// The two centres differ under affine/rotzoom motion (AV1 7.10.2.5).

///|
fn compound_global_test_block() -> Av1MvBlock {
  {
    mi_row: 8,
    mi_col: 16,
    width4: 8,
    height4: 8,
    block_width: 32,
    block_height: 32,
    refs: [1, 5],
    tile_row_start: 0,
    tile_row_end: 24,
    tile_col_start: 0,
    tile_col_end: 32,
  }
}

///|
test "translation global motion respects forced integer precision" {
  let block = compound_global_test_block()
  let frame = av1_mv_test_frame(false, 1)
  frame.gm_type[1] = av1_gm_translation
  frame.gm_params[1] = [3 << 14, -5 << 14, 65536, 0, 0, 65536]
  // Translation syntax yields (6, -10) eighth-pel. Integer-only motion
  // lowers that to (8, -8), including when used directly by GLOBALMV.
  // dav1d 1.2.1 env.h get_gmv_2d also calls fix_int_mv_precision here.
  assert_eq(av1_setup_global_mv(0, block, frame), (8, -8))
  let fractional = av1_mv_test_frame(false, 0)
  fractional.gm_type[1] = av1_gm_translation
  fractional.gm_params[1] = frame.gm_params[1]
  assert_eq(av1_setup_global_mv(0, block, fractional), (6, -10))
}

///|
test "compound global candidate evaluates both models at current centre" {
  let frame = av1_mv_test_frame(true, 0)
  frame.gm_type[1] = av1_gm_rot_zoom
  frame.gm_params[1] = [0, 0, 65536, 4096, -4096, 65536]
  frame.gm_type[5] = av1_gm_affine
  frame.gm_params[5] = [0, 0, 73728, 0, 0, 69632]
  let field = av1_motion_field(32, 24)
  // The neighbour centre is (79, 15), the current centre is (79, 47).
  // In eighth-pel units the models are (-x/2, y/2) and (y/2, x).
  av1_motion_field_store(
    field,
    0,
    16,
    8,
    8,
    av1_mode_global_global_mv,
    [1, 5],
    [-40, 8],
    [8, 79],
  )
  let stack = av1_find_mv_stack(
    field,
    compound_global_test_block(),
    frame,
    true,
  ).unwrap()
  assert_eq(av1_stack_mv(stack, 0, 0), (-40, 24))
  assert_eq(av1_stack_mv(stack, 0, 1), (24, 79))
  assert_eq(stack.newmv_count, 0)
}

///|
test "compound global candidates substitute each reference independently" {
  let block = compound_global_test_block()
  for affine_list in 0..<2 {
    let frame = av1_mv_test_frame(false, 0)
    frame.gm_type[block.refs[affine_list]] = av1_gm_affine
    frame.gm_type[block.refs[1 - affine_list]] = av1_gm_translation
    let field = av1_motion_field(32, 24)
    av1_motion_field_store(
      field,
      0,
      16,
      8,
      8,
      av1_mode_global_global_mv,
      [1, 5],
      [11, -13],
      [15, -17],
    )
    let stack = av1_mv_stack_new()
    stack.global_rows[0] = 31
    stack.global_cols[0] = -33
    stack.global_rows[1] = -35
    stack.global_cols[1] = 37
    av1_add_ref_mv_candidate(field, stack, block, frame, 7, 16, true, 4)
    assert_eq(
      av1_stack_mv(stack, 0, 0),
      if affine_list == 0 {
        (30, -32)
      } else {
        (10, 14)
      },
    )
    assert_eq(
      av1_stack_mv(stack, 0, 1),
      if affine_list == 1 {
        (-34, 36)
      } else {
        (-12, -16)
      },
    )
  }
}

///|
test "compound global candidates merge after current-centre substitution" {
  let block = compound_global_test_block()
  let frame = av1_mv_test_frame(true, 0)
  frame.gm_type[1] = av1_gm_rot_zoom
  frame.gm_type[5] = av1_gm_affine
  let field = av1_motion_field(32, 24)
  av1_motion_field_store(
    field,
    0,
    16,
    8,
    8,
    av1_mode_global_global_mv,
    [1, 5],
    [11, -13],
    [15, -17],
  )
  av1_motion_field_store(
    field,
    8,
    8,
    8,
    8,
    av1_mode_global_global_mv,
    [1, 5],
    [21, -23],
    [25, -27],
  )
  let stack = av1_mv_stack_new()
  stack.global_rows[0] = 31
  stack.global_cols[0] = -33
  stack.global_rows[1] = -35
  stack.global_cols[1] = 37
  av1_add_ref_mv_candidate(field, stack, block, frame, 7, 16, true, 4)
  av1_add_ref_mv_candidate(field, stack, block, frame, 8, 15, true, 6)
  assert_eq(stack.count, 1)
  assert_eq(stack.weights[0], 10)
  assert_eq(stack.found_match, 1)
  assert_eq(stack.newmv_count, 0)
  assert_eq(av1_stack_mv(stack, 0, 0), (31, -33))
  assert_eq(av1_stack_mv(stack, 0, 1), (-35, 37))
}

///|
test "compound spatial candidates preserve nonglobal and small neighbours" {
  let block = compound_global_test_block()
  let frame = av1_mv_test_frame(false, 1)
  frame.gm_type[1] = av1_gm_affine
  frame.gm_type[5] = av1_gm_affine
  for
    neighbour in [
      (av1_mode_new_new_mv, 8, 8),
      (av1_mode_global_global_mv, 1, 2),
      (av1_mode_global_global_mv, 2, 1),
    ] {
    let (mode, width4, height4) = neighbour
    let field = av1_motion_field(32, 24)
    av1_motion_field_store(
      field,
      0,
      16,
      width4,
      height4,
      mode,
      [1, 5],
      [13, -13],
      [17, -17],
    )
    let stack = av1_mv_stack_new()
    av1_add_ref_mv_candidate(field, stack, block, frame, 0, 16, true, 4)
    assert_eq(av1_stack_mv(stack, 0, 0), (16, 16))
    assert_eq(av1_stack_mv(stack, 0, 1), (-16, -16))
    assert_eq(
      stack.newmv_count,
      if mode == av1_mode_new_new_mv {
        1
      } else {
        0
      },
    )
  }
}
