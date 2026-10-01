///|
priv struct AvifMetadataBuilder {
  mut icc : FixedArray[Byte]?
  mut exif : FixedArray[Byte]?
  mut exif_tiff_offset : Int?
  mut xmp : FixedArray[Byte]?
  mut aspect : (Int64, Int64)?
  transforms : Array[AvifDisplayTransform]
  mut remaining : Int
}

///|
fn metadata_builder(limit : Int) -> AvifMetadataBuilder {
  {
    icc: None,
    exif: None,
    exif_tiff_offset: None,
    xmp: None,
    aspect: None,
    transforms: [],
    remaining: limit,
  }
}

///|
fn metadata_finish(
  builder : AvifMetadataBuilder,
  primary : Int?,
  track : Int?,
) -> AvifMetadata {
  {
    primary_item_id: primary,
    track_id: track,
    icc: builder.icc,
    exif: builder.exif,
    exif_tiff_offset: builder.exif_tiff_offset,
    xmp: builder.xmp,
    pixel_aspect_ratio: builder.aspect,
    transforms: FixedArray::from_array(builder.transforms),
  }
}

///|
fn metadata_u32(
  data : Array[Byte],
  at : Int,
  end : Int,
) -> Int64 raise AvifError {
  let mut value = 0L
  for i in 0..<4 {
    value = value * 256L + u8(data, at + i, end).to_int64()
  }
  value
}

///|
fn metadata_blob(
  builder : AvifMetadataBuilder,
  data : Array[Byte],
  start : Int,
  end : Int,
) -> FixedArray[Byte] raise AvifError {
  if start < 0 || end < start || end > data.length() {
    raise AvifError::Invalid
  }
  if end - start > builder.remaining {
    raise AvifError::Diagnostic(
      decode_error(
        LimitExceeded,
        "metadata",
        "Combined exposed metadata exceeds max_input_bytes",
      ),
    )
  }
  builder.remaining -= end - start
  FixedArray::makei(end - start, i => data[start + i])
}

///|
fn metadata_property(
  builder : AvifMetadataBuilder,
  data : Array[Byte],
  box : Box,
) -> Unit raise AvifError {
  let p = box.payload
  let n = box.end - p
  if box.typ == t_colr {
    let kind = u32(data, p, box.end)
    if kind == 0x70726F66 || kind == 0x72494343 { // prof / rICC
      if builder.icc is Some(_) || n <= 4 {
        raise AvifError::Invalid
      }
      builder.icc = Some(metadata_blob(builder, data, p + 4, box.end))
    }
  } else if box.typ == 0x70617370 { // pasp
    if n != 8 || builder.aspect is Some(_) {
      raise AvifError::Invalid
    }
    let h = metadata_u32(data, p, box.end)
    let v = metadata_u32(data, p + 4, box.end)
    if h == 0L || v == 0L {
      raise AvifError::Invalid
    }
    builder.aspect = Some((h, v))
  } else if box.typ == 0x69726F74 { // irot
    if n != 1 || u8(data, p, box.end) > 3 {
      raise AvifError::Invalid
    }
    builder.transforms.push(Rotate(u8(data, p, box.end)))
  } else if box.typ == 0x696D6972 { // imir
    if n != 1 || u8(data, p, box.end) > 1 {
      raise AvifError::Invalid
    }
    builder.transforms.push(Mirror(u8(data, p, box.end)))
  } else if box.typ == 0x636C6170 { // clap
    if n != 32 {
      raise AvifError::Invalid
    }
    let crop : AvifCleanAperture = {
      width_n: metadata_u32(data, p, box.end),
      width_d: metadata_u32(data, p + 4, box.end),
      height_n: metadata_u32(data, p + 8, box.end),
      height_d: metadata_u32(data, p + 12, box.end),
      horizontal_n: u32(data, p + 16, box.end).to_int64(),
      horizontal_d: metadata_u32(data, p + 20, box.end),
      vertical_n: u32(data, p + 24, box.end).to_int64(),
      vertical_d: metadata_u32(data, p + 28, box.end),
    }
    if crop.width_n == 0L ||
      crop.width_d == 0L ||
      crop.height_n == 0L ||
      crop.height_d == 0L ||
      crop.horizontal_d == 0L ||
      crop.vertical_d == 0L {
      raise AvifError::Invalid
    }
    builder.transforms.push(Crop(crop))
  }
}

