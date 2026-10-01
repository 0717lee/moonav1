///|
struct Fixture {
  name : String
  input : Array[Byte]
  width : Int
  height : Int
  references : Array[Array[Int]]
  decode : Bool
}

///|
/// Check every channel against the saved independent reference before timing.
fn verify(image : @moonav1.Image16, fixture : Fixture, frame : Int) -> Unit {
  let reference = fixture.references[frame]
  if image.width != fixture.width ||
    image.height != fixture.height ||
    image.data.length() != reference.length() {
    abort("Benchmark shape mismatch: \{fixture.name}, frame \{frame}")
  }
  for i in 0..<reference.length() {
    let tolerance = if i % 4 == 3 { 0 } else { 1 }
    if (image.data[i].to_int() - reference[i]).abs() > tolerance {
      abort(
        "Benchmark pixel mismatch: \{fixture.name}, frame \{frame}, channel \{i}",
      )
    }
  }
}

///|
fn benchmark_into(
  bench : @bench.Bench,
  image : @moonav1.AvifNativeImage,
  fixture : Fixture,
  frame : Int,
) -> Unit {
  let stride = fixture.width * 4 + 8
  let buffer : FixedArray[UInt16] = FixedArray::make(
    3 + stride * fixture.height,
    65535,
  )
  image.to_rgba16_into(buffer, stride, offset=3).unwrap()
  let reference = fixture.references[frame]
  for y in 0..<fixture.height {
    for c in 0..<(fixture.width * 4) {
      let tolerance = if c % 4 == 3 { 0 } else { 1 }
      if (buffer[3 + y * stride + c].to_int() -
        reference[y * fixture.width * 4 + c]).abs() >
        tolerance {
        abort("Caller-buffer benchmark pixel mismatch")
      }
    }
  }
  bench.bench(name="\{fixture.name}/convert_rgba16_into", () => {
    image.to_rgba16_into(buffer, stride, offset=3).unwrap()
    bench.keep(buffer)
  })
}

///|
fn main {
  let bench = @bench.Bench()
  for fixture in fixtures() {
    if fixture.references.length() > 1 {
      let animation = @moonav1.avif_decode_animation_native(fixture.input).unwrap()
      if animation.frames.length() != fixture.references.length() {
        abort("Benchmark frame count mismatch: \{fixture.name}")
      }
      for i in 0..<animation.frames.length() {
        verify(animation.frames[i].image.to_rgba16().unwrap(), fixture, i)
      }
      bench.bench(name="\{fixture.name}/decode_native", () => {
        bench.keep(
          @moonav1.avif_decode_animation_native(fixture.input).unwrap(),
        )
      })
      bench.bench(name="\{fixture.name}/decode_rgba8", () => {
        bench.keep(@moonav1.avif_decode_animation(fixture.input).unwrap())
      })
      let image = animation.frames[1].image
      bench.bench(name="\{fixture.name}/convert_rgba16_frame1", () => {
        bench.keep(image.to_rgba16().unwrap())
      })
      benchmark_into(bench, image, fixture, 1)
    } else {
      let image = @moonav1.avif_decode_native(fixture.input).unwrap()
      verify(image.to_rgba16().unwrap(), fixture, 0)
      if fixture.decode {
        verify(@moonav1.avif_decode_rgba16(fixture.input).unwrap(), fixture, 0)
        bench.bench(name="\{fixture.name}/decode_native", () => {
          bench.keep(@moonav1.avif_decode_native(fixture.input).unwrap())
        })
        bench.bench(name="\{fixture.name}/decode_rgba8", () => {
          bench.keep(@moonav1.avif_decode(fixture.input).unwrap())
        })
        bench.bench(name="\{fixture.name}/decode_rgba16", () => {
          bench.keep(@moonav1.avif_decode_rgba16(fixture.input).unwrap())
        })
      }
      bench.bench(name="\{fixture.name}/convert_rgba16", () => {
        bench.keep(image.to_rgba16().unwrap())
      })
      benchmark_into(bench, image, fixture, 0)
    }
  }
  println(bench.dump_summaries())
}
