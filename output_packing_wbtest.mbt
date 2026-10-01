///|
test "native packing preserves every depth endian alignment and odd chroma" {
  for depth in [8, 10, 12] {
    let frame : Av1NativeFrame = {
      width: 9,
      height: 7,
      bit_depth: depth,
      subsampling_x: true,
      subsampling_y: true,
      full_range: false,
      matrix_coefficients: 1,
      color_primaries: 2,
      transfer_characteristics: 2,
      planes: FixedArray::makei(3, p => {
        let width = if p == 0 { 9 } else { 5 }
        let height = if p == 0 { 7 } else { 4 }
        {
          width,
          height,
          data: FixedArray::makei(width * height, i => {
            (i * 997 + p * 611) & ((1 << depth) - 1)
          }),
        }
      }),
    }
    let formats = [PixelPacking::U16LE, U16BE, High16LE, High16BE]
    if depth == 8 {
      formats.push(U8)
    }
    for packing in formats {
      let bytes = if packing == U8 { 1 } else { 2 }
      for p in 0..<3 {
        let plane = frame.planes[p]
        let stride = plane.width * bytes + 5
        let output = FixedArray::make(3 + plane.height * stride + 7, b'\xCD')
        frame.copy_plane_into(p, output, stride, packing, offset=3).unwrap()
        let big = packing == U16BE || packing == High16BE
        let shift = if packing == High16LE || packing == High16BE {
          16 - depth
        } else {
          0
        }
        for y in 0..<plane.height {
          for x in 0..<plane.width {
            let at = 3 + y * stride + x * bytes
            let first = output[at].to_int()
            let second = if bytes == 2 { output[at + 1].to_int() } else { 0 }
            assert_eq(
              if big {
                first * 256 + second
              } else {
                first + second * 256
              },
              plane.data[y * plane.width + x] << shift,
            )
          }
          for x in (plane.width * bytes)..<stride {
            assert_eq(output[3 + y * stride + x], b'\xCD')
          }
        }
        assert_eq(output[0], b'\xCD')
        assert_eq(output[output.length() - 1], b'\xCD')
      }
    }
  }
}