///|
fn metadata_string_end(
  data : Array[Byte],
  start : Int,
  end : Int,
) -> Int raise AvifError {
  for p in start..<end {
    if data[p] == b'\x00' {
      return p + 1
    }
  }
  raise AvifError::Diagnostic(
    decode_error(
      TruncatedInput,
      "metadata",
      "Unterminated item string",
      offset=Some(end),
    ),
  )
}

///|
fn metadata_string_equals(
  data : Array[Byte],
  start : Int,
  end : Int,
  expected : String,
) -> Bool {
  let chars = expected.to_array()
  if end - start != chars.length() + 1 {
    return false
  }
  for i in 0..<chars.length() {
    if data[start + i].to_int() != chars[i].to_int() {
      return false
    }
  }
  true
}

///|
fn metadata_item_payload(
  data : Array[Byte],
  item : Item,
  idat : Box?,
  limit : Int,
) -> Array[Byte] raise AvifError {
  let output : Array[Byte] = []
  for i in 0..<item.offs.length() {
    let (base, end) = if item.method_id == 1 {
      match idat {
        Some(box) => (box.payload, box.end)
        None => raise AvifError::Invalid
      }
    } else {
      (0, data.length())
    }
    let length = item.lens[i]
    if length < 0 || length > limit - output.length() {
      raise AvifError::Diagnostic(
        decode_error(
          LimitExceeded,
          "metadata",
          "Metadata extents exceed the byte budget",
        ),
      )
    }
    if item.base < 0 ||
      item.offs[i] < 0 ||
      base > end - length ||
      item.base > end - length - base ||
      item.offs[i] > end - length - base - item.base {
      raise AvifError::Invalid
    }
    let offset = base + item.base + item.offs[i]
    for p in offset..<(offset + length) {
      output.push(data[p])
    }
  }
  output
}

///|
fn metadata_descriptions(
  data : Array[Byte],
  boxes : Array[Box],
  meta : Box,
  primary : Int,
) -> Array[Int] raise AvifError {
  let linked : Array[Int] = []
  let iref = match find_box(boxes, idx_box(boxes, meta.start), 0x69726566) {
    Some(value) => value
    None => return linked
  }
  let version = u8(data, iref.payload, iref.end)
  if version > 1 {
    raise AvifError::Unsupported
  }
  let refs : Array[Box] = []
  walk(data, iref.payload + 4, iref.end, -1, refs)
  for reference in refs {
    if reference.parent != -1 || reference.typ != 0x63647363 {
      continue
    }
    let size = if version == 0 { 2 } else { 4 }
    let from = if size == 2 {
      u16(data, reference.payload, reference.end)
    } else {
      u32(data, reference.payload, reference.end)
    }
    let count = u16(data, reference.payload + size, reference.end)
    let start = reference.payload + size + 2
    if count > (reference.end - start) / size {
      raise AvifError::Invalid
    }
    for i in 0..<count {
      let target = if size == 2 {
        u16(data, start + i * size, reference.end)
      } else {
        u32(data, start + i * size, reference.end)
      }
      if target == primary && !linked.contains(from) {
        linked.push(from)
      }
    }
  }
  linked
}

