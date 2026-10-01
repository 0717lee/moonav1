///|
struct LargeFixture {
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
  reference : Array[Int]
}

///|
fn verify_frame(
  frame : @moonav1.Av1NativeFrame,
  fixture : LargeFixture,
  index : Int,
) -> Unit {
  if frame.width != fixture.width ||
    frame.height != fixture.height ||
    frame.bit_depth != fixture.depth ||
    frame.planes.length() != 3 ||
    !frame.subsampling_x ||
    !frame.subsampling_y ||
    frame.full_range != fixture.full ||
    frame.matrix_coefficients != fixture.matrix ||
    frame.color_primaries != fixture.primaries ||
    frame.transfer_characteristics != fixture.transfer {
    println(
      "Metadata \{fixture.name}: \{frame.width}x\{frame.height} depth=\{frame.bit_depth} planes=\{frame.planes.length()} sx=\{frame.subsampling_x} sy=\{frame.subsampling_y} full=\{frame.full_range} cicp=\{frame.color_primaries}/\{frame.transfer_characteristics}/\{frame.matrix_coefficients}",
    )
    abort("Large fixture metadata mismatch: \{fixture.name}, frame \{index}")
  }
  let mut offset = index * fixture.width * fixture.height * 3 / 2
  for p in 0..<3 {
    let plane = frame.planes[p]
    let width = fixture.width >> (if p == 0 { 0 } else { 1 })
    let height = fixture.height >> (if p == 0 { 0 } else { 1 })
    if plane.width != width ||
      plane.height != height ||
      plane.data.length() != width * height {
      abort("Large fixture plane shape mismatch: \{fixture.name}")
    }
    for i in 0..<plane.data.length() {
      if plane.data[i] != fixture.reference[offset + i] {
        abort(
          "Large fixture pixel mismatch: \{fixture.name}, frame \{index}, plane \{p}, sample \{i}: \{plane.data[i]} vs \{fixture.reference[offset + i]}",
        )
      }
    }
    offset = offset + plane.data.length()
  }
}

///|
fn decode_video(fixture : LargeFixture) -> Array[@moonav1.Av1NativeFrame] {
  let decoder = @moonav1.av1_video_decoder()
  let frames = []
  for unit in fixture.units {
    let output = @moonav1.av1_video_decode_temporal_unit_native(decoder, unit).unwrap()
    for frame in output {
      frames.push(frame)
    }
  }
  frames
}

///|
fn decode_video_rgba8(fixture : LargeFixture) -> Array[@moonav1.Image] {
  let decoder = @moonav1.av1_video_decoder()
  let frames = []
  for unit in fixture.units {
    let output = @moonav1.av1_video_decode_temporal_unit(decoder, unit).unwrap()
    for frame in output {
      frames.push(frame)
    }
  }
  frames
}

///|
fn verify_fixture(fixture : LargeFixture) -> Unit {
  let frames = decode_video(fixture)
  if frames.length() != fixture.frames {
    abort("Large fixture presentation count mismatch")
  }
  for i in 0..<frames.length() {
    verify_frame(frames[i], fixture, i)
  }
  match fixture.avif {
    Some(bytes) => {
      let image = @moonav1.avif_decode_native(bytes).unwrap()
      if image.alpha is Some(_) || image.premultiplied {
        abort("Unexpected large AVIF alpha")
      }
      verify_frame(image.color, fixture, 0)
      verify_frame(
        @moonav1.av1_decode_native(fixture.units[0]).unwrap(),
        fixture,
        0,
      )
    }
    None => ()
  }
}

///|
fn main {
  let bench = @bench.Bench()
  let args = @env.args()
  let verify_only = args.contains("--verify-only")
  let fixtures = large_fixtures()
  let has_selection = fixtures.any(fixture => args.contains(fixture.name))
  let mut found = false
  for fixture in fixtures {
    if has_selection && !args.contains(fixture.name) {
      continue
    }
    found = true
    verify_fixture(fixture)
    if verify_only {
      println(
        "Verified \{fixture.name}: \{fixture.frames} frame(s), exact native pixels",
      )
      continue
    }
    match fixture.avif {
      Some(bytes) => {
        bench.bench(name="\{fixture.name}/decode_av1_native", count=5, () => {
          bench.keep(@moonav1.av1_decode_native(fixture.units[0]).unwrap())
        })
        bench.bench(name="\{fixture.name}/decode_avif_native", count=5, () => {
          bench.keep(@moonav1.avif_decode_native(bytes).unwrap())
        })
      }
      None => {
        bench.bench(name="\{fixture.name}/decode_video_native", count=5, () => {
          bench.keep(decode_video(fixture))
        })
        bench.bench(name="\{fixture.name}/decode_video_rgba8", count=5, () => {
          bench.keep(decode_video_rgba8(fixture))
        })
      }
    }
  }
  if !found {
    abort("No matching large fixture")
  }
  if !verify_only {
    println(bench.dump_summaries())
  }
}
