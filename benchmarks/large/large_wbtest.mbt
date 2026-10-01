///|
test "large 512x384 8-bit AV1 and AVIF exact independent pixels" {
  verify_fixture(large_fixtures()[0])
}

///|
test "large 512x384 12-bit AV1 and AVIF exact independent pixels" {
  verify_fixture(large_fixtures()[1])
}

///|
test "large 640x360 10-bit video exact independent pixels" {
  let fixture = large_fixtures()[2]
  verify_fixture(fixture)
  let joined = []
  for unit in fixture.units {
    for byte in unit {
      joined.push(byte)
    }
  }
  let frames = @moonav1.av1_video_decode_temporal_unit_native(
    @moonav1.av1_video_decoder(),
    joined,
  ).unwrap()
  assert_eq(frames.length(), fixture.frames)
  for i in 0..<frames.length() {
    verify_frame(frames[i], fixture, i)
  }
}