///|
fn metadata_meta(
  builder : AvifMetadataBuilder,
  data : Array[Byte],
  boxes : Array[Box],
  meta : Box,
  primary : Int?,
) -> Unit raise AvifError {
  let mi = idx_box(boxes, meta.start)
  let iinf = match find_box(boxes, mi, t_iinf) {
    Some(value) => value
    None => if primary is Some(_) { raise AvifError::Invalid } else { return }
  }
  let ii = idx_box(boxes, iinf.start)
  let items : Array[Item] = []
  let xmp_ids : Array[Int] = []
  for box in boxes {
    if box.parent != ii || box.typ != t_infe {
      continue
    }
    let version = u8(data, box.payload, box.end)
    if version != 2 && version != 3 {
      raise AvifError::Unsupported
    }
    let size = if version == 2 { 2 } else { 4 }
    let id = if size == 2 {
      u16(data, box.payload + 4, box.end)
    } else {
      u32(data, box.payload + 4, box.end)
    }
    if id <= 0 || items.any(item => item.id == id) {
      raise AvifError::Invalid
    }
    if u16(data, box.payload + 4 + size, box.end) != 0 {
      raise AvifError::Unsupported
    }
    let kind = u32(data, box.payload + 6 + size, box.end)
    items.push({
      id,
      typ: kind,
      method_id: 0,
      base: 0,
      offs: [],
      lens: [],
      props: [],
    })
    if kind == 0x6D696D65 {
      let content = metadata_string_end(data, box.payload + 10 + size, box.end)
      let end = metadata_string_end(data, content, box.end)
      if metadata_string_equals(data, content, end, "application/rdf+xml") {
        if end < box.end && u8(data, end, box.end) != 0 {
          raise AvifError::Unsupported
        }
        xmp_ids.push(id)
      }
    }
  }
  let iloc = match find_box(boxes, mi, t_iloc) {
    Some(value) => value
    None => if items.is_empty() { return } else { raise AvifError::Invalid }
  }
  parse_iloc(data, iloc, items)
  let iprp = find_box(boxes, mi, t_iprp)
  let essential : Array[(Int, Int)] = []
  parse_ipma(data, boxes, iprp, items, essential=Some(essential))
  if primary is Some(id) {
    let item_index = idx_item(items, id)
    if item_index < 0 {
      raise AvifError::Invalid
    }
    if iprp is Some(rp) {
      if find_box(boxes, idx_box(boxes, rp.start), t_ipco) is Some(co) {
        let ci = idx_box(boxes, co.start)
        let properties = boxes.filter(box => box.parent == ci)
        for entry in essential {
          let (owner, index) = entry
          if owner != id {
            continue
          }
          if index <= 0 || index > properties.length() {
            raise AvifError::Invalid
          }
          let kind = properties[index - 1].typ
          if ![
              t_ispe, t_av1c, t_colr, t_auxc, t_a1op, t_lsel, 0x70697869, 0x70617370,
              0x636C6170, 0x69726F74, 0x696D6972,
            ].contains(kind) {
            raise AvifError::Diagnostic(
              decode_error(
                Unsupported,
                "metadata.property",
                "Unknown essential primary-item property",
                offset=Some(properties[index - 1].start),
              ),
            )
          }
        }
        for association in items[item_index].props {
          if association <= 0 || association > properties.length() {
            raise AvifError::Invalid
          }
          metadata_property(builder, data, properties[association - 1])
        }
      }
    }
  }
  let linked = match primary {
    Some(id) => metadata_descriptions(data, boxes, meta, id)
    None => []
  }
  let idat = find_box(boxes, mi, t_idat)
  for item in items {
    if primary is Some(_) && !linked.contains(item.id) {
      continue
    }
    if item.typ != 0x45786966 && !xmp_ids.contains(item.id) {
      continue
    }
    let payload = metadata_item_payload(data, item, idat, builder.remaining)
    if payload.is_empty() {
      continue
    }
    if item.typ == 0x45786966 {
      if builder.exif is Some(_) {
        raise AvifError::Invalid
      }
      let offset = metadata_u32(payload, 0, payload.length())
      if offset > (payload.length() - 4).to_int64() {
        raise AvifError::Invalid
      }
      builder.exif_tiff_offset = Some(offset.to_int())
      builder.exif = Some(metadata_blob(builder, payload, 4, payload.length()))
    } else {
      if builder.xmp is Some(_) {
        raise AvifError::Invalid
      }
      builder.xmp = Some(metadata_blob(builder, payload, 0, payload.length()))
    }
  }
}

