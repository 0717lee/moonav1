/// OBU envelopes and frame assembly. Payload bytes retain their layer IDs until
/// the selected operating point has accepted them and frame syntax consumes it.

///|
priv struct Av1ObuPacket {
  kind : Int
  extension : Bool
  temporal_id : Int
  spatial_id : Int
  offset : Int
  payload_offset : Int
  payload : Array[Byte]
}

///|
fn av1_obu_packets(
  data : Array[Byte],
  budget? : DecodeBudget? = None,
) -> Array[Av1ObuPacket]? {
  let limit = match budget {
    Some(value) => value.limits.max_input_bytes
    None => 0x7FFFFFFF
  }
  match av1_obu_packets_checked(data, limit~) {
    Ok(packets) => Some(packets)
    Err(error) => {
      decode_record_error(budget, error)
      None
    }
  }
}

///|
/// OBUs without an extension are not filtered by layer, as specified by
/// open_bitstream_unit(). The default chosen operating point is index zero.
fn av1_obu_selected(
  packet : Av1ObuPacket,
  sequence : Av1SequenceInfo,
  operating_point? : Int = 0,
) -> Bool {
  if operating_point < 0 ||
    operating_point >= sequence.operating_point_idc.length() {
    return false
  }
  if packet.kind == 1 || packet.kind == 2 || !packet.extension {
    return true
  }
  let idc = sequence.operating_point_idc[operating_point]
  idc == 0 ||
  (
    ((idc >> packet.temporal_id) & 1) != 0 &&
    ((idc >> (packet.spatial_id + 8)) & 1) != 0
  )
}

///|
fn av1_obu_trailing_bits(data : Array[Byte], bit_pos : Int) -> Bool {
  let bits : Av1FrameBits = { data, bit_pos, }
  if bits.take(1) != Some(1) {
    return false
  }
  while bits.bit_pos < data.length() * 8 {
    if bits.take(1) != Some(0) {
      return false
    }
  }
  true
}

///|
/// Assemble complete, sequential tile groups into the existing tile decoder's
/// raster payload. A group's last tile has no size prefix; add a four-byte
/// prefix when another group follows, so no original prefix-width limit is
/// imposed on that tile. The caller sets its normalized TileSizeBytes to four.
fn av1_assemble_tile_groups(
  groups : Array[Array[Byte]],
  tile_cols : Int,
  tile_rows : Int,
  tile_bits : Int,
  tile_size_bytes : Int,
) -> Array[Byte]? {
  let count = tile_cols * tile_rows
  if count <= 0 ||
    count > 4096 ||
    groups.is_empty() ||
    (
      count > 1 &&
      (
        tile_bits <= 0 ||
        tile_bits > 12 ||
        tile_size_bytes < 1 ||
        tile_size_bytes > 4
      )
    ) {
    return None
  }
  let out : Array[Byte] = []
  let mut next_tile = 0
  for payload in groups {
    let bits : Av1FrameBits = { data: payload, bit_pos: 0, }
    let explicit_range = if count > 1 {
      match bits.take(1) {
        Some(value) => value == 1
        None => return None
      }
    } else {
      false
    }
    let (start, end) = if explicit_range {
      let start = match bits.take(tile_bits) {
        Some(value) => value
        None => return None
      }
      let end = match bits.take(tile_bits) {
        Some(value) => value
        None => return None
      }
      (start, end)
    } else {
      (0, count - 1)
    }
    if start != next_tile || end < start || end >= count {
      return None
    }
    while (bits.bit_pos & 7) != 0 {
      if bits.take(1) != Some(0) {
        return None
      }
    }
    let mut pos = bits.bit_pos / 8
    for tile in start..<=end {
      let size = if tile == end {
        payload.length() - pos
      } else {
        if tile_size_bytes > payload.length() - pos {
          return None
        }
        let mut minus_one = 0
        for byte in 0..<tile_size_bytes {
          let value = payload[pos + byte].to_int()
          // Tile data and all output allocations fit positive signed Int.
          if byte == 3 && value >= 128 {
            return None
          }
          minus_one = minus_one | (value << (8 * byte))
        }
        pos = pos + tile_size_bytes
        if minus_one >= payload.length() - pos {
          return None
        }
        minus_one + 1
      }
      if size <= 0 || size > payload.length() - pos {
        return None
      }
      if tile != count - 1 {
        for byte in 0..<4 {
          out.push((((size - 1) >> (byte * 8)) & 255).to_byte())
        }
      }
      for index in pos..<(pos + size) {
        out.push(payload[index])
      }
      pos = pos + size
    }
    if pos != payload.length() {
      return None
    }
    next_tile = end + 1
  }
  if next_tile == count {
    Some(out)
  } else {
    None
  }
}

