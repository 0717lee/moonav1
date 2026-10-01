///|
/// Focused incremental WebM checks. Full AV1 packet equivalence is exercised
/// by the generated container corpus; these tests keep the streaming protocol
/// and ownership checks independent of that large embedded fixture.

///|
test "incremental WebM waits for split EBML headers" {
  let header : Array[Byte] = [
    0x1A, 0x45, 0xDF, 0xA3, 0x87, 0x42, 0x82, 0x84, 119, 101, 98, 109,
  ]
  let stream = Av1ContainerStream::new(format=Some(WebM)).unwrap()
  assert_eq(stream.feed([header[0]]).unwrap().status, NeedMoreInput)
  assert_eq(
    stream.feed(Array::makei(header.length() - 1, i => header[i + 1])).unwrap().status,
    NeedMoreInput,
  )
  match stream.finish() {
    Err(error) => assert_eq(error.kind, TruncatedInput)
    Ok(_) => fail("missing Segment unexpectedly finished")
  }
}

///|
test "incremental WebM reports terminal truncation" {
  let stream = Av1ContainerStream::new(format=Some(WebM)).unwrap()
  let _ = stream.feed([0x1A, 0x45, 0xDF, 0xA3]).unwrap()
  match stream.finish() {
    Err(error) => assert_eq(error.kind, TruncatedInput)
    Ok(_) => fail("truncated EBML unexpectedly finished")
  }
}

///|
test "incremental WebM queued packets drain without consuming input" {
  let limits = DecodeLimits::default()
  let state = Av1WebmStreamState::new(None, limits)
  state.queue = [
    {
      data: [1, 2, 3],
      presentation_timestamp: Some(1L),
      decode_timestamp: None,
      duration: None,
      sync_sample: Some(true),
    },
    {
      data: [4, 5],
      presentation_timestamp: Some(2L),
      decode_timestamp: None,
      duration: None,
      sync_sample: Some(false),
    },
  ]
  let input : ContainerStreamInput = {
    bytes: [0xA3],
    start: 0,
    base_offset: 9L,
  }
  assert_eq(state.retained_bytes(), 5)
  let offset = input.offset()
  match state.step(input, false) {
    Ok(Packet(packet)) => assert_eq(packet.data, [1, 2, 3])
    _ => fail("queued packet was not returned")
  }
  assert_eq(input.offset(), offset)
  assert_eq(state.retained_bytes(), 2)
  match state.step(input, false) {
    Ok(Packet(packet)) => assert_eq(packet.data, [4, 5])
    _ => fail("second queued packet was not returned")
  }
  assert_eq(state.retained_bytes(), 0)
}

///|
fn webm_stream_test_state(default_duration : Int64?) -> Av1WebmStreamState {
  let state = Av1WebmStreamState::new(None, {
    ..DecodeLimits::default(),
    max_input_bytes: 32,
    max_frames: 16,
  })
  state.selected = Some({
    number: 1L,
    track_type: 1,
    codec_av1: true,
    codec_private: None,
    width: 16,
    height: 16,
    default_duration,
    codec_delay: None,
    flag_lacing: true,
    content_encoded: false,
    track_timestamp_scale_one: true,
  })
  state.track_numbers = [1L]
  state.track = Some({
    format: WebM,
    track_id: 1L,
    width: 16,
    height: 16,
    timescale: WEBM_NANOS,
    movie_timescale: None,
    edits: [],
    codec_initialization: [],
    packets: [],
  })
  state.saw_info = true
  state.saw_tracks = true
  state.segment_unknown = true
  state.stage = WebmInSegment
  state.timestamp_scale = 1L
  state
}

///|
test "finite Cluster header is streamable before its declared body ends" {
  // The Cluster declares 127 bytes, beyond this state's 32-byte input budget,
  // but the first Timestamp and SimpleBlock are complete in this chunk.
  let input : ContainerStreamInput = {
    bytes: [
      0x1F, 0x43, 0xB6, 0x75, 0x40, 0x7F, 0xE7, 0x81, 0, 0xA3, 0x85, 0x81, 0, 0,
      0x80, 0xAA,
    ],
    start: 0,
    base_offset: 0L,
  }
  let state = webm_stream_test_state(None)
  match state.step(input, false) {
    Ok(Progress) => ()
    _ => fail("finite Cluster header did not advance")
  }
  assert_eq(input.offset(), 6L)
  match state.step(input, false) {
    Ok(Progress) => ()
    _ => fail("Cluster Timestamp did not advance")
  }
  match state.step(input, false) {
    Ok(Progress) => ()
    _ => fail("SimpleBlock did not advance")
  }
  match state.step(input, false) {
    Ok(Packet(packet)) => {
      assert_eq(packet.data, [0xAA])
      assert_eq(packet.presentation_timestamp, Some(0L))
    }
    _ => fail("selected packet was not emitted before Cluster EOF")
  }
  assert_eq(input.offset(), 16L)
}

