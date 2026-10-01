///|
test "HD 12-bit native and AVIF exact independent pixels" {
  ignore(verify_stream(stream_fixture_0()))
}

///|
test "32-frame reordered video exact independent pixels and output ownership" {
  ignore(verify_stream(stream_fixture_1()))
}

///|
test "32-frame reordered video batches preserve presentation order" {
  ignore(verify_stream(stream_fixture_1(), batch=5))
}
