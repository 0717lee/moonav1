///|
/// One presented animation sample with timing in the primary track's units.
/// Color and alpha retain their original precision, range and prem association.
/// Its buffers are independent of every other decoded sample and input data.
pub struct AvifNativeAnimationFrame {
  index : Int
  timestamp : Int
  duration : Int
  timescale : Int
  image : AvifNativeImage
}

///|
/// A completely decoded AVIF animation in presentation order. On return,
/// frames is nonempty, index equals the array position, durations are positive,
/// and timestamps are contiguous from zero, in units of timescale per second.
/// The total duration fits in a positive Int. All frames share this timescale.
pub struct AvifNativeAnimation {
  timescale : Int
  frames : FixedArray[AvifNativeAnimationFrame]
}

///|
/// Decode the entire AVIF animation at 8/10/12-bit native precision.
/// Each color/alpha track keeps its own AV1 reference state. Track association,
/// exact time alignment, metadata and rejection follow avif_decode_animation;
/// color conversion and alpha range expansion/unpremultiplication are omitted.
/// None rejects the whole animation, including a malformed later sample.
fn avif_decode_animation_native_limited(
  data : Array[Byte],
  limits? : DecodeLimits? = None,
) -> AvifNativeAnimation? {
  let decoded = match avif_decode_animation_planes(data, limits~) {
    Some(value) => value
    None => return None
  }
  let frames = FixedArray::makei(decoded.color.length(), fn(i) {
    let timing = decoded.descriptor.frames[i]
    AvifNativeAnimationFrame::{
      index: i,
      timestamp: timing.timestamp,
      duration: timing.duration,
      timescale: timing.timescale,
      image: {
        color: av1_frame_to_native(decoded.color[i]),
        alpha: decoded.alpha.map(planes => av1_frame_to_native(planes[i])),
        premultiplied: decoded.premultiplied,
      },
    }
  })
  Some({ timescale: decoded.descriptor.timescale, frames, })
}

///|
/// Select a frame without decoding again. timestamp uses this animation's
/// timescale, not milliseconds, and loops modulo the total duration.
/// Intervals include their start and exclude their end; negative timestamps
/// or caller-reordered/noncontiguous timing return None.
/// Returns the stored frame: its buffers alias frames[index], with no copy.
pub fn AvifNativeAnimation::frame_at(
  self : AvifNativeAnimation,
  timestamp : Int,
) -> AvifNativeAnimationFrame? {
  if timestamp < 0 || self.timescale <= 0 || self.frames.length() == 0 {
    return None
  }
  let mut total = 0
  for i in 0..<self.frames.length() {
    let frame = self.frames[i]
    if frame.index != i ||
      frame.timescale != self.timescale ||
      frame.timestamp != total ||
      frame.duration <= 0 ||
      frame.duration > 0x7FFFFFFF - total {
      return None
    }
    total = total + frame.duration
  }
  let t = timestamp % total
  for frame in self.frames {
    if t < frame.timestamp + frame.duration {
      return Some(frame)
    }
  }
  None
}
