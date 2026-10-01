///|
/// InvalidData includes failures for which the decoder cannot identify a more
/// specific cause. Unsupported is never guessed from an opaque syntax failure.
pub(all) enum DecodeErrorKind {
  InvalidData
  TruncatedInput
  Unsupported
  MissingSequence
  MissingReference
  LimitExceeded
  InvalidState
  InvalidBuffer
  NoPresentation
} derive(Eq, Debug)

///|
/// Zero-based checked field or failing payload start, not a bit-level entropy
/// position. Incremental input uses absolute stream offsets. None is used when
/// an assembled AVIF payload cannot be mapped to one container byte location.
pub struct DecodeError {
  kind : DecodeErrorKind
  byte_offset : Int64?
  context : String
  message : String
} derive(Eq, Debug)

///|
fn decode_error(
  kind : DecodeErrorKind,
  context : String,
  message : String,
  offset? : Int? = None,
) -> DecodeError {
  {
    kind,
    context,
    message,
    byte_offset: offset.map(value => value.to_int64()),
  }
}

///|
priv struct DecodeDiagnostic {
  mut context : String
  mut byte_offset : Int64?
  mut error : DecodeError?
}

///|
fn decode_context(
  budget : DecodeBudget?,
  context : String,
  offset : Int?,
) -> Unit {
  match budget {
    Some({ diagnostic: Some(trace), .. }) => {
      trace.context = context
      trace.byte_offset = offset.map(value => value.to_int64())
    }
    _ => ()
  }
}

///|
fn decode_fail(
  budget : DecodeBudget?,
  kind : DecodeErrorKind,
  message : String,
) -> Unit {
  match budget {
    Some({ diagnostic: Some(trace), .. }) =>
      if trace.error is None {
        trace.error = Some({
          kind,
          byte_offset: trace.byte_offset,
          context: trace.context,
          message,
        })
      }
    _ => ()
  }
}

///|
fn decode_record_error(budget : DecodeBudget?, error : DecodeError) -> Unit {
  match budget {
    Some({ diagnostic: Some(trace), .. }) => trace.error = Some(error)
    _ => ()
  }
}

///|
fn decode_trace_error(trace : DecodeDiagnostic?, error : DecodeError) -> Unit {
  match trace {
    Some(value) => value.error = Some(error)
    None => ()
  }
}

///|
fn avif_boxes_result(data : Array[Byte]) -> Result[Array[Box], DecodeError] {
  try {
    let boxes : Array[Box] = []
    walk(data, 0, data.length(), -1, boxes)
    Ok(boxes)
  } catch {
    AvifError::Diagnostic(error) => Err(error)
    AvifError::Unsupported =>
      Err(
        decode_error(
          Unsupported,
          "container",
          "Unsupported container size or syntax",
        ),
      )
    _ =>
      Err(decode_error(InvalidData, "container", "Invalid container structure"))
  }
}