///|
/// A key-frame show-existing operation performs reference_frame_loading and
/// refreshes all eight slots. Saved pixels and syntax are already immutable
/// snapshots; copy the mutable metadata arrays with the same contents.
fn av1_show_existing_refresh(
  map : Av1FrameMap,
  slot : Int,
  frame : Av1RefFrame,
) -> Unit {
  if frame.frame_type != av1_key_frame {
    return
  }
  map.current_frame_id = frame.frame_id
  let segmentation = map.saved_segmentation[slot]
  let segments = map.saved_segment_ids[slot]
  let grain = map.saved_film_grain[slot]
  for target in 0..<av1_num_ref_frames {
    map.slots[target] = Some(frame)
    map.valid[target] = true
    map.order_hints[target] = frame.order_hint
    map.frame_types[target] = frame.frame_type
    map.frame_ids[target] = frame.frame_id
    map.upscaled_widths[target] = frame.upscaled_width
    map.frame_widths[target] = frame.frame_width
    map.frame_heights[target] = frame.frame_height
    map.render_widths[target] = frame.render_width
    map.render_heights[target] = frame.render_height
    map.saved_gm_params[target] = frame.gm_params
    map.saved_loop_filter_ref_deltas[target] = frame.loop_filter_ref_deltas.copy()
    map.saved_loop_filter_mode_deltas[target] = frame.loop_filter_mode_deltas.copy()
    map.saved_segmentation[target] = av1_segmentation_copy(segmentation)
    map.saved_segment_ids[target] = segments.copy()
    map.saved_film_grain[target] = grain.map(av1_frame_grain_copy)
    map.saved_showable[target] = false
  }
  map.saved_cdfs = frame.cdfs.map(av1_frame_cdfs_copy)
}

///|
fn av1_show_existing_planes(
  packet : Av1ObuPacket,
  sequence : Av1SequenceInfo,
  map : Av1FrameMap,
  budget? : DecodeBudget? = None,
) -> Av1FramePlanes? {
  // OBU_FRAME always includes tile syntax; show-existing is a frame-header OBU.
  if packet.kind != 3 {
    return None
  }
  let envelope = match
    av1_parse_show_existing_frame(packet.payload, {
      decoder_model_info_present: sequence.decoder_model_info_present,
      equal_picture_interval: sequence.equal_picture_interval,
      frame_presentation_time_length_minus_1: sequence.frame_presentation_time_length_minus_1,
      frame_id_numbers_present: sequence.frame_id_numbers_present,
      additional_frame_id_len_minus1: sequence.additional_frame_id_length_minus_1,
      delta_frame_id_length_minus2: sequence.delta_frame_id_length_minus_2,
      reference_frame_types: map.frame_types,
    }) {
    Some(value) => value
    None => return None
  }
  if !av1_obu_trailing_bits(packet.payload, envelope.header_bits) {
    return None
  }
  let slot = envelope.frame_to_show_map_idx
  if !map.saved_showable[slot] {
    return None
  }
  let reference = match av1_frame_map_show(map, slot) {
    Some(value) => value
    None => return None
  }
  if !decode_reserve(budget, reference.width, reference.height) {
    return None
  }
  match envelope.display_frame_id {
    Some(id) => if id != reference.frame_id { return None }
    None => ()
  }
  let frame : Av1FramePlanes = {
    width: reference.width,
    height: reference.height,
    coded_width: reference.coded_width,
    bit_depth: reference.bit_depth,
    full_range: sequence.full_range,
    matrix_coefficients: sequence.matrix_coefficients,
    color_primaries: sequence.color_primaries,
    transfer_characteristics: sequence.transfer_characteristics,
    sub_x: reference.sub_x,
    sub_y: reference.sub_y,
    planes: reference.planes,
  }
  let grain = map.saved_film_grain[slot]
  av1_show_existing_refresh(map, slot, reference)
  match grain {
    None => Some(frame)
    Some(params) =>
      av1_frame_apply_grain(
        frame,
        params,
        sequence.monochrome,
        sequence.subsampling_x,
        sequence.subsampling_y,
      )
  }
}

