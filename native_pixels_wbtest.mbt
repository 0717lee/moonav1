///|
test "native export crops odd and aligned planes at every depth" {
  for depth in [8, 10, 12] {
    for sampling in [(0, 0), (1, 0), (1, 1)] {
      let (sub_x, sub_y) = sampling
      for count in [1, 3] {
        for width in [1, 3, 5, 8, 9, 16] {
          for height in [1, 3, 8, 9] {
            let coded_width = (width + 7) / 8 * 8
            let coded_height = (height + 7) / 8 * 8
            let frame : Av1FramePlanes = {
              width,
              height,
              coded_width,
              bit_depth: depth,
              sub_x,
              sub_y,
              full_range: false,
              matrix_coefficients: 1,
              color_primaries: 9,
              transfer_characteristics: 16,
              planes: Array::makei(count, p => {
                let dx = if p == 0 { 1 } else { 1 << sub_x }
                let dy = if p == 0 { 1 } else { 1 << sub_y }
                Array::makei(coded_width / dx * (coded_height / dy), i => {
                  if i % (coded_width / dx) >= (width + dx - 1) / dx ||
                    i / (coded_width / dx) >= (height + dy - 1) / dy {
                    -1 // Poison right and bottom padding; never a visible sample.
                  } else {
                    (i * 17 + p * 31) % (1 << depth)
                  }
                })
              }),
            }
            let native = av1_frame_to_native(frame)
            assert_eq(
              (native.width, native.height, native.bit_depth),
              (width, height, depth),
            )
            assert_eq(
              (
                native.color_primaries,
                native.transfer_characteristics,
                native.matrix_coefficients,
              ),
              (9, 16, 1),
            )
            assert_eq(
              (native.subsampling_x, native.subsampling_y),
              (sub_x == 1, sub_y == 1),
            )
            assert_eq(native.planes.length(), count)
            for p in 0..<count {
              let (dx, dy) = if p == 0 {
                (1, 1)
              } else {
                (1 << sub_x, 1 << sub_y)
              }
              let expected_width = (width + dx - 1) / dx
              let expected_height = (height + dy - 1) / dy
              let expected_length = expected_width * expected_height
              let stride = coded_width / dx
              assert_eq(
                (
                  native.planes[p].width,
                  native.planes[p].height,
                  native.planes[p].data.length(),
                ),
                (expected_width, expected_height, expected_length),
              )
              for y in 0..<expected_height {
                for x in 0..<expected_width {
                  let source_index = y * stride + x
                  let expected = (source_index * 17 + p * 31) % (1 << depth)
                  let actual = native.planes[p].data[y * expected_width + x]
                  assert_eq(actual, expected)
                  assert_true(actual >= 0)
                }
              }
            }
          }
        }
      }
    }
  }
}

///|
test "native export owns buffers on contiguous and cropped paths" {
  for width in [7, 8] {
    let frame : Av1FramePlanes = {
      width,
      height: 3,
      coded_width: 8,
      bit_depth: 12,
      sub_x: 1,
      sub_y: 1,
      full_range: true,
      matrix_coefficients: 0,
      color_primaries: 1,
      transfer_characteristics: 13,
      planes: [
        Array::make(64, 1025),
        Array::make(16, 2049),
        Array::make(16, 3073),
      ],
    }
    let first = av1_frame_to_native(frame)
    let second = av1_frame_to_native(frame)
    first.planes[0].data[0] = 0
    first.planes[1].data[0] = 1
    frame.planes[2][0] = 2
    assert_eq(second.planes[0].data[0], 1025)
    assert_eq(frame.planes[0][0], 1025)
    assert_eq(second.planes[1].data[0], 2049)
    assert_eq(frame.planes[1][0], 2049)
    assert_eq(first.planes[2].data[0], 3073)
    assert_eq(second.planes[2].data[0], 3073)
  }
}