///|
pub fn avif_container_parse_result(
  data : Array[Byte],
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[AvifContainer, DecodeError] {
  let budget = match decode_checked_budget(data.length(), limits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    avif_container_parse_limited(
      data,
      limits=Some(limits),
      diagnostic=budget.diagnostic,
    ) {
    Some(container) => Ok(container)
    None => Err(decode_failure(budget))
  }
}

///|
fn avif_decode_checked_planes(
  data : Array[Byte],
  limits : DecodeLimits,
) -> Result[(Av1FramePlanes, Av1FramePlanes?, Bool), DecodeError] {
  let budget = match decode_checked_budget(data.length(), limits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // Envelope validation retains exact container field positions before the
  // existing independent color/alpha parsers resolve item associations.
  match avif_boxes_result(data) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match
    avif_decode_image_planes(data, limits=Some(limits), budget=Some(budget)) {
    Some(planes) => Ok(planes)
    None => {
      let error = decode_failure(budget)
      if error.context == "container" {
        Err(error)
      } else {
        Err({ ..error, byte_offset: None, context: "avif/" + error.context, })
      }
    }
  }
}

///|
pub fn avif_decode_native_result(
  data : Array[Byte],
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[AvifNativeImage, DecodeError] {
  match avif_decode_checked_planes(data, limits) {
    Err(error) => Err(error)
    Ok((color, alpha, premultiplied)) =>
      Ok({
        color: av1_frame_to_native(color),
        alpha: alpha.map(av1_frame_to_native),
        premultiplied,
      })
  }
}

///|
pub fn avif_decode_rgba_result(
  data : Array[Byte],
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[Image, DecodeError] {
  match avif_decode_checked_planes(data, limits) {
    Err(error) => Err(error)
    Ok((color, alpha, premultiplied)) => {
      let converted = match alpha {
        Some(plane) => av1_frame_with_alpha(color, plane, premultiplied)
        None => av1_frame_to_rgba(color)
      }
      match converted {
        Some(image) => Ok(image)
        None =>
          Err(
            decode_error(
              if av1_color_supported(
                  color.matrix_coefficients,
                  color.color_primaries,
                  color.transfer_characteristics,
                ) {
                InvalidData
              } else {
                Unsupported
              },
              "color",
              "RGBA8 conversion failed",
            ),
          )
      }
    }
  }
}

///|
pub fn avif_decode_rgba16_result(
  data : Array[Byte],
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[Image16, DecodeError] {
  match avif_decode_native_result(data, limits~) {
    Err(error) => Err(error)
    Ok(image) =>
      match image.to_rgba16() {
        Some(value) => Ok(value)
        None =>
          Err(
            decode_error(
              if av1_color_supported(
                  image.color.matrix_coefficients,
                  image.color.color_primaries,
                  image.color.transfer_characteristics,
                ) {
                InvalidData
              } else {
                Unsupported
              },
              "color",
              "RGBA16 conversion failed",
            ),
          )
      }
  }
}

///|
pub fn av1_decode_result(
  data : Array[Byte],
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[Image, DecodeError] {
  let budget = match decode_checked_budget(data.length(), limits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match av1_decode_checked_planes(av1_video_decoder(), data, true, budget) {
    Err(error) => Err(error)
    Ok(frames) => {
      if frames.is_empty() {
        return Err(
          decode_error(NoPresentation, "presentation", "No displayed picture"),
        )
      }
      let frame = frames[0]
      match av1_frame_to_rgba(frame) {
        Some(image) => Ok(image)
        None =>
          Err(
            decode_error(
              if av1_color_supported(
                  frame.matrix_coefficients,
                  frame.color_primaries,
                  frame.transfer_characteristics,
                ) {
                InvalidData
              } else {
                Unsupported
              },
              "color",
              "RGBA8 conversion failed",
            ),
          )
      }
    }
  }
}

///|
fn decode_failure(budget : DecodeBudget) -> DecodeError {
  match budget.diagnostic {
    Some(trace) =>
      match trace.error {
        Some(error) => error
        None =>
          {
            kind: InvalidData,
            byte_offset: trace.byte_offset,
            context: trace.context,
            message: "Syntax or reconstruction validation failed",
          }
      }
    None =>
      decode_error(
        InvalidData,
        "decode",
        "Syntax or reconstruction validation failed",
      )
  }
}

///|
fn decode_checked_budget(
  length : Int,
  limits : DecodeLimits,
) -> Result[DecodeBudget, DecodeError] {
  if !decode_input_allowed(0, Some(limits)) {
    return Err(
      decode_error(
        InvalidData,
        "limits",
        "DecodeLimits fields must be positive and within the hard picture limit",
      ),
    )
  }
  if length > limits.max_input_bytes {
    return Err(
      decode_error(
        LimitExceeded,
        "input",
        "Compressed input exceeds max_input_bytes",
      ),
    )
  }
  Ok({
    limits,
    frames_left: limits.max_frames,
    pixels_left: limits.max_total_pixels,
    diagnostic: Some({ context: "decode", byte_offset: None, error: None, }),
  })
}

///|
fn av1_decode_checked_planes(
  decoder : Av1VideoDecoder,
  data : Array[Byte],
  allow_monochrome : Bool,
  budget : DecodeBudget,
) -> Result[Array[Av1FramePlanes], DecodeError] {
  if data.is_empty() && decoder.sequence is None {
    return Err(
      decode_error(TruncatedInput, "input", "Empty AV1 input", offset=Some(0)),
    )
  }
  match
    av1_video_decode_temporal_unit_planes(
      decoder,
      data,
      allow_monochrome~,
      budget=Some(budget),
    ) {
    Some(frames) => Ok(frames)
    None => Err(decode_failure(budget))
  }
}

///|
/// Valid hidden-only input returns Ok([]). Any Err requires discarding/resetting
/// the decoder: reference updates are not transactional, as in the Option API.
pub fn av1_video_decode_temporal_unit_native_result(
  decoder : Av1VideoDecoder,
  data : Array[Byte],
  allow_monochrome? : Bool = false,
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[Array[Av1NativeFrame], DecodeError] {
  let budget = match decode_checked_budget(data.length(), limits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match av1_decode_checked_planes(decoder, data, allow_monochrome, budget) {
    Ok(frames) => Ok(frames.map(av1_frame_to_native))
    Err(error) => Err(error)
  }
}

///|
pub fn av1_decode_native_result(
  data : Array[Byte],
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[Av1NativeFrame, DecodeError] {
  match
    av1_video_decode_temporal_unit_native_result(
      av1_video_decoder(),
      data,
      allow_monochrome=true,
      limits~,
    ) {
    Err(error) => Err(error)
    Ok(frames) =>
      if frames.is_empty() {
        Err(
          decode_error(NoPresentation, "presentation", "No displayed picture"),
        )
      } else {
        Ok(frames[0])
      }
  }
}

///|
pub fn av1_decode_rgba16_result(
  data : Array[Byte],
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[Image16, DecodeError] {
  match av1_decode_native_result(data, limits~) {
    Err(error) => Err(error)
    Ok(frame) =>
      match frame.to_rgba16() {
        Some(image) => Ok(image)
        None =>
          Err(
            decode_error(
              if av1_color_supported(
                  frame.matrix_coefficients,
                  frame.color_primaries,
                  frame.transfer_characteristics,
                ) {
                InvalidData
              } else {
                Unsupported
              },
              "color",
              "RGBA16 conversion failed",
            ),
          )
      }
  }
}
