/// File-backed independent comparison, with bounded host IO buffers.
/// Host adapters only read bytes/configuration; all decoding runs in MoonBit.

///|
fn require(value : Bool, message : String) -> Unit {
  if !value {
    println(message)
    abort(message)
  }
}

///|
fn read_byte(file : Int) -> Int {
  let value = io_read(file)
  require(value >= 0, "Unexpected EOF or file error")
  value
}

///|
struct ObuReader {
  mut pending : Int
}

///|
fn ObuReader::next(self : ObuReader) -> Array[Byte]? {
  let unit = []
  let mut header = if self.pending >= 0 { self.pending } else { io_read(0) }
  self.pending = -1
  while header >= 0 {
    if ((header >> 3) & 15) == 2 && !unit.is_empty() {
      self.pending = header
      return Some(unit)
    }
    unit.push(header.to_byte())
    require((header & 2) != 0, "Fixture OBU has no explicit size")
    if (header & 4) != 0 {
      unit.push(read_byte(0).to_byte())
    }
    let mut size = 0
    let mut shift = 0
    while true {
      let byte = read_byte(0)
      unit.push(byte.to_byte())
      require(shift < 28, "Fixture OBU exceeds reader limit")
      size = size | ((byte & 127) << shift)
      if (byte & 128) == 0 {
        break
      }
      shift += 7
    }
    require(
      size <= 64 * 1024 * 1024 - unit.length(),
      "Fixture unit exceeds reader limit",
    )
    for _ in 0..<size {
      unit.push(read_byte(0).to_byte())
    }
    header = io_read(0)
  }
  require(header == -1, "File read failed")
  if unit.is_empty() {
    None
  } else {
    Some(unit)
  }
}

///|
fn verify_frame(
  frame : @moonav1.Av1NativeFrame,
  index : Int,
  alpha? : Bool = false,
) -> Int {
  let file = if alpha { 3 } else { 1 }
  require(
    frame.width == io_config(0) &&
    frame.height == io_config(1) &&
    frame.bit_depth == io_config(2),
    "Geometry mismatch at frame \{index}",
  )
  require(
    frame.planes.length() == (if alpha { 1 } else { io_config(3) }),
    "Plane count mismatch",
  )
  require(
    frame.full_range == (io_config(if alpha { 14 } else { 9 }) != 0),
    "Range mismatch",
  )
  if !alpha {
    require(
      frame.subsampling_x == (io_config(4) == 1) &&
      frame.subsampling_y == (io_config(5) == 1) &&
      frame.color_primaries == io_config(6) &&
      frame.transfer_characteristics == io_config(7) &&
      frame.matrix_coefficients == io_config(8),
      "Color metadata mismatch",
    )
  }
  let mut count = 0
  for p in 0..<frame.planes.length() {
    let plane = frame.planes[p]
    let dx = if p == 0 || !frame.subsampling_x { 1 } else { 2 }
    let dy = if p == 0 || !frame.subsampling_y { 1 } else { 2 }
    require(
      plane.width == (frame.width + dx - 1) / dx &&
      plane.height == (frame.height + dy - 1) / dy &&
      plane.data.length() == plane.width * plane.height,
      "Plane extent mismatch",
    )
    for i in 0..<plane.data.length() {
      let low = read_byte(file)
      let expected = if frame.bit_depth == 8 {
        low
      } else {
        low | (read_byte(file) << 8)
      }
      if plane.data[i] != expected {
        require(
          false,
          "Pixel mismatch frame=\{index} plane=\{p} sample=\{i} actual=\{plane.data[i]} expected=\{expected}",
        )
      }
    }
    count += plane.data.length()
  }
  count
}

///|
fn slot_samples(decoder : @moonav1.Av1VideoDecoder) -> Int {
  require(decoder.map.slots.length() == 8, "Reference slot count changed")
  let mut count = 0
  for slot in decoder.map.slots {
    match slot {
      None => ()
      Some(frame) =>
        for plane in frame.planes {
          count += plane.length()
        }
    }
  }
  let area = (io_config(0) + 7) / 8 * 8 * ((io_config(1) + 7) / 8 * 8)
  require(count <= 8 * area * 3, "Reference storage exceeds bounded slots")
  count
}

