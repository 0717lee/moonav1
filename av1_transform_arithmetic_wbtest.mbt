/// Exact wide-integer differential checks for the optimized transform steps.
/// Full transform and decoded-image references remain independent codec data.

///|
test "transform Round2 preserves signed rounding and Int32 extremes" {
  let inputs = [
    -2147483648, -2147483647, -536870913, -536870912, -524289, -2049, -2048, -2047,
    -3, -2, -1, 0, 1, 2, 3, 2047, 2048, 2049, 524287, 536870911, 536870912, 2147483646,
    2147483647,
  ]
  for value in inputs {
    for shift in 0..<41 {
      let expected = if shift == 0 {
        value
      } else {
        ((value.to_int64() + (1L << (shift - 1))) >> shift).to_int()
      }
      assert_eq(av1_round2(value, shift), expected)
    }
  }
}

///|
test "transform butterfly matches wide arithmetic across fast path boundaries" {
  let pairs = [
    (0, 0),
    (1, -1),
    (-2049, 2047),
    (524287, -524288),
    (536870911, -536870912),
    (-536870912, -536870912),
    (536870912, 536870911),
    (-536870913, 536870912),
    (2147483647, 2147483647),
    (-2147483648, -2147483648),
    (-2147483648, 2147483647),
    (2147483647, -2147483648),
  ]
  for pair in pairs {
    let (a, b) = pair
    for angle in 0..<256 {
      let ca = av1_cos128(angle).to_int64()
      let sa = av1_sin128(angle).to_int64()
      let x = ((a.to_int64() * ca - b.to_int64() * sa + 2048L) >> 12).to_int()
      let y = ((a.to_int64() * sa + b.to_int64() * ca + 2048L) >> 12).to_int()
      for flip in 0..<2 {
        let actual = [a, b]
        av1_bfly(actual, 0, 1, angle, flip)
        assert_eq(actual, if flip == 1 { [y, x] } else { [x, y] })
      }
    }
  }
}

///|
test "transform Hadamard clips wide sums before narrowing" {
  let pairs = [
    (0, 0),
    (1, -1),
    (-2049, 2047),
    (524287, -524288),
    (2147483647, 2147483647),
    (-2147483648, -2147483648),
    (-2147483648, 2147483647),
    (2147483647, -2147483648),
  ]
  for pair in pairs {
    for bits in [1, 8, 16, 18, 20, 24, 31, 32, 33] {
      let lo = -(1L << (bits - 1))
      let hi = (1L << (bits - 1)) - 1L
      let clip = fn(x : Int64) -> Int {
        (if x < lo { lo } else if x > hi { hi } else { x }).to_int()
      }
      for flip in 0..<2 {
        let (x, y) = pair
        let a = (if flip == 1 { y } else { x }).to_int64()
        let b = (if flip == 1 { x } else { y }).to_int64()
        let sum = clip(a + b)
        let difference = clip(a - b)
        let actual = [x, y]
        av1_had(actual, 0, 1, flip, bits)
        assert_eq(
          actual,
          if flip == 1 {
            [difference, sum]
          } else {
            [sum, difference]
          },
        )
      }
    }
  }
}
