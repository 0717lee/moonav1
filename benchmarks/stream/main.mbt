///|
struct StreamFixture {
  name : String
  width : Int
  height : Int
  depth : Int
  frames : Int
  primaries : Int
  transfer : Int
  matrix : Int
  full : Bool
  units : Array[Array[Byte]]
  avif : Array[Byte]?
  reference : (Int) -> Array[Int]
}

///|
fn require(condition : Bool, message : String) -> Unit {
  if !condition {
    // Release abort messages may be removed, so keep the diagnostic observable.
    println(message)
    abort(message)
  }
}

///|
fn verify_frame(
  frame : @moonav1.Av1NativeFrame,
  fixture : StreamFixture,
  index : Int,
) -> Unit {
  require(
    frame.width == fixture.width &&
    frame.height == fixture.height &&
    frame.bit_depth == fixture.depth &&
    frame.planes.length() == 3 &&
    frame.subsampling_x &&
    frame.subsampling_y &&
    frame.full_range == fixture.full &&
    frame.color_primaries == fixture.primaries &&
    frame.transfer_characteristics == fixture.transfer &&
    frame.matrix_coefficients == fixture.matrix,
    "Metadata mismatch: \{fixture.name}, frame \{index}",
  )
  let reference = (fixture.reference)(index)
  let mut offset = 0
  for p in 0..<3 {
    let plane = frame.planes[p]
    let w = fixture.width >> (if p == 0 { 0 } else { 1 })
    let h = fixture.height >> (if p == 0 { 0 } else { 1 })
    require(
      plane.width == w && plane.height == h && plane.data.length() == w * h,
      "Plane shape mismatch: \{fixture.name}",
    )
    for i in 0..<plane.data.length() {
      if plane.data[i] != reference[offset + i] {
        require(
          false,
          "Pixel mismatch: \{fixture.name}, frame \{index}, plane \{p}, sample \{i}: \{plane.data[i]} vs \{reference[offset + i]}",
        )
      }
    }
    offset += plane.data.length()
  }
  require(offset == reference.length(), "Reference extent mismatch")
}

///|
/// Inspect logical reference storage after each unit. Counting aliased slots
/// separately is a conservative sample bound, not an RSS or heap measurement.
fn reference_samples(
  decoder : @moonav1.Av1VideoDecoder,
  fixture : StreamFixture,
) -> Int {
  let map = decoder.map
  require(
    map.slots.length() == 8 && map.saved_segment_ids.length() == 8,
    "Reference slot count changed",
  )
  let coded_w = (fixture.width + 7) / 8 * 8
  let coded_h = (fixture.height + 7) / 8 * 8
  let mut samples = 0
  for slot in 0..<8 {
    match map.slots[slot] {
      None => ()
      Some(frame) => {
        require(
          frame.coded_width == coded_w && frame.coded_height == coded_h,
          "Unexpected reference geometry",
        )
        require(
          frame.mf_refs.length() <= coded_w * coded_h / 16 &&
          frame.mf_mvs.length() <= coded_w * coded_h / 8 &&
          map.saved_segment_ids[slot].length() <= coded_w * coded_h / 16,
          "Reference side data exceeds frame geometry",
        )
        for plane in frame.planes {
          samples += plane.length()
        }
      }
    }
  }
  require(
    samples <= 8 * coded_w * coded_h * 3 / 2,
    "Reference plane samples exceed eight slots",
  )
  samples
}

///|
/// Keep one caller-owned picture, verify each later picture then release it.
/// Altering later output samples must not affect references or the saved frame.
fn verify_stream(fixture : StreamFixture, batch? : Int = 1) -> Int {
  let decoder = @moonav1.av1_video_decoder()
  let mut index = 0
  let mut peak = 0
  let mut first : @moonav1.Av1NativeFrame? = None
  let mut unit = 0
  while unit < fixture.units.length() {
    let bytes = []
    for _ in 0..<batch {
      if unit == fixture.units.length() {
        break
      }
      for byte in fixture.units[unit] {
        bytes.push(byte)
      }
      unit += 1
    }
    let output = @moonav1.av1_video_decode_temporal_unit_native(decoder, bytes).unwrap()
    for frame in output {
      require(index < fixture.frames, "Too many presentations")
      verify_frame(frame, fixture, index)
      if index == 0 {
        first = Some(frame)
      } else {
        for plane in frame.planes {
          plane.data[0] = (1 << fixture.depth) - 1
          plane.data[plane.data.length() - 1] = 0
        }
      }
      index += 1
    }
    let samples = reference_samples(decoder, fixture)
    if samples > peak {
      peak = samples
    }
  }
  require(index == fixture.frames, "Missing presentations")
  verify_frame(first.unwrap(), fixture, 0)
  match fixture.avif {
    None => ()
    Some(bytes) => {
      let image = @moonav1.avif_decode_native(bytes).unwrap()
      require(image.alpha is None && !image.premultiplied, "Unexpected alpha")
      verify_frame(image.color, fixture, 0)
      verify_frame(
        @moonav1.av1_decode_native(fixture.units[0]).unwrap(),
        fixture,
        0,
      )
    }
  }
  peak
}

///|
/// Decode and consume each returned picture without accumulating the sequence.
fn decode_stream(fixture : StreamFixture) -> Int {
  let decoder = @moonav1.av1_video_decoder()
  let mut count = 0
  for unit in fixture.units {
    let frames = @moonav1.av1_video_decode_temporal_unit_native(decoder, unit).unwrap()
    count += frames.length()
  }
  count
}

///|
fn main {
  let args = @env.args()
  let verify_only = args.contains("--verify-only")
  let bench = @bench.Bench()
  let fixtures = [stream_fixture_0(), stream_fixture_1()]
  let selected = fixtures.any(fixture => args.contains(fixture.name))
  for fixture in fixtures {
    if selected && !args.contains(fixture.name) {
      continue
    }
    let peak = verify_stream(fixture)
    if verify_only {
      println(
        "Verified \{fixture.name}: \{fixture.frames} frame(s), exact native pixels; peak slot samples=\{peak}",
      )
      continue
    }
    match fixture.avif {
      Some(bytes) =>
        bench.bench(name="\{fixture.name}/decode_avif_native", count=5, () => {
          bench.keep(@moonav1.avif_decode_native(bytes).unwrap())
        })
      None => {
        bench.bench(name="\{fixture.name}/decode_stream_native", count=5, () => {
          bench.keep(decode_stream(fixture))
        })
        // The saved stream's fourth unit is an inter show-existing header.
        // Repeating it leaves the reference state intact and isolates output
        // preparation from prediction, inverse transforms and loop filters.
        let decoder = @moonav1.av1_video_decoder()
        for i in 0..<4 {
          let output = @moonav1.av1_video_decode_temporal_unit_native(
            decoder,
            fixture.units[i],
          ).unwrap()
          require(output.length() == 1, "Expected one replay preparation frame")
          verify_frame(output[0], fixture, i)
        }
        let replay = fixture.units[3]
        require(
          replay == [b'\x12', b'\x00', b'\x1a', b'\x01', b'\xa8'],
          "Replay fixture changed",
        )
        verify_frame(
          @moonav1.av1_video_decode_temporal_unit_native(decoder, replay).unwrap()[0],
          fixture,
          3,
        )
        bench.bench(name="\{fixture.name}/present_existing_native", count=5, () => {
          bench.keep(
            @moonav1.av1_video_decode_temporal_unit_native(decoder, replay).unwrap(),
          )
        })
      }
    }
  }
  if !verify_only {
    println(bench.dump_summaries())
  }
}
