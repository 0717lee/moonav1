///|
/// A separate-package consumer for color-managed AV1 video. Every input in
/// fixtures.mbt is retained or explicitly derived from the saved fixtures; the example
/// itself performs no file I/O.
fn main {
  let avif_input = metadata_fixture()
  let native = @moonav1.avif_decode_native(avif_input).unwrap()
  let metadata = @moonav1.avif_metadata(avif_input).unwrap()
  let icc_bytes = metadata.icc.unwrap()
  let profile_bytes = Array::makei(icc_bytes.length(), i => icc_bytes[i])
  let profile = match @moonav1.IccProfile::parse(profile_bytes) {
    Ok(value) => value
    Err(_) => abort("ICC fixture was rejected")
  }
  let managed = profile.apply_rgba16(native.to_rgba16().unwrap()).unwrap()
  println(
    "ICC: RGBA16 \{managed.width}x\{managed.height}, profile=\{icc_bytes.length()} bytes, alpha=\{managed.data[3]}",
  )

  let hdr_frame = @moonav1.av1_decode_native(hdr_obu()).unwrap()
  let sdr = hdr_frame
    .to_sdr_rgba16(options={
      peak_luminance_nits: 600.0,
      reference_white_nits: 100.0,
      exposure_stops: 0.0,
    })
    .unwrap()
  println("HDR: explicit PQ tone map, SDR16 red=\{sdr.data[0]}")

  let sample = metadata
    .resample_rgba16(native.to_rgba16().unwrap(), 7, 6)
    .unwrap()
  println(
    "Crop: 23/2 x 19/2 clap, transforms=\{metadata.transforms.length()}, RGBA16 \{sample.width}x\{sample.height}, red=\{sample.data[0]}",
  )

  container_summary("IVF", container_ivf())
  container_summary("MP4", container_mp4())
  container_summary("WebM", container_webm())

  let compensated = profile
    .apply_rgba16_with_options(
      native.to_rgba16().unwrap(),
      @moonav1.IccTransformOptions::new(@moonav1.RelativeColorimetric, true),
    )
    .unwrap()
  println(
    "ICC policy: relative+BPC, red=\{compensated.data[0]}, alpha=\{compensated.data[3]}",
  )
  stream_summary("IVF", container_ivf())
  stream_summary("MP4", container_mp4())
  stream_summary("WebM", container_webm())

  let video = @moonav1.Av1ContainerDecoder::new(container_mp4()).unwrap()
  let first = video.next_frame().unwrap().unwrap()
  let requested = first.timestamp.unwrap()
  let located = video.seek_timestamp(requested).unwrap()
  let outcome = match located.outcome {
    @moonav1.Exact => "exact"
    @moonav1.Next => "next"
    @moonav1.End => "end"
    @moonav1.UnknownTimestamp => "unknown timestamp"
  }
  println(
    "Seek: requested=\{requested}, outcome=\{outcome}, packet=\{located.frame.unwrap().packet_index}",
  )
  let timeline = video.presentation_timeline().unwrap()
  let point = match timeline.map_movie_time(0L).unwrap() {
    @moonav1.Empty => "empty edit"
    @moonav1.End => "end"
    @moonav1.Media(time) => "\{time.numerator}/\{time.denominator} media ticks"
  }
  println("Timeline: edits=\{timeline.edit_count()}, movie tick 0=\{point}")
}

///|
fn container_summary(label : String, data : Array[Byte]) -> Unit {
  let decoder = match @moonav1.Av1ContainerDecoder::new(data) {
    Ok(value) => value
    Err(_) => abort("Container fixture was rejected")
  }
  let mut presentations = 0
  while true {
    match decoder.next_frame() {
      Ok(Some(_)) => presentations += 1
      Ok(None) => break
      Err(_) => abort("Container decode failed")
    }
  }
  println(
    "Container \{label}: packets=\{decoder.packet_count()}, presentations=\{presentations}",
  )
}

///|
/// A host supplies byte chunks; this example supplies them from saved data.
/// Consume each returned batch before feeding more compressed input.
fn stream_summary(label : String, data : Array[Byte]) -> Unit {
  let stream = @moonav1.Av1ContainerStreamDecoder::new(limits={
    ..@moonav1.DecodeLimits::default(),
    max_input_bytes: 8192,
  }).unwrap()
  let mut presentations = 0
  let mut replayed = false
  while true {
    let mut at = 0
    while at < data.length() {
      let count = if data.length() - at < 37 { data.length() - at } else { 37 }
      let chunk = Array::makei(count, i => data[at + i])
      let batch = stream.feed(chunk).unwrap()
      presentations += batch.frames.length()
      at += count
    }
    let last = stream.finish().unwrap()
    presentations += last.frames.length()
    match last.status {
      @moonav1.ReplayRequired => {
        // Tail-moov MP4 retained its index. A seekable host rewinds the same
        // file; we resend this immutable input from byte zero.
        if replayed {
          abort("Repeated replay request")
        }
        stream.replay().unwrap()
        replayed = true
      }
      @moonav1.Finished => break
      _ => abort("Container did not finish")
    }
  }
  println(
    "Stream \{label}: presentations=\{presentations}, peak=\{stream.peak_pending_bytes()}, replay=\{replayed}",
  )
}