///|
/// Read primary-item metadata without reconstructing pixels. Input and total
/// exposed metadata are bounded by max_input_bytes. Transform metadata remains
/// available even when its crop cannot be represented by an integer raster.
pub fn avif_metadata(
  data : Array[Byte],
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[AvifMetadata, DecodeError] {
  match decode_checked_budget(data.length(), limits) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  try {
    let boxes : Array[Box] = []
    walk(data, 0, data.length(), -1, boxes)
    let meta = match find_box(boxes, -1, t_meta) {
      Some(value) => value
      None => raise AvifError::Invalid
    }
    let pitm = match find_box(boxes, idx_box(boxes, meta.start), t_pitm) {
      Some(value) => value
      None => raise AvifError::Invalid
    }
    let version = u8(data, pitm.payload, pitm.end)
    if version > 1 {
      raise AvifError::Unsupported
    }
    let primary = if version == 0 {
      u16(data, pitm.payload + 4, pitm.end)
    } else {
      u32(data, pitm.payload + 4, pitm.end)
    }
    let builder = metadata_builder(limits.max_input_bytes)
    metadata_meta(builder, data, boxes, meta, Some(primary))
    Ok(metadata_finish(builder, Some(primary), None))
  } catch {
    AvifError::Diagnostic(error) => Err(error)
    AvifError::Unsupported =>
      Err(
        decode_error(
          Unsupported,
          "metadata",
          "Unsupported metadata syntax, protection or content encoding",
        ),
      )
    _ =>
      Err(
        decode_error(
          InvalidData,
          "metadata",
          "Invalid metadata item, association, extent or property",
        ),
      )
  }
}

///|
fn avif_track_metadata(
  data : Array[Byte],
  track : GaAnimationTrack,
  limit : Int,
) -> Result[AvifMetadata, DecodeError] {
  try {
    let builder = metadata_builder(limit)
    for property in track.properties {
      if property.parent == -1 {
        metadata_property(builder, data, {
          typ: property.typ,
          start: property.start,
          payload: property.payload,
          end: property.end,
          parent: -1,
        })
      }
    }
    let tracks : Array[GaBox] = []
    ga_walk(data, 0, data.length(), -1, tracks)
    if ga_find(tracks, ga_idx(tracks, track.box_start), ga_meta) is Some(meta) {
      let boxes : Array[Box] = []
      walk(data, meta.start, meta.end, -1, boxes)
      metadata_meta(builder, data, boxes, boxes[0], None)
    }
    Ok(metadata_finish(builder, None, Some(track.id)))
  } catch {
    AvifError::Diagnostic(error) => Err(error)
    AvifError::Unsupported | GridAnimError::Unsupported =>
      Err(
        decode_error(
          Unsupported,
          "animation.metadata",
          "Unsupported track metadata syntax",
        ),
      )
    _ =>
      Err(
        decode_error(
          InvalidData,
          "animation.metadata",
          "Invalid track metadata",
        ),
      )
  }
}

///|
fn avif_metadata_copy(metadata : AvifMetadata) -> AvifMetadata {
  {
    ..metadata,
    icc: metadata.icc.map(bytes => bytes.map(byte => byte)),
    exif: metadata.exif.map(bytes => bytes.map(byte => byte)),
    xmp: metadata.xmp.map(bytes => bytes.map(byte => byte)),
    transforms: metadata.transforms.map(transform => transform),
  }
}