///|
/// Decode frame OBUs in order and present the highest spatial layer actually
/// present in each temporal unit of the selected operating point (AV1 §7.18.1).
/// An explicit spatial layer limits presentation; every decoded layer and hidden
/// frame still updates references. Temporal delimiters separate units; the input
/// end closes the final unit, as for an ISOBMFF sample without a TD.
fn av1_decode_obu_planes(
  data : Array[Byte],
  map : Av1FrameMap,
  sequence : Av1SequenceInfo?,
  allow_monochrome : Bool,
  operating_point? : Int = 0,
  spatial_layer? : Int? = None,
  budget? : DecodeBudget? = None,
) -> (Av1SequenceInfo, Array[Av1FramePlanes])? {
  if operating_point < 0 || operating_point > 31 {
    return None
  }
  match spatial_layer {
    Some(layer) => if layer < 0 || layer > 3 { return None }
    None => ()
  }
  match sequence {
    Some(seq) =>
      if operating_point >= seq.operating_point_idc.length() {
        return None
      }
    None => ()
  }
  let packets = match av1_obu_packets(data, budget~) {
    Some(value) => value
    None => return None
  }
  let displayed : Array[Av1FramePlanes] = []
  let mut selected : Av1FramePlanes? = None
  let mut selected_spatial = -1
  let mut active = sequence
  let mut index = 0
  while index < packets.length() {
    let packet = packets[index]
    decode_context(budget, "obu", Some(packet.offset))
    index = index + 1
    if packet.kind == 1 {
      decode_context(budget, "sequence_header", Some(packet.payload_offset))
      active = av1_parse_sequence_payload(packet.payload)
      match active {
        Some(seq) =>
          if operating_point >= seq.operating_point_idc.length() {
            return None
          }
        None => return None
      }
      continue
    }
    if packet.kind == 2 {
      match selected {
        Some(frame) => displayed.push(frame)
        None => ()
      }
      selected = None
      selected_spatial = -1
      continue
    }
    let seq = match active {
      Some(value) => value
      None => {
        decode_fail(
          budget,
          MissingSequence,
          "A sequence header is required before frame decoding",
        )
        return None
      }
    }
    if !av1_obu_selected(packet, seq, operating_point~) {
      continue
    }
    if packet.kind != 3 && packet.kind != 6 {
      if packet.kind == 4 || packet.kind == 7 || packet.kind == 8 {
        decode_fail(
          budget,
          if packet.kind == 8 {
            Unsupported
          } else {
            InvalidData
          },
          "Unexpected tile group, redundant header or tile-list OBU",
        )
        return None
      }
      continue
    }
    if packet.payload.is_empty() || (seq.monochrome && !allow_monochrome) {
      decode_fail(
        budget,
        if packet.payload.is_empty() {
          TruncatedInput
        } else {
          Unsupported
        },
        "Empty frame payload or monochrome was not enabled",
      )
      return None
    }
    decode_context(budget, "frame_header", Some(packet.payload_offset))
    if !seq.reduced_still_picture_header &&
      (packet.payload[0].to_int() & 128) != 0 {
      let slot = (packet.payload[0].to_int() >> 4) & 7
      if !map.valid[slot] || map.slots[slot] is None {
        decode_fail(
          budget,
          MissingReference,
          "show-existing names an unavailable reference slot",
        )
      }
      match av1_show_existing_planes(packet, seq, map, budget~) {
        Some(frame) =>
          if packet.spatial_id >= selected_spatial &&
            (spatial_layer is None || spatial_layer == Some(packet.spatial_id)) {
            selected = Some(frame)
            selected_spatial = packet.spatial_id
          }
        None => return None
      }
      continue
    }
    let groups : Array[Array[Byte]] = []
    if packet.kind == 3 {
      while index < packets.length() {
        let next = packets[index]
        if !av1_obu_selected(next, seq, operating_point~) {
          index = index + 1
          continue
        }
        if next.kind == 1 || next.kind == 2 || next.kind == 3 || next.kind == 6 {
          break
        }
        index = index + 1
        if next.kind == 4 || next.kind == 7 {
          if next.extension != packet.extension ||
            next.temporal_id != packet.temporal_id ||
            next.spatial_id != packet.spatial_id {
            return None
          }
          if next.kind == 4 {
            groups.push(next.payload)
          } else if next.payload != packet.payload {
            return None
          }
        } else if next.kind == 8 {
          return None
        }
      }
    }
    let header = match
      av1_parse_stage1_frame(
        packet.payload,
        seq,
        allow_highbd=true,
        allow_monochrome~,
        map~,
        frame_header_obu=packet.kind == 3,
        tile_groups=groups,
        temporal_id=packet.temporal_id,
        spatial_id=packet.spatial_id,
      ) {
      Some(value) => value
      None => {
        if !seq.reduced_still_picture_header &&
          ((packet.payload[0].to_int() >> 5) & 3) % 2 == 1 &&
          !map.valid.any(value => value) {
          decode_fail(
            budget,
            MissingReference,
            "Inter picture has no decoded references",
          )
        }
        return None
      }
    }
    decode_context(budget, "reconstruction", Some(packet.payload_offset))
    let decoded = match
      av1_decode_parsed_frame_planes(header, seq, map, budget~) {
      Some(value) => value
      None => return None
    }
    if header.show_frame {
      let frame = match header.film_grain {
        None => decoded
        Some(params) => {
          let frame = match
            av1_frame_apply_grain(
              decoded,
              params,
              seq.monochrome,
              seq.subsampling_x,
              seq.subsampling_y,
            ) {
            Some(value) => value
            None => return None
          }
          frame
        }
      }
      if packet.spatial_id >= selected_spatial &&
        (spatial_layer is None || spatial_layer == Some(packet.spatial_id)) {
        selected = Some(frame)
        selected_spatial = packet.spatial_id
      }
    }
  }
  match selected {
    Some(frame) => displayed.push(frame)
    None => ()
  }
  match active {
    Some(seq) => Some((seq, displayed))
    None => None
  }
}