///|
fn fixture_avif_bytes(read_error? : String = "AVIF read failed") -> Array[Byte] {
  require(io_open(2) == 2, "Cannot open AVIF")
  let bytes = []
  let mut byte = io_read(2)
  while byte >= 0 {
    bytes.push(byte.to_byte())
    byte = io_read(2)
  }
  require(byte == -1, read_error)
  io_close(2)
  bytes
}

///|
fn reference_at(index : Int) -> Unit {
  require(io_rewind(1) == 0, "Cannot rewind native reference")
  let cw = (io_config(0) + io_config(4)) >> io_config(4)
  let ch = (io_config(1) + io_config(5)) >> io_config(5)
  let size = (
      io_config(0) * io_config(1) +
      (if io_config(3) == 1 { 0 } else { 2 * cw * ch })
    ) *
    (if io_config(2) == 8 { 1 } else { 2 })
  for _ in 0..<index {
    for _ in 0..<size {
      ignore(read_byte(1))
    }
  }
}

///|
fn main {
  require(
    io_config(0) > 0 && io_config(10) > 0 && io_config(13) > 0,
    "Run through scripts/check-file-fixtures.py",
  )
  require(io_open(1) == 1, "Cannot open native reference")
  let limits = @moonav1.DecodeLimits::default()
  let mut samples : Int64 = 0
  let mut frames = 0
  let mut peak = 0
  let mut icc_pixels = 0
  let mut icc_max_error = 0
  if io_config(11) == 2 {
    let decoder = @moonav1.AvifAnimationDecoder::new(fixture_avif_bytes()).unwrap()
    require(decoder.frame_count() == io_config(10), "Animation count differs")
    let mut first : @moonav1.Av1NativeFrame? = None
    for _ in 0..<io_config(13) {
      decoder.reset()
      reference_at(0)
      for index in 0..<io_config(10) {
        let frame = decoder.next_frame().unwrap().unwrap()
        require(frame.index == index, "Animation position differs")
        samples += verify_frame(frame.image.color, index).to_int64()
        require(
          frame.image.alpha is None,
          "Unexpected alpha in real-video corpus",
        )
        if first is None {
          first = Some(frame.image.color)
        } else {
          for plane in frame.image.color.planes {
            plane.data[0] = -1
          }
        }
        frames += 1
      }
      require(
        decoder.next_frame().unwrap() is None && io_read(1) == -1,
        "Animation EOF differs",
      )
    }
    for index in [io_config(10) - 1, io_config(10) / 2, 1, 0] {
      reference_at(index)
      ignore(
        verify_frame(decoder.seek_frame(index).unwrap().image.color, index),
      )
    }
    reference_at(0)
    ignore(verify_frame(first.unwrap(), 0))
  } else if io_config(11) == 3 {
    require(io_open(0) == 0, "Cannot open AV1")
    let decoder = @moonav1.Av1StreamDecoder::new(allow_monochrome=true).unwrap()
    let mut first : @moonav1.Av1NativeFrame? = None
    for _ in 0..<io_config(13) {
      decoder.reset()
      require(io_rewind(0) == 0 && io_rewind(1) == 0, "Cannot rewind stream")
      let mut index = 0
      let mut chunk_index = 0
      while true {
        let chunk = []
        let size = [1, 2, 7, 251, 4093][chunk_index % 5]
        chunk_index += 1
        let mut eof = false
        for _ in 0..<size {
          let byte = io_read(0)
          if byte == -1 {
            eof = true
            break
          }
          require(byte >= 0, "Input read error")
          chunk.push(byte.to_byte())
        }
        let batch = if eof && chunk.is_empty() {
          decoder.finish().unwrap()
        } else {
          decoder.feed(chunk).unwrap()
        }
        for frame in batch.frames {
          samples += verify_frame(frame, index).to_int64()
          if first is None {
            first = Some(frame)
          } else {
            for plane in frame.planes {
              plane.data[0] = -1
            }
          }
          index += 1
          frames += 1
        }
        require(
          decoder.pending_bytes() <= 64 * 1024 * 1024 + 16,
          "Unbounded compressed buffer",
        )
        if batch.status == @moonav1.Finished {
          break
        }
      }
      require(
        index == io_config(10) && io_read(1) == -1,
        "Chunk stream count differs",
      )
    }
    reference_at(0)
    ignore(verify_frame(first.unwrap(), 0))
    io_close(0)
  } else if io_config(11) == 1 {
    let bytes = fixture_avif_bytes(read_error="AVIF file read failed")
    let image = limits.avif_decode_native(bytes).unwrap()
    require(
      image.premultiplied == (io_config(15) != 0),
      "Prem association mismatch",
    )
    samples += verify_frame(image.color, 0).to_int64()
    if io_config(12) == 1 {
      require(io_open(3) == 3, "Cannot open alpha reference")
      samples += verify_frame(image.alpha.unwrap(), 0, alpha=true).to_int64()
      require(io_read(3) == -1, "Unexpected extra alpha reference bytes")
      io_close(3)
    } else {
      require(image.alpha is None, "Unexpected alpha")
    }
    frames = 1
    require(io_read(1) == -1, "Unexpected extra reference bytes")
    if io_config(16) == 1 {
      require(io_open(4) == 4 && io_open(5) == 5, "Cannot open ICC references")
      let rgba = image.to_rgba16().unwrap()
      let metadata = @moonav1.avif_metadata(bytes).unwrap()
      let icc = metadata.icc.unwrap()
      let profile = @moonav1.IccProfile::parse(
        Array::makei(icc.length(), i => icc[i]),
      ).unwrap()
      let converted = profile.apply_rgba16(rgba).unwrap()
      // Separately compare decode/RGB conversion and ICC math on identical
      // independently decoded input, so two stage errors cannot cancel out.
      for i in 0..<rgba.data.length() {
        let expected = read_byte(4) | (read_byte(4) << 8)
        let difference = rgba.data[i].to_int() - expected
        let tolerance = if i % 4 == 3 { 0 } else { 1 }
        if difference < 0 - tolerance || difference > tolerance {
          require(
            false,
            "RGBA16 mismatch channel=\{i} actual=\{rgba.data[i]} expected=\{expected}",
          )
        }
        rgba.data[i] = expected.to_uint16()
      }
      let isolated = profile.apply_rgba16(rgba).unwrap()
      let outputs = [converted, isolated]
      for i in 0..<rgba.data.length() {
        let expected = read_byte(5) | (read_byte(5) << 8)
        let tolerance = if i % 4 == 3 { 0 } else { 8 }
        for output in outputs {
          let delta = output.data[i].to_int() - expected
          let difference = if delta < 0 { 0 - delta } else { delta }
          if difference > tolerance {
            require(
              false,
              "ICC mismatch channel=\{i} actual=\{output.data[i]} expected=\{expected}",
            )
          }
          if difference > icc_max_error {
            icc_max_error = difference
          }
        }
      }
      require(io_read(4) == -1 && io_read(5) == -1, "Extra ICC reference bytes")
      io_close(4)
      io_close(5)
      icc_pixels = rgba.width * rgba.height
    }
  } else {
    require(io_open(0) == 0, "Cannot open AV1")
    let decoder = @moonav1.av1_video_decoder()
    let mut first : @moonav1.Av1NativeFrame? = None
    for _ in 0..<io_config(13) {
      require(io_rewind(0) == 0 && io_rewind(1) == 0, "Cannot rewind fixtures")
      let reader : ObuReader = { pending: -1, }
      let mut index = 0
      while true {
        let unit = match reader.next() {
          Some(value) => value
          None => break
        }
        let output = match
          @moonav1.av1_video_decode_temporal_unit_native_result(
            decoder,
            unit,
            allow_monochrome=true,
            limits~,
          ) {
          Ok(value) => value
          Err(error) => {
            let message = "Decode failed before presentation \{index}: \{error.context}: \{error.message}"
            println(message)
            abort(message)
          }
        }
        for frame in output {
          require(index < io_config(10), "Too many presentations")
          samples += verify_frame(frame, index).to_int64()
          if first is None {
            first = Some(frame)
          } else {
            for plane in frame.planes {
              plane.data[0] = (1 << frame.bit_depth) - 1
            }
          }
          index += 1
          frames += 1
        }
        let count = slot_samples(decoder)
        if count > peak {
          peak = count
        }
      }
      require(
        index == io_config(10) && io_read(1) == -1,
        "Presentation/reference count mismatch",
      )
    }
    require(io_rewind(1) == 0, "Cannot recheck retained first frame")
    ignore(verify_frame(first.unwrap(), 0))
    io_close(0)
  }
  io_close(1)
  println(
    "Verified frames=\{frames} samples=\{samples} peak_slot_samples=\{peak} icc_pixels=\{icc_pixels} icc_max_error=\{icc_max_error}",
  )
}
