///|
fn main {
  // IVF header, one record at timestamp 5, then the neutral 10-bit AV1 sample
  // used by examples/decode. The time base is 1/25 second.
  let bytes : Array[Byte] = [
    0x44, 0x4B, 0x49, 0x46, 0, 0, 32, 0, 0x41, 0x56, 0x30, 0x31, 64, 0, 64, 0, 25,
    0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 18, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0,
    0, 0x12, 0x00, 0x0A, 0x06, 0x18, 0x15, 0x7F, 0xFE, 0x08, 0x08, 0x32, 0x06, 0x15,
    0x00, 0x00, 0x00, 0x40, 0x2E,
  ]
  let decoder = @moonav1.Av1ContainerDecoder::new(bytes).unwrap()
  let first = decoder.next_frame().unwrap().unwrap()
  if first.timestamp != Some(5L) || first.frame.bit_depth != 10 {
    abort("unexpected IVF frame timing or precision")
  }
  let selected = decoder.seek_timestamp(5L).unwrap()
  if selected.outcome != @moonav1.Av1ContainerSeekOutcome::Exact {
    abort("timestamp seek did not select the frame")
  }
  let stream = @moonav1.Av1ContainerStreamDecoder::new().unwrap()
  let mut count = 0
  let mut offset = 0
  while offset < bytes.length() {
    let end = if offset + 7 < bytes.length() {
      offset + 7
    } else {
      bytes.length()
    }
    let batch = stream.feed(bytes[offset:end].to_array()).unwrap()
    for item in batch.frames {
      if item.frame.planes[0].data != first.frame.planes[0].data {
        abort("chunked decoder changed native pixels")
      }
      count += 1
    }
    offset = end
  }
  let last = stream.finish().unwrap()
  for item in last.frames {
    if item.frame.planes[0].data != first.frame.planes[0].data {
      abort("final batch changed native pixels")
    }
    count += 1
  }
  if count != 1 || last.status != @moonav1.Av1ContainerStreamStatus::Finished {
    abort("unexpected stream completion")
  }
  println("IVF: 64x64 10-bit frame, timestamp seek and chunked decode OK")
}
