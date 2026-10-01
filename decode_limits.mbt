///|
/// Optional work limits for a single high-level decode call. max_input_bytes
/// also caps each assembled item/sample payload, including repeated extents.
/// Pixel counts are
/// luma-grid areas, not bytes or a process-memory guarantee. Every reconstructed
/// or show-existing picture counts, including hidden pictures and alpha tracks.
/// Grid canvases also consume pixels. Reference state persists between video
/// calls, but the work budget restarts for each call.
/// All fields must be positive; max_frame_pixels cannot exceed 100,000,000.
pub(all) struct DecodeLimits {
  max_input_bytes : Int
  max_frame_pixels : Int
  max_total_pixels : Int
  max_frames : Int
}

///|
/// An opt-in starting policy: 64 MiB input, 16 Mi pixels per padded picture,
/// 128 Mi cumulative pixels and 256 pictures. Ordinary free functions preserve
/// their original policy. Applications can construct stricter limits.
pub fn DecodeLimits::default() -> DecodeLimits {
  {
    max_input_bytes: 64 * 1024 * 1024,
    max_frame_pixels: 16 * 1024 * 1024,
    max_total_pixels: 128 * 1024 * 1024,
    max_frames: 256,
  }
}

///|
priv struct DecodeBudget {
  limits : DecodeLimits
  mut frames_left : Int
  mut pixels_left : Int
  diagnostic : DecodeDiagnostic?
}

///|
fn decode_input_allowed(length : Int, limits : DecodeLimits?) -> Bool {
  match limits {
    None => true
    Some(value) =>
      value.max_input_bytes > 0 &&
      value.max_frame_pixels > 0 &&
      value.max_frame_pixels <= MAX_IMAGE_PIXELS &&
      value.max_total_pixels > 0 &&
      value.max_frames > 0 &&
      length >= 0 &&
      length <= value.max_input_bytes
  }
}

///|
fn decode_budget(limits : DecodeLimits?) -> DecodeBudget? {
  limits.map(value => {
    limits: value,
    frames_left: value.max_frames,
    pixels_left: value.max_total_pixels,
    diagnostic: None,
  })
}

///|
fn decode_samples_allowed(
  samples : Array[Array[Byte]],
  limits : DecodeLimits?,
) -> Bool {
  if !decode_input_allowed(0, limits) {
    return false
  }
  match limits {
    None => true
    Some(value) => {
      let mut remaining = value.max_input_bytes
      for sample in samples {
        if sample.length() > remaining {
          return false
        }
        remaining -= sample.length()
      }
      true
    }
  }
}

///|
fn decode_payload_allowed(
  length : Int,
  added : Int,
  limits : DecodeLimits?,
) -> Bool {
  if length < 0 || added < 0 || added > 0x7FFFFFFF - length {
    return false
  }
  match limits {
    None => true
    Some(value) => added <= value.max_input_bytes - length
  }
}

///|
/// Reserve before allocating a reconstructed picture or grid canvas. AV1
/// reconstruction counts MI padding and the larger super-resolution extent.
fn decode_reserve(
  budget : DecodeBudget?,
  width : Int,
  height : Int,
  picture? : Bool = true,
  padded? : Bool = true,
) -> Bool {
  let value = match budget {
    None => return true
    Some(value) => value
  }
  if width <= 0 ||
    height <= 0 ||
    width > MAX_IMAGE_PIXELS ||
    height > MAX_IMAGE_PIXELS {
    return false
  }
  let w = if padded { (width + 7) / 8 * 8 } else { width }
  let h = if padded { (height + 7) / 8 * 8 } else { height }
  if w > value.limits.max_frame_pixels / h ||
    w > value.pixels_left / h ||
    (picture && value.frames_left == 0) {
    decode_fail(
      budget,
      LimitExceeded,
      "Picture size, cumulative pixels or picture count exceeds the selected policy",
    )
    return false
  }
  value.pixels_left -= w * h
  if picture {
    value.frames_left -= 1
  }
  true
}

///|
/// Bounds parser stack use even when optional decode work limits are absent.
/// Normal AVIF box hierarchies require far fewer than 64 nested containers.
const AVIF_MAX_BOX_DEPTH : Int = 64