///|
test "unknown Cluster boundary and laced timing remain bounded" {
  let input : ContainerStreamInput = {
    bytes: [
      0x1F, 0x43, 0xB6, 0x75, 0xFF, 0xE7, 0x81, 0, 0xA0, 0x8F, 0xA1, 0x8A, 0x81,
      0, 0, 0x02, 0x02, 1, 1, 0xAA, 0xBB, 0xCC, 0x9B, 0x81, 10, 0x1F, 0x43, 0xB6,
      0x75, 0x80,
    ],
    start: 0,
    base_offset: 0L,
  }
  let state = webm_stream_test_state(Some(3L))
  match state.step(input, false) {
    Ok(Progress) => ()
    _ => fail("unknown Cluster header did not advance")
  }
  match state.step(input, false) {
    Ok(Progress) => ()
    _ => fail("Cluster Timestamp did not advance")
  }
  match state.step(input, false) {
    Ok(Progress) => ()
    _ => fail("laced BlockGroup did not advance")
  }
  assert_eq(state.retained_bytes(), 3)
  let expected_pts = [0L, 3L, 6L]
  let expected_frames : Array[Array[Byte]] = [[0xAA], [0xBB], [0xCC]]
  let expected_durations = [3L, 3L, 4L]
  for i in 0..<3 {
    match state.step(input, false) {
      Ok(Packet(packet)) => {
        assert_eq(packet.data, expected_frames[i])
        assert_eq(packet.presentation_timestamp, Some(expected_pts[i]))
        assert_eq(packet.duration, Some(expected_durations[i]))
      }
      _ => fail("laced packet was not queued")
    }
  }
  assert_eq(state.retained_bytes(), 0)
  match state.step(input, false) {
    Ok(Progress) => ()
    _ => fail("unknown Cluster did not stop at the next Cluster sibling")
  }
  assert_eq(input.offset(), 30L)
}

///|
test "incremental WebM rejects bad EBML metadata" {
  let bad_header : Array[Byte] = [
    0x1A, 0x45, 0xDF, 0xA3, 0x8F, 0x42, 0x87, 0x81, 0x02, 0x42, 0x85, 0x81, 0x03,
    0x42, 0x82, 0x84, 119, 101, 98, 109,
  ]
  let stream = Av1ContainerStream::new(format=Some(WebM)).unwrap()
  match stream.feed(bad_header) {
    Err(error) => assert_eq(error.kind, Unsupported)
    Ok(_) => fail("bad EBML declaration was accepted")
  }
}

///|
test "WebM partial block retries do not consume the element budget" {
  let state = webm_stream_test_state(None)
  state.stage = WebmInCluster
  state.cluster_unknown = true
  state.cluster_timestamp = Some(0L)
  state.cluster_elements = WEBM_MAX_ELEMENTS - 1
  let input : ContainerStreamInput = {
    bytes: [0xA3, 0x86, 0x81, 0, 0, 0x80],
    start: 0,
    base_offset: 0L,
  }
  for _ in 0..<4 {
    match state.step(input, false) {
      Ok(Wait) => ()
      _ => fail("Incomplete block consumed the element budget")
    }
  }
  input.bytes.push(0xAA)
  match state.step(input, false) {
    Ok(Wait) => ()
    _ => fail("Partial payload was treated as a new element")
  }
  input.bytes.push(0xBB)
  match state.step(input, false) {
    Ok(Progress) => ()
    _ => fail("Final permitted block did not complete")
  }
  match state.step(input, false) {
    Ok(Packet(packet)) => assert_eq(packet.data, [0xAA, 0xBB])
    _ => fail("Completed block did not produce its packet")
  }
}
