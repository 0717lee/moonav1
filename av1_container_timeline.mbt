///|
/// An exact, unreduced rational timestamp. `denominator` is always positive;
/// callers can compare two values by checked cross multiplication or retain
/// the fraction when a movie tick does not land on an integer media tick.
pub struct Av1RationalTime {
  numerator : Int64
  denominator : Int64
} derive(Eq, Debug)

///|
/// Mapping a movie presentation tick through an explicit MP4 edit list.
/// Empty edits intentionally carry no media time. End is returned after the
/// final edit; an edit list is interpreted as half-open movie intervals.
pub(all) enum Av1PresentationPoint {
  Empty
  Media(Av1RationalTime)
  End
} derive(Eq, Debug)

///|
/// An explicit presentation timeline for one demuxed track. An empty edit
/// list is retained as raw media timing and does not synthesize a default
/// MP4 edit. For an explicit edit list, movie ticks are mapped to media ticks
/// with exact rational arithmetic and unit playback rate.
pub struct Av1PresentationTimeline {
  priv media_timescale : Int64
  priv movie_timescale : Int64?
  priv edits : Array[Av1TrackEdit]
}

///|
let av1_timeline_i64_max : Int64 = 9223372036854775807L

///|
let av1_timeline_i64_min : Int64 = -9223372036854775807L - 1L

///|
fn av1_timeline_error(kind : DecodeErrorKind, message : String) -> DecodeError {
  decode_error(kind, "container.timeline", message)
}

///|
fn av1_timeline_add(a : Int64, b : Int64) -> Result[Int64, DecodeError] {
  if (b > 0L && a > av1_timeline_i64_max - b) ||
    (b < 0L && a < av1_timeline_i64_min - b) {
    return Err(
      av1_timeline_error(
        LimitExceeded,
        "Presentation timeline arithmetic overflows Int64",
      ),
    )
  }
  Ok(a + b)
}

///|
fn av1_timeline_sub(a : Int64, b : Int64) -> Result[Int64, DecodeError] {
  if b == av1_timeline_i64_min {
    return Err(
      av1_timeline_error(
        LimitExceeded,
        "Presentation timeline subtraction overflows Int64",
      ),
    )
  }
  av1_timeline_add(a, -b)
}

///|
fn av1_timeline_mul(a : Int64, b : Int64) -> Result[Int64, DecodeError] {
  if a == 0L || b == 0L {
    return Ok(0L)
  }
  if (a == av1_timeline_i64_min && b == -1L) ||
    (b == av1_timeline_i64_min && a == -1L) {
    return Err(
      av1_timeline_error(
        LimitExceeded,
        "Presentation timeline multiplication overflows Int64",
      ),
    )
  }
  let overflow = if a > 0L {
    if b > 0L {
      a > av1_timeline_i64_max / b
    } else {
      a > av1_timeline_i64_min / b
    }
  } else if b > 0L {
    a < av1_timeline_i64_min / b
  } else {
    a < av1_timeline_i64_max / b
  }
  if overflow {
    Err(
      av1_timeline_error(
        LimitExceeded,
        "Presentation timeline multiplication overflows Int64",
      ),
    )
  } else {
    Ok(a * b)
  }
}

///|
/// Construct the explicit presentation mapping for a demuxed track. The
/// demuxer already validates MP4 edit syntax and currently emits unit-rate
/// edits; this layer validates the timescale relationship and retains each
/// edit, including repeated and empty entries, without rewriting it.
pub fn Av1PresentationTimeline::new(
  track : Av1DemuxedTrack,
) -> Result[Av1PresentationTimeline, DecodeError] {
  if track.timescale <= 0L {
    return Err(
      av1_timeline_error(InvalidData, "Track timescale must be positive"),
    )
  }
  if track.edits.length() > 0 && track.movie_timescale is None {
    return Err(
      av1_timeline_error(
        InvalidData,
        "An explicit edit list requires a positive movie timescale",
      ),
    )
  }
  match track.movie_timescale {
    Some(value) =>
      if value <= 0L {
        return Err(
          av1_timeline_error(InvalidData, "Movie timescale must be positive"),
        )
      }
    None => ()
  }
  for edit in track.edits {
    if edit.duration < 0L || edit.media_time < -1L {
      return Err(
        av1_timeline_error(
          InvalidData,
          "Edit duration or media time is invalid",
        ),
      )
    }
    if edit.media_rate != 65536 {
      return Err(
        av1_timeline_error(
          Unsupported,
          "Only unit-rate edit lists are supported by the timeline",
        ),
      )
    }
  }
  Ok({
    media_timescale: track.timescale,
    movie_timescale: track.movie_timescale,
    edits: track.edits.copy(),
  })
}

///|
pub fn Av1PresentationTimeline::media_timescale(
  self : Av1PresentationTimeline,
) -> Int64 {
  self.media_timescale
}

///|
pub fn Av1PresentationTimeline::movie_timescale(
  self : Av1PresentationTimeline,
) -> Int64? {
  self.movie_timescale
}

///|
/// True when the source supplied an edit list. False means raw media timing
/// is intentionally in force, even if the movie has a movie timescale.
pub fn Av1PresentationTimeline::has_edits(
  self : Av1PresentationTimeline,
) -> Bool {
  !self.edits.is_empty()
}

///|
pub fn Av1PresentationTimeline::edit_count(
  self : Av1PresentationTimeline,
) -> Int {
  self.edits.length()
}

///|
/// Map one movie tick to the exact media timestamp selected by the edit list.
/// For an empty edit the result is `Empty`; after the final edit it is `End`.
/// With no edits, the input is already a raw media tick and is returned as an
/// integer rational, preserving the decoder's default media-timeline policy.
pub fn Av1PresentationTimeline::map_movie_time(
  self : Av1PresentationTimeline,
  movie_time : Int64,
) -> Result[Av1PresentationPoint, DecodeError] {
  if movie_time < 0L {
    return Err(
      av1_timeline_error(InvalidData, "Movie time must not be negative"),
    )
  }
  if self.edits.is_empty() {
    return Ok(Media({ numerator: movie_time, denominator: 1L, }))
  }
  let movie_scale = match self.movie_timescale {
    Some(value) => value
    None =>
      return Err(
        av1_timeline_error(InvalidData, "Edit list has no movie timescale"),
      )
  }
  let mut cursor = 0L
  for edit in self.edits {
    let end = match av1_timeline_add(cursor, edit.duration) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if movie_time < end {
      if edit.media_time == -1L {
        return Ok(Empty)
      }
      let offset = match av1_timeline_sub(movie_time, cursor) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let base = match av1_timeline_mul(edit.media_time, movie_scale) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let advance = match av1_timeline_mul(offset, self.media_timescale) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let numerator = match av1_timeline_add(base, advance) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      return Ok(Media({ numerator, denominator: movie_scale, }))
    }
    cursor = end
  }
  Ok(End)
}
