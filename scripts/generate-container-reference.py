#!/usr/bin/env python3
"""Remux a small AV1 temporal-unit prefix into IVF, MP4, fMP4, and WebM.

The source is the existing licensed/synthetic `av1-stream` sequence.  The
first eight packet records retain its sequence header, inter-frame state and a
show-existing presentation while keeping the committed container corpus
small.  FFmpeg performs every remux; the fMP4 `tfdt` field is then adjusted by
the recorded deterministic post-process so its fragment retains the same
2500-tick timestamp offset as the ordinary MP4 and WebM outputs.

`--check` is read-only.  It hashes all saved files, reruns ffprobe for packet
metadata and data hashes, and verifies the generated MoonBit source without
invoking FFmpeg or writing a temporary file.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import zlib


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tests/fixtures/av1-stream/reorder_10bit_320x180.obu"
SOURCE_PIXELS = ROOT / "tests/fixtures/av1-stream/reorder_10bit_320x180.reference.yuv"
OUT = ROOT / "tests/fixtures/av1-containers"
TEST = ROOT / "container_reference_test.mbt"
PACKETS = 8
TIMESTAMP_OFFSET = 2500
TIMESCALE = 1000
WIDTH = 320
HEIGHT = 180
DEPTH = 10
FRAME_BYTES = WIDTH * HEIGHT * 2 + (WIDTH // 2) * (HEIGHT // 2) * 2 * 2


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def ffprobe(path: Path, ignore_editlist: bool = False) -> dict[str, object]:
    command = [
        "ffprobe",
        "-v",
        "error",
        *( ["-ignore_editlist", "1"] if ignore_editlist else [] ),
        "-show_streams",
        "-show_packets",
        "-show_data_hash",
        "sha256",
        "-show_entries",
        "stream=index,codec_name,width,height,time_base,start_time,extradata_size:packet=pts,dts,duration,size,pos,flags,data_hash",
        "-of",
        "json",
        str(path),
    ]
    completed = subprocess.run(command, capture_output=True, text=True, check=True)
    value = json.loads(completed.stdout)
    # Keep only deterministic fields; ffprobe adds empty program/side-data
    # arrays and version-dependent tags that are not part of the demux API.
    streams = []
    for stream in value.get("streams", []):
        streams.append({key: stream[key] for key in (
            "index", "codec_name", "width", "height", "time_base", "start_time", "extradata_size"
        ) if key in stream})
    packets = []
    for packet in value.get("packets", []):
        packets.append({key: packet[key] for key in (
            "pts", "dts", "duration", "size", "pos", "flags", "data_hash"
        ) if key in packet})
    return {"streams": streams, "packets": packets}


def parse_original_packets() -> list[dict[str, object]]:
    value = ffprobe(SOURCE)
    packets = value["packets"]
    if len(packets) < PACKETS:
        raise RuntimeError(f"source has only {len(packets)} packets")
    selected = packets[:PACKETS]
    if int(selected[0]["pts"]) != 0 or "K" not in selected[0].get("flags", ""):
        raise RuntimeError("prefix does not begin with a key packet")
    return selected


def packet_payloads(path: Path) -> list[bytes]:
    # pkt_pos is container-specific (IVF points at its record header; WebM at
    # its Block). Ask ffprobe for the demuxed data, then verify its own hash.
    result = subprocess.run(['ffprobe','-v','error','-show_packets','-show_data',
        '-show_data_hash','sha256','-show_entries','packet=data,data_hash,size',
        '-of','json',str(path)],capture_output=True,text=True,check=True)
    payloads = []
    for packet in json.loads(result.stdout)['packets']:
        data = b''.join(bytes.fromhex(line.split(': ',1)[1][:39])
                      for line in packet['data'].splitlines() if line.strip())
        if len(data) != int(packet['size']) or 'SHA256:'+sha256(data) != packet['data_hash']:
            raise RuntimeError('ffprobe payload extraction/hash mismatch')
        payloads.append(data)
    return payloads


def prefix_bytes(packets: list[dict[str, object]]) -> bytes:
    source = SOURCE.read_bytes()
    end = int(packets[-1]["pos"]) + int(packets[-1]["size"])
    if end > len(source):
        raise RuntimeError("ffprobe packet range exceeds source")
    return source[:end]


def run(command: list[str]) -> None:
    subprocess.run(command, check=True, capture_output=True, text=True)


def patch_fragment_timestamp(path: Path, offset: int) -> None:
    data = bytearray(path.read_bytes())
    marker = b"tfdt"
    cursor = 0
    found = 0
    while True:
        at = data.find(marker, cursor)
        if at < 0:
            break
        if at < 4 or at + 16 > len(data):
            raise RuntimeError("malformed tfdt marker")
        version = data[at + 4]
        if version == 1:
            value = struct.unpack(">Q", data[at + 8 : at + 16])[0]
            data[at + 8 : at + 16] = struct.pack(">Q", value + offset)
        elif version == 0:
            value = struct.unpack(">I", data[at + 8 : at + 12])[0]
            if value + offset > 0xFFFFFFFF:
                raise RuntimeError("fMP4 tfdt timestamp overflows version 0")
            data[at + 8 : at + 12] = struct.pack(">I", value + offset)
        else:
            raise RuntimeError(f"unsupported tfdt version {version}")
        found += 1
        cursor = at + 4
    if found == 0:
        raise RuntimeError("fMP4 output has no tfdt box")
    path.write_bytes(data)


def frame_crc32(data: bytes) -> list[int]:
    if len(data) % FRAME_BYTES:
        raise RuntimeError("native reference length is not a whole frame count")
    return [zlib.crc32(data[i : i + FRAME_BYTES]) & 0xFFFFFFFF for i in range(0, len(data), FRAME_BYTES)]


def byte_array(data: bytes, indent: str = "  ") -> str:
    rows = []
    for index in range(0, len(data), 16):
        rows.append(indent + ", ".join(f"0x{byte:02x}" for byte in data[index : index + 16]) + ",")
    return "[\n" + "\n".join(rows) + "\n]"


def moon_int64_array(values: list[int]) -> str:
    return "[" + ", ".join(f"{value}L" for value in values) + "]"


def moon_option_int64_array(values: list[int | None]) -> str:
    return "[" + ", ".join("None" if value is None else f"Some({value}L)" for value in values) + "]"


def moon_uint_array(values: list[int]) -> str:
    return "[" + ", ".join(f"{value}U" for value in values) + "]"


def generated_test(manifest: dict[str, object], embedded: dict[str, bytes]) -> str:
    lines = [
        "/// Generated by scripts/generate-container-reference.py.",
        "/// Packet timestamps/data hashes are recorded from FFprobe; native CRCs reuse dav1d output.",
        "",
        "///|",
        "fn container_crc32(data : Array[Byte]) -> UInt {",
        "  let mut crc = 0xFFFFFFFFU",
        "  for byte in data {",
        "    crc = crc ^ byte.to_uint()",
        "    for _ in 0..<8 {",
        "      if (crc & 1U) != 0U { crc = (crc >> 1) ^ 0xEDB88320U } else { crc = crc >> 1 }",
        "    }",
        "  }",
        "  crc ^ 0xFFFFFFFFU",
        "}",
        "",
        "///|",
        "fn container_native_crc(frame : Av1NativeFrame) -> UInt {",
        "  let bytes : Array[Byte] = []",
        "  for plane in frame.planes {",
        "    for sample in plane.data {",
        "      bytes.push((sample & 0xFF).to_byte())",
        "      bytes.push((sample >> 8).to_byte())",
        "    }",
        "  }",
        "  container_crc32(bytes)",
        "}",
        "",
    ]
    for name, data in embedded.items():
        lines.extend([
            "///|",
            f"let container_{name} : Array[Byte] = {byte_array(data)}",
            "",
        ])
    source_data = embedded["source_obu"]
    lines.extend([
        "///|",
        "test \"container prefix preserves independent native presentations\" {",
        "  assert_true(av1_frame_info(container_source_obu) is None)",
        "  let decoder = av1_video_decoder()",
        "  let frames = av1_video_decode_temporal_unit_native(decoder, container_source_obu).unwrap()",
        f"  let expected = {moon_uint_array(manifest['native_reference']['frame_crc32'])}",
        "  assert_eq(frames.length(), expected.length())",
        "  for i in 0..<frames.length() { assert_eq(container_native_crc(frames[i]), expected[i]) }",
        "}",
        "",
    ])
    lines.extend([
        '///|', 'test "independent CFR sequence header and pixels" {',
        '  let sequence = av1_sequence_info(container_cfr_obu).unwrap()',
        '  assert_true(sequence.equal_picture_interval)',
        '  assert_false(sequence.decoder_model_info_present)',
        '  let frames = av1_video_decode_temporal_unit_native(av1_video_decoder(), container_cfr_obu).unwrap()',
        f"  let expected = {moon_uint_array(manifest['native_reference']['frame_crc32'])}",
        '  assert_eq(frames.length(), expected.length())',
        '  for i in 0..<frames.length() { assert_eq(container_native_crc(frames[i]), expected[i]) }',
        '}', '',
    ])
    lines.extend([
        "///|",
        "fn container_packet_crc(packet : Av1Packet) -> UInt { container_crc32(packet.data) }",
        "",
        "///|",
        "fn container_track_check(track : Av1DemuxedTrack, expected_format : Av1ContainerFormat, pts : Array[Int64], dts : Array[Int64?], durations : Array[Int64?], crcs : Array[UInt]) -> Unit raise {",
        "  assert_eq(track.format, expected_format)",
        "  assert_eq(track.packets.length(), pts.length())",
        "  for i in 0..<track.packets.length() {",
        "    assert_eq(track.packets[i].presentation_timestamp, Some(pts[i]))",
        "    assert_eq(track.packets[i].decode_timestamp, dts[i])",
        "    assert_eq(track.packets[i].duration, durations[i])",
        "    assert_eq(container_packet_crc(track.packets[i]), crcs[i])",
        "  }",
        "}",
        "",
    ])
    for key, fmt, fn_name in (("ivf", "Ivf", "av1_demux_ivf"), ("mp4", "Mp4", "av1_demux_mp4"), ("fragmented_mp4", "Mp4", "av1_demux_mp4"), ("webm", "WebM", "av1_demux_webm")):
        expected = manifest["demux_expectations"][key]
        lines.extend([
            "///|",
            f"test \"demux {key} packet bytes and timestamps\" {{",
            f"  let track = {fn_name}(container_{key}).unwrap()",
            f"  container_track_check(track, {fmt}, {moon_int64_array(expected['pts'])}, {moon_option_int64_array(expected['dts'])}, {moon_option_int64_array(expected['duration'])}, {moon_uint_array(expected['crc32'])})",
            "}",
            "",
        ])
    displayed = manifest["native_reference"]["displayed_packet_indices"]
    for key, fmt in (("ivf", "Ivf"), ("mp4", "Mp4"), ("fragmented_mp4", "Mp4"), ("webm", "WebM")):
        expected = manifest["demux_expectations"][key]
        pts = [expected["pts"][index] for index in displayed]
        durations = [expected["duration"][index] for index in displayed]
        crcs = manifest["native_reference"]["displayed_frame_crc32"]
        lines.extend([
            "///|",
            f"test \"container decoder {key} native CRC, timestamps, reset and ownership\" {{",
            f"  let decoder = Av1ContainerDecoder::new(container_{key}).unwrap()",
            f"  assert_eq(decoder.format(), {fmt})",
            f"  assert_eq(decoder.packet_count(), {PACKETS})",
            f"  let expected_indices = {moon_int64_array(displayed)}",
            f"  let expected_pts = {moon_int64_array(pts)}",
            f"  let expected_durations = {moon_option_int64_array(durations)}",
            f"  let expected_crc = {moon_uint_array(crcs)}",
            "  let mut seen = 0",
            "  while true {",
            "    match decoder.next_frame().unwrap() {",
            "      None => break",
            "      Some(value) => {",
            "        assert_eq(value.packet_index, expected_indices[seen].to_int())",
            "        assert_eq(value.timestamp, Some(expected_pts[seen]))",
            "        assert_eq(value.duration, expected_durations[seen])",
            "        assert_eq(container_native_crc(value.frame), expected_crc[seen])",
            "        seen += 1",
            "      }",
            "    }",
            "  }",
            "  assert_eq(seen, expected_crc.length())",
            "  decoder.reset()",
            "  let retained = decoder.next_frame().unwrap().unwrap()",
            "  let replay_crc = container_native_crc(retained.frame)",
            "  assert_eq(replay_crc, expected_crc[0])",
            "  retained.frame.planes[0].data[0] = -1",
            "  let following = decoder.next_frame().unwrap().unwrap()",
            "  assert_eq(container_native_crc(following.frame), expected_crc[1])",
            "  decoder.reset()",
            "  assert_eq(container_native_crc(decoder.next_frame().unwrap().unwrap().frame), expected_crc[0])",
            "}",
            "",
        ])
    lines.extend([
        "///|",
        "test \"auto demux retains ordinary MP4 edits and fragmented media timeline\" {",
        "  let ordinary = av1_demux(container_mp4).unwrap()",
        "  assert_true(ordinary.movie_timescale is Some(_))",
        "  assert_true(ordinary.edits.length() > 0)",
        "  let fragmented = av1_demux(container_fragmented_mp4).unwrap()",
        "  assert_eq(fragmented.edits.length(), 0)",
        "}",
        "",
    ])
    return subprocess.run(
        ["moonfmt", "-"], input="\n".join(lines), text=True,
        encoding="utf8", capture_output=True, check=True,
    ).stdout


def build(args: argparse.Namespace) -> None:
    packets = parse_original_packets()
    prefix = prefix_bytes(packets)
    source_copy = OUT / "reorder_prefix8_10bit_320x180.obu"
    OUT.mkdir(parents=True, exist_ok=True)
    source_copy.write_bytes(prefix)
    source = str(source_copy)
    cfr = OUT / 'reorder_prefix8_cfr.obu'
    cfr_command = ['ffmpeg','-hide_banner','-loglevel','error','-y','-f','obu','-i',source,'-c:v','copy','-bsf:v','av1_metadata=tick_rate=50:num_ticks_per_picture=2','-f','obu',str(cfr)]
    run(cfr_command)
    stem = "reorder_prefix8_10bit_320x180"
    outputs = {
        "ivf": OUT / f"{stem}.ivf",
        "mp4": OUT / f"{stem}.mp4",
        "fragmented_mp4": OUT / f"{stem}.fragmented.mp4",
        "webm": OUT / f"{stem}.webm",
    }
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
        "-f", "obu", "-i", source, "-map", "0:v:0", "-c:v", "copy", "-copyts",
        "-avoid_negative_ts", "disabled", "-f", "ivf", str(outputs["ivf"]),
    ])
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
        "-f", "obu", "-i", source, "-map", "0:v:0", "-c:v", "copy", "-copyts",
        "-avoid_negative_ts", "disabled", "-video_track_timescale", str(TIMESCALE),
        "-movflags", "+faststart", str(outputs["mp4"]),
    ])
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
        "-f", "obu", "-i", source, "-map", "0:v:0", "-c:v", "copy", "-copyts",
        "-avoid_negative_ts", "disabled", "-video_track_timescale", str(TIMESCALE),
        "-movflags", "+frag_keyframe+empty_moov+default_base_moof", str(outputs["fragmented_mp4"]),
    ])
    patch_fragment_timestamp(outputs["fragmented_mp4"], TIMESTAMP_OFFSET)
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
        "-f", "obu", "-i", source, "-map", "0:v:0", "-c:v", "copy", "-copyts",
        "-avoid_negative_ts", "disabled", "-time_base", "1/1000", "-cluster_time_limit", "1000",
        "-f", "webm", str(outputs["webm"]),
    ])
    reference = SOURCE_PIXELS.read_bytes()[: PACKETS * FRAME_BYTES]
    manifest = {
        "source": {
            "file": "../av1-stream/reorder_10bit_320x180.obu",
            "sha256": sha256(SOURCE.read_bytes()),
            "selection": f"first {PACKETS} ffprobe packets, through complete packet end",
            "source_pixels": "../av1-stream/reorder_10bit_320x180.reference.yuv",
            "source_pixels_sha256": sha256(SOURCE_PIXELS.read_bytes()),
            "license": "synthetic integer-only MoonAV1 fixture; no external imagery",
        },
        "tooling": {
            "ffmpeg": subprocess.run(["ffmpeg", "-version"], capture_output=True, text=True, check=True).stdout.splitlines()[0],
            "ffprobe": subprocess.run(["ffprobe", "-version"], capture_output=True, text=True, check=True).stdout.splitlines()[0],
            "remux_note": "fMP4 tfdt base decode time is increased by 2500 ticks after FFmpeg empty-moov remux",
            "commands": {
                "ivf": ["ffmpeg", "-itsoffset", "2.5", "-f", "obu", "-i", "reorder_prefix8_10bit_320x180.obu", "-map", "0:v:0", "-c:v", "copy", "-copyts", "-avoid_negative_ts", "disabled", "-f", "ivf"],
                "mp4": ["ffmpeg", "-itsoffset", "2.5", "-f", "obu", "-i", "reorder_prefix8_10bit_320x180.obu", "-map", "0:v:0", "-c:v", "copy", "-copyts", "-avoid_negative_ts", "disabled", "-video_track_timescale", "1000", "-movflags", "+faststart"],
                "fragmented_mp4": ["ffmpeg", "-itsoffset", "2.5", "-f", "obu", "-i", "reorder_prefix8_10bit_320x180.obu", "-map", "0:v:0", "-c:v", "copy", "-copyts", "-avoid_negative_ts", "disabled", "-video_track_timescale", "1000", "-movflags", "+frag_keyframe+empty_moov+default_base_moof", "then add 2500 to every tfdt base decode time"],
                "webm": ["ffmpeg", "-itsoffset", "2.5", "-f", "obu", "-i", "reorder_prefix8_10bit_320x180.obu", "-map", "0:v:0", "-c:v", "copy", "-copyts", "-avoid_negative_ts", "disabled", "-time_base", "1/1000", "-cluster_time_limit", "1000", "-f", "webm"],
                "ffprobe_raw_mp4": ["ffprobe", "-ignore_editlist", "1", "-show_packets", "-show_data_hash", "sha256"],
            },
        },
        "sequence": {
            "width": WIDTH,
            "height": HEIGHT,
            "depth": DEPTH,
            "sampling": "420",
            "packets": PACKETS,
            "timescale": TIMESCALE,
            "timestamp_offset": TIMESTAMP_OFFSET,
            "packet_source_crc32": [zlib.crc32(prefix[int(row["pos"]) : int(row["pos"]) + int(row["size"])]) & 0xFFFFFFFF for row in packets],
            "has_key_packet": True,
            "evidence": {
                "hidden_frames": 2,
                "show_existing_frames": 2,
                "evidence_source": "tests/fixtures/av1-stream/reorder_10bit_320x180.trace.txt packets 0..7",
            },
        },
        "native_reference": {
            "frame_bytes": FRAME_BYTES,
            "frame_crc32": frame_crc32(reference),
            "displayed_packet_indices": list(range(PACKETS)),
            "displayed_frame_crc32": frame_crc32(reference),
            "sha256": sha256(reference),
        },
        'cfr_reference': {'file':cfr.name,'sha256':sha256(cfr.read_bytes()),'command':cfr_command},
        "artifacts": {},
    }
    manifest["source"]["prefix_sha256"] = sha256(prefix)
    embedded = {"source_obu": prefix, 'cfr_obu':cfr.read_bytes()}
    for name, path in outputs.items():
        probe = ffprobe(path, ignore_editlist=path.suffix.lower() == ".mp4")
        probe_name = f"{stem}.{name}.ffprobe.json"
        (OUT / probe_name).write_text(json.dumps(probe, indent=2) + "\n", encoding="utf8", newline="\n")
        raw_bytes = path.read_bytes()
        manifest["artifacts"][path.name] = {"sha256": sha256(raw_bytes), "bytes": path.stat().st_size, "ffprobe": probe_name}
        time_scale = 1000000 if name == "webm" else 1
        manifest.setdefault("demux_expectations", {})[name] = {
            "pts": [int(packet["pts"]) * time_scale for packet in probe["packets"]],
            "dts": [None if name in ("ivf", "webm") or "dts" not in packet else int(packet["dts"]) for packet in probe["packets"]],
            "duration": [None if "duration" not in packet else int(packet["duration"]) * time_scale for packet in probe["packets"]],
            "crc32": [zlib.crc32(payload) & 0xFFFFFFFF for payload in packet_payloads(path)],
        }
        if path.suffix.lower() == ".mp4" and not path.name.endswith(".fragmented.mp4"):
            display_probe = ffprobe(path, ignore_editlist=False)
            display_name = f"{stem}.{name}.ffprobe-display.json"
            (OUT / display_name).write_text(json.dumps(display_probe, indent=2) + "\n", encoding="utf8", newline="\n")
            manifest["artifacts"][path.name]["ffprobe_display"] = display_name
        embedded[name] = raw_bytes
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf8", newline="\n")
    TEST.write_text(generated_test(manifest, embedded), encoding="utf8", newline="\n")
    print(f"Wrote {PACKETS} temporal units into {len(outputs)} container fixtures")


def check() -> None:
    manifest = json.loads((OUT / "manifest.json").read_text(encoding="utf8"))
    for name, record in manifest["artifacts"].items():
        path = OUT / name
        data = path.read_bytes()
        if len(data) != record["bytes"] or sha256(data) != record["sha256"]:
            raise SystemExit(f"{path} hash or size differs")
        probe = ffprobe(path, ignore_editlist=path.suffix.lower() == ".mp4")
        saved = json.loads((OUT / record["ffprobe"]).read_text(encoding="utf8"))
        if probe != saved:
            raise SystemExit(f"{path} ffprobe packet metadata differs")
        key = 'fragmented_mp4' if name.endswith('.fragmented.mp4') else Path(name).suffix[1:]
        if manifest['demux_expectations'][key]['crc32'] != [zlib.crc32(p) & 0xFFFFFFFF for p in packet_payloads(path)]:
            raise SystemExit(f'{path} demuxed packet CRCs differ')
    source = OUT / "reorder_prefix8_10bit_320x180.obu"
    if sha256(source.read_bytes()) != manifest["source"]["prefix_sha256"]:
        raise SystemExit("prefix source hash differs")
    reference = SOURCE_PIXELS.read_bytes()[: PACKETS * FRAME_BYTES]
    if frame_crc32(reference) != manifest["native_reference"]["frame_crc32"]:
        raise SystemExit("native reference CRCs differ")
    # Keep check independent from generation order and use the exact artifact names.
    cfr = OUT / manifest['cfr_reference']['file']
    if sha256(cfr.read_bytes()) != manifest['cfr_reference']['sha256']:
        raise SystemExit('CFR sequence fixture hash differs')
    embedded = {"source_obu": source.read_bytes(), 'cfr_obu':cfr.read_bytes()}
    for name in manifest["artifacts"]:
        key = "fragmented_mp4" if name.endswith(".fragmented.mp4") else Path(name).suffix[1:]
        embedded[key] = (OUT / name).read_bytes()
    expected = generated_test(manifest, embedded)
    if TEST.read_text(encoding="utf8") != expected:
        raise SystemExit(f"{TEST.name} differs; regenerate from saved containers")
    print("av1-containers: hashes, ffprobe packet records, native references, and test match")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify without writing")
    args = parser.parse_args()
    if args.check:
        check()
    else:
        build(args)


if __name__ == "__main__":
    main()
