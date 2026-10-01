#!/usr/bin/env python3
"""Generate and independently check the long AV1 container corpus.

The corpus remuxes the existing licensed Big Buck Bunny AV1 OBU stream without
re-encoding.  It keeps the native dav1d planes in ``av1-realvideo`` and stores
only their file hash and per-frame CRC mapping here.  FFmpeg creates the
containers; ffprobe and an independent payload parser record packet timing,
size, SHA-256 and CRC32 values.

``--check`` is read-only.  It does not run FFmpeg and does not create a
temporary file.  It reopens every saved artifact, reruns ffprobe packet
inspection, recomputes payload hashes and CRCs, checks MP4 structure and
verifies the immutable source/native references.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
from typing import Any, Iterable
import zlib


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tests/fixtures/av1-realvideo/bbb_8bit_512x288.obu"
SOURCE_PIXELS = ROOT / "tests/fixtures/av1-realvideo/bbb_8bit_512x288.reference.yuv"
SOURCE_MANIFEST = ROOT / "tests/fixtures/av1-realvideo/manifest.json"
OUT = ROOT / "tests/fixtures/av1-long-containers"

WIDTH = 512
HEIGHT = 288
DEPTH = 8
SAMPLING = "420"
FRAME_BYTES = WIDTH * HEIGHT + 2 * ((WIDTH + 1) // 2) * ((HEIGHT + 1) // 2)
FRAMES = 706
TIMESCALE = 1000
TIMESTAMP_OFFSET = 2500
FRAGMENT_DURATION = 1_000_000
MIN_FRAGMENT_DURATION = 500_000
SCHEMA_VERSION = 1
STREAM_MAX_FRAMES = 768
STREAM_MAX_INPUT_BYTES = 65_536
STREAM_MAX_CHUNK_BYTES = 32_768

PREFIX = "bbb_long_8bit_512x288"
ARTIFACTS = {
    "ivf": f"{PREFIX}.ivf",
    "faststart_mp4": f"{PREFIX}.faststart.mp4",
    "moov_tail_mp4": f"{PREFIX}.moov-tail.mp4",
    "fragmented_mp4": f"{PREFIX}.fragmented.mp4",
    "webm": f"{PREFIX}.webm",
    "multitrack_mp4": f"{PREFIX}.multitrack.mp4",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256(path.read_bytes())


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def run(command: list[str]) -> None:
    subprocess.run(command, check=True, capture_output=True, text=True)


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def ffmpeg_version() -> str:
    return subprocess.run(
        ["ffmpeg", "-version"], capture_output=True, text=True, check=True
    ).stdout.splitlines()[0]


def ffprobe_version() -> str:
    return subprocess.run(
        ["ffprobe", "-version"], capture_output=True, text=True, check=True
    ).stdout.splitlines()[0]


def ffprobe_command(path: Path, ignore_editlist: bool) -> list[str]:
    return [
        "ffprobe",
        "-v",
        "error",
        *( ["-ignore_editlist", "1"] if ignore_editlist else [] ),
        "-show_streams",
        "-show_packets",
        "-show_format",
        "-show_data",
        "-show_data_hash",
        "sha256",
        "-show_entries",
        "stream=index,id,codec_type,codec_name,width,height,sample_rate,channels,time_base,start_time,duration,extradata_size,disposition:packet=stream_index,pts,dts,duration,size,pos,flags,data_hash,data:format=format_name,start_time,duration",
        "-of",
        "json",
        str(path),
    ]


_HEX_LINE = re.compile(r"^\s*[0-9a-fA-F]+:\s*(.*?)\s*$")


def payload_from_ffprobe(data: str, expected_size: int) -> bytes:
    """Decode ffprobe's hex dump without trusting packet positions."""
    result = bytearray()
    for line in data.splitlines():
        match = _HEX_LINE.match(line)
        if not match:
            continue
        # ffprobe reserves 39 columns after the offset for eight four-hex-digit
        # groups (or a final two-digit odd byte) and then prints ASCII.  Limit
        # parsing to those columns so printable text can never become payload.
        for token in match.group(1)[:39].split():
            if len(token) == 4 and re.fullmatch(r"[0-9A-Fa-f]{4}", token):
                result.extend(bytes.fromhex(token))
                continue
            if len(token) == 2 and re.fullmatch(r"[0-9A-Fa-f]{2}", token):
                result.extend(bytes.fromhex(token))
                continue
            raise RuntimeError(f"invalid ffprobe hex group: {token!r}")
    value = bytes(result)
    if len(value) != expected_size:
        raise RuntimeError(
            f"ffprobe payload length mismatch: expected {expected_size}, got {len(value)}"
        )
    return value


def _stream_record(stream: dict[str, Any]) -> dict[str, Any]:
    keys = (
        "index",
        "id",
        "codec_type",
        "codec_name",
        "width",
        "height",
        "sample_rate",
        "channels",
        "time_base",
        "start_time",
        "duration",
        "extradata_size",
        "disposition",
    )
    return {key: stream[key] for key in keys if key in stream}


def _packet_record(packet: dict[str, Any], payload: bytes) -> dict[str, Any]:
    keys = ("stream_index", "pts", "dts", "duration", "size", "pos", "flags", "data_hash")
    record = {key: packet[key] for key in keys if key in packet}
    record["crc32"] = crc32(payload)
    return record


def probe(path: Path, ignore_editlist: bool) -> dict[str, Any]:
    completed = subprocess.run(
        ffprobe_command(path, ignore_editlist),
        capture_output=True,
        text=True,
        check=True,
    )
    value = json.loads(completed.stdout)
    packets: list[dict[str, Any]] = []
    for packet in value.get("packets", []):
        if "size" not in packet:
            raise RuntimeError(f"ffprobe omitted packet size for {path}")
        payload = payload_from_ffprobe(packet.get("data", ""), int(packet["size"]))
        expected_hash = packet.get("data_hash")
        actual_hash = f"SHA256:{sha256(payload)}"
        if expected_hash != actual_hash:
            raise RuntimeError(f"ffprobe payload SHA-256 mismatch for {path}")
        packets.append(_packet_record(packet, payload))
    return {
        "streams": [_stream_record(stream) for stream in value.get("streams", [])],
        "packets": packets,
        "format": value.get("format", {}),
    }


def select_av1_stream(probe_result: dict[str, Any]) -> dict[str, Any]:
    streams = [stream for stream in probe_result["streams"] if stream.get("codec_name") == "av1"]
    if len(streams) != 1:
        raise RuntimeError(f"expected exactly one AV1 stream, found {len(streams)}")
    stream = streams[0]
    return {
        key: stream[key]
        for key in ("index", "id", "codec_type", "codec_name", "width", "height", "time_base")
        if key in stream
    }


def stream_packets(probe_result: dict[str, Any], stream_index: int) -> list[dict[str, Any]]:
    return [packet for packet in probe_result["packets"] if packet.get("stream_index") == stream_index]


def frame_crc32(path: Path) -> list[int]:
    data = path.read_bytes()
    if len(data) != FRAMES * FRAME_BYTES:
        raise RuntimeError(
            f"native reference size mismatch: expected {FRAMES * FRAME_BYTES}, got {len(data)}"
        )
    return [
        crc32(data[index : index + FRAME_BYTES])
        for index in range(0, len(data), FRAME_BYTES)
    ]


def _iter_boxes(data: bytes, start: int, end: int) -> Iterable[tuple[bytes, int, int, int, int]]:
    cursor = start
    while cursor < end:
        if cursor + 8 > end:
            raise RuntimeError("truncated MP4 box header")
        size = struct.unpack(">I", data[cursor : cursor + 4])[0]
        kind = data[cursor + 4 : cursor + 8]
        header = 8
        if size == 1:
            if cursor + 16 > end:
                raise RuntimeError("truncated MP4 large box header")
            size = struct.unpack(">Q", data[cursor + 8 : cursor + 16])[0]
            header = 16
        elif size == 0:
            size = end - cursor
        if size < header or cursor + size > end:
            raise RuntimeError("invalid MP4 box size")
        yield kind, cursor, int(size), header, cursor + header
        cursor += int(size)
    if cursor != end:
        raise RuntimeError("MP4 box walk did not end at parent boundary")


_CONTAINER_BOXES = {
    b"moov",
    b"trak",
    b"edts",
    b"mdia",
    b"minf",
    b"stbl",
    b"mvex",
    b"moof",
    b"traf",
    b"mfra",
    b"dinf",
    b"dref",
}


def mp4_structure(path: Path) -> dict[str, Any] | None:
    if path.suffix.lower() != ".mp4":
        return None
    data = path.read_bytes()
    top: list[dict[str, Any]] = []
    edit_lists: list[dict[str, Any]] = []
    tfdt_values: list[int] = []

    def walk(start: int, end: int, parents: tuple[bytes, ...]) -> None:
        for kind, offset, size, header, payload_start in _iter_boxes(data, start, end):
            top_level = not parents
            if top_level:
                top.append({"type": kind.decode("ascii", errors="replace"), "offset": offset, "size": size})
            payload_end = offset + size
            if kind == b"elst":
                if payload_start + 8 > payload_end:
                    raise RuntimeError("truncated MP4 edit list")
                version = data[payload_start]
                count = struct.unpack(">I", data[payload_start + 4 : payload_start + 8])[0]
                cursor = payload_start + 8
                entries: list[dict[str, int]] = []
                for _ in range(count):
                    if version == 1:
                        if cursor + 20 > payload_end:
                            raise RuntimeError("truncated version 1 edit list")
                        duration = struct.unpack(">Q", data[cursor : cursor + 8])[0]
                        media_time = struct.unpack(">q", data[cursor + 8 : cursor + 16])[0]
                        cursor += 16
                    else:
                        if cursor + 12 > payload_end:
                            raise RuntimeError("truncated version 0 edit list")
                        duration = struct.unpack(">I", data[cursor : cursor + 4])[0]
                        media_time = struct.unpack(">i", data[cursor + 4 : cursor + 8])[0]
                        cursor += 8
                    rate_integer = struct.unpack(">h", data[cursor : cursor + 2])[0]
                    rate_fraction = struct.unpack(">H", data[cursor + 2 : cursor + 4])[0]
                    cursor += 4
                    entries.append(
                        {
                            "segment_duration": int(duration),
                            "media_time": int(media_time),
                            "media_rate_integer": rate_integer,
                            "media_rate_fraction": rate_fraction,
                        }
                    )
                edit_lists.append(
                    {
                        "path": "/".join((*[item.decode("ascii", errors="replace") for item in parents], "elst")),
                        "version": version,
                        "entries": entries,
                    }
                )
            elif kind == b"tfdt":
                if payload_start + 8 > payload_end:
                    raise RuntimeError("truncated MP4 tfdt")
                version = data[payload_start]
                if version == 1:
                    if payload_start + 12 > payload_end:
                        raise RuntimeError("truncated version 1 tfdt")
                    value = struct.unpack(">Q", data[payload_start + 4 : payload_start + 12])[0]
                elif version == 0:
                    value = struct.unpack(">I", data[payload_start + 4 : payload_start + 8])[0]
                else:
                    raise RuntimeError(f"unsupported MP4 tfdt version {version}")
                tfdt_values.append(int(value))
            if kind in _CONTAINER_BOXES:
                walk(payload_start, payload_end, (*parents, kind))

    walk(0, len(data), ())
    moov = next((item for item in top if item["type"] == "moov"), None)
    mdat = next((item for item in top if item["type"] == "mdat"), None)
    return {
        "top_level_boxes": top,
        "moov_offset": None if moov is None else moov["offset"],
        "moov_before_mdat": None if moov is None or mdat is None else moov["offset"] < mdat["offset"],
        "fragment_count": sum(item["type"] == "moof" for item in top),
        "edit_lists": edit_lists,
        "tfdt_base_decode_times": tfdt_values,
    }


def patch_tfdt(path: Path, offset: int) -> None:
    data = bytearray(path.read_bytes())
    cursor = 0
    found = 0
    while True:
        at = data.find(b"tfdt", cursor)
        if at < 4:
            break
        if at + 16 > len(data):
            raise RuntimeError("truncated tfdt marker")
        version = data[at + 4]
        if version == 1:
            value = struct.unpack(">Q", data[at + 8 : at + 16])[0]
            data[at + 8 : at + 16] = struct.pack(">Q", value + offset)
        elif version == 0:
            value = struct.unpack(">I", data[at + 8 : at + 12])[0]
            if value + offset > 0xFFFFFFFF:
                raise RuntimeError("tfdt timestamp overflow")
            data[at + 8 : at + 12] = struct.pack(">I", value + offset)
        else:
            raise RuntimeError(f"unsupported tfdt version {version}")
        found += 1
        cursor = at + 4
    if found == 0:
        raise RuntimeError("fragmented MP4 has no tfdt boxes")
    path.write_bytes(data)


def write_text(path: Path, value: str) -> None:
    path.write_text(value, encoding="utf-8", newline="\n")


def artifact_probe_name(filename: str) -> str:
    return f"{filename}.ffprobe.json"


def display_probe_name(filename: str) -> str:
    return f"{filename}.ffprobe-display.json"


def allowed_names() -> set[str]:
    names = {"README.md", "manifest.json", "source.ffprobe.json"}
    for filename in ARTIFACTS.values():
        names.add(filename)
        names.add(artifact_probe_name(filename))
        if filename.endswith(".mp4") and not filename.endswith(".fragmented.mp4"):
            names.add(display_probe_name(filename))
    return names


def assert_safe_output_directory() -> None:
    if not OUT.exists():
        return
    unexpected = sorted(path.name for path in OUT.iterdir() if path.name not in allowed_names())
    if unexpected:
        raise RuntimeError(
            "refusing to overwrite unrelated files in long-container fixture directory: "
            + ", ".join(unexpected)
        )


def source_records(
    saved_probe: dict[str, Any] | None = None,
) -> tuple[dict[str, Any], list[int], dict[str, Any]]:
    """Check source identities; generation/check reruns ffprobe by default.

    Ordinary consumer verification passes the retained probe explicitly so it
    needs no external reference tools. Its caller also checks saved packet
    hashes against the unchanged source bytes.
    """
    if not SOURCE.is_file() or not SOURCE_PIXELS.is_file() or not SOURCE_MANIFEST.is_file():
        raise RuntimeError("av1-realvideo source, native reference, or manifest is missing")
    source_manifest = json.loads(SOURCE_MANIFEST.read_text(encoding="utf-8"))
    case = next(case for case in source_manifest["cases"] if case["name"] == "bbb_8bit_512x288")
    if case["frames"] != FRAMES:
        raise RuntimeError(f"source manifest frame count changed: {case['frames']}")
    if sha256_file(SOURCE) != case["artifacts"]["bbb_8bit_512x288.obu"]:
        raise RuntimeError("source AV1 OBU hash differs from av1-realvideo manifest")
    if sha256_file(SOURCE_PIXELS) != case["artifacts"]["bbb_8bit_512x288.reference.yuv"]:
        raise RuntimeError("native reference hash differs from av1-realvideo manifest")
    source_probe = probe(SOURCE, False) if saved_probe is None else saved_probe
    source_stream = select_av1_stream(source_probe)
    source_packets = stream_packets(source_probe, int(source_stream["index"]))
    if len(source_packets) != FRAMES:
        raise RuntimeError(f"source packet count changed: {len(source_packets)}")
    native_crc = frame_crc32(SOURCE_PIXELS)
    source_record = {
        "file": rel(SOURCE),
        "sha256": sha256_file(SOURCE),
        "native_reference_file": rel(SOURCE_PIXELS),
        "native_reference_sha256": sha256_file(SOURCE_PIXELS),
        "source_manifest_sha256": sha256_file(SOURCE_MANIFEST),
        "license": source_manifest["source"]["license"],
        "attribution": source_manifest["source"]["attribution"],
        "license_url": source_manifest["source"]["license_url"],
        "selection": "the complete 706-packet AV1 OBU stream from the existing realvideo fixture",
        "dimensions": {"width": WIDTH, "height": HEIGHT, "depth": DEPTH, "sampling": SAMPLING},
        "sequence_metadata": case["sequence_metadata"],
        "evidence": case["evidence"],
        "stream": source_stream,
        "packets": FRAMES,
        "ffprobe": "source.ffprobe.json",
    }
    return source_record, native_crc, source_probe


def command_records() -> dict[str, list[str]]:
    source = rel(SOURCE)
    return {
        "ivf": [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
            "-f", "obu", "-i", source, "-map", "0:v:0", "-c:v", "copy", "-copyts",
            "-avoid_negative_ts", "disabled", "-f", "ivf", ARTIFACTS["ivf"],
        ],
        "faststart_mp4": [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
            "-f", "obu", "-i", source, "-map", "0:v:0", "-c:v", "copy", "-copyts",
            "-avoid_negative_ts", "disabled", "-video_track_timescale", str(TIMESCALE),
            "-movflags", "+faststart", ARTIFACTS["faststart_mp4"],
        ],
        "moov_tail_mp4": [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
            "-f", "obu", "-i", source, "-map", "0:v:0", "-c:v", "copy", "-copyts",
            "-avoid_negative_ts", "disabled", "-video_track_timescale", str(TIMESCALE),
            ARTIFACTS["moov_tail_mp4"],
        ],
        "fragmented_mp4": [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
            "-f", "obu", "-i", source, "-map", "0:v:0", "-c:v", "copy", "-copyts",
            "-avoid_negative_ts", "disabled", "-video_track_timescale", str(TIMESCALE),
            "-movflags", "+empty_moov+default_base_moof", "-frag_duration", str(FRAGMENT_DURATION),
            "-min_frag_duration", str(MIN_FRAGMENT_DURATION), ARTIFACTS["fragmented_mp4"],
            "then add 2500 to every tfdt base decode time",
        ],
        "webm": [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
            "-f", "obu", "-i", source, "-map", "0:v:0", "-c:v", "copy", "-copyts",
            "-avoid_negative_ts", "disabled", "-time_base", "1/1000", "-cluster_time_limit", "1000",
            "-f", "webm", ARTIFACTS["webm"],
        ],
        "multitrack_mp4": [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
            "-f", "obu", "-i", source, "-f", "lavfi", "-i",
            "sine=frequency=440:sample_rate=48000:duration=31", "-map", "1:a:0", "-map", "0:v:0",
            "-c:a", "aac", "-b:a", "64k", "-c:v", "copy", "-copyts", "-avoid_negative_ts", "disabled",
            "-video_track_timescale", str(TIMESCALE), "-movflags", "+faststart",
            "-disposition:a:0", "0", "-disposition:v:0", "default", ARTIFACTS["multitrack_mp4"],
        ],
    }


def run_commands() -> None:
    out = {key: OUT / filename for key, filename in ARTIFACTS.items()}
    source = str(SOURCE)
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
        "-f", "obu", "-i", source, "-map", "0:v:0", "-c:v", "copy", "-copyts",
        "-avoid_negative_ts", "disabled", "-f", "ivf", str(out["ivf"]),
    ])
    for key, movflags in (("faststart_mp4", "+faststart"), ("moov_tail_mp4", None)):
        command = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
            "-f", "obu", "-i", source, "-map", "0:v:0", "-c:v", "copy", "-copyts",
            "-avoid_negative_ts", "disabled", "-video_track_timescale", str(TIMESCALE),
        ]
        if movflags:
            command.extend(["-movflags", movflags])
        command.append(str(out[key]))
        run(command)
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
        "-f", "obu", "-i", source, "-map", "0:v:0", "-c:v", "copy", "-copyts",
        "-avoid_negative_ts", "disabled", "-video_track_timescale", str(TIMESCALE),
        "-movflags", "+empty_moov+default_base_moof", "-frag_duration", str(FRAGMENT_DURATION),
        "-min_frag_duration", str(MIN_FRAGMENT_DURATION), str(out["fragmented_mp4"]),
    ])
    patch_tfdt(out["fragmented_mp4"], TIMESTAMP_OFFSET)
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
        "-f", "obu", "-i", source, "-map", "0:v:0", "-c:v", "copy", "-copyts",
        "-avoid_negative_ts", "disabled", "-time_base", "1/1000", "-cluster_time_limit", "1000",
        "-f", "webm", str(out["webm"]),
    ])
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-itsoffset", "2.5",
        "-f", "obu", "-i", source, "-f", "lavfi", "-i",
        "sine=frequency=440:sample_rate=48000:duration=31", "-map", "1:a:0", "-map", "0:v:0",
        "-c:a", "aac", "-b:a", "64k", "-c:v", "copy", "-copyts", "-avoid_negative_ts", "disabled",
        "-video_track_timescale", str(TIMESCALE), "-movflags", "+faststart",
        "-disposition:a:0", "0", "-disposition:v:0", "default", str(out["multitrack_mp4"]),
    ])


def artifact_record(key: str, filename: str) -> tuple[dict[str, Any], dict[str, Any]]:
    path = OUT / filename
    raw = probe(path, filename.endswith(".mp4"))
    display = probe(path, False) if filename.endswith(".mp4") and not filename.endswith(".fragmented.mp4") else None
    selected = select_av1_stream(raw)
    selected_packets = stream_packets(raw, int(selected["index"]))
    if len(selected_packets) != FRAMES:
        raise RuntimeError(f"{filename} contains {len(selected_packets)} AV1 packets, expected {FRAMES}")
    if selected.get("width") != WIDTH or selected.get("height") != HEIGHT:
        raise RuntimeError(f"{filename} has unexpected AV1 dimensions")
    structure = mp4_structure(path)
    if key == "fragmented_mp4" and (structure is None or structure["fragment_count"] < 2):
        raise RuntimeError("fragmented MP4 did not produce multiple fragments")
    if key == "faststart_mp4" and not structure["moov_before_mdat"]:
        raise RuntimeError("faststart MP4 moov is not before mdat")
    if key == "moov_tail_mp4" and structure["moov_before_mdat"]:
        raise RuntimeError("ordinary moov-tail MP4 unexpectedly has moov before mdat")
    if key in ("faststart_mp4", "moov_tail_mp4", "multitrack_mp4") and not structure["edit_lists"]:
        raise RuntimeError(f"{filename} has no edit list for the recorded presentation offset")
    if key == "multitrack_mp4" and len(raw["streams"]) < 2:
        raise RuntimeError("multi-track MP4 has no audio/video pair")
    record: dict[str, Any] = {
        "file": filename,
        "sha256": sha256_file(path),
        "bytes": path.stat().st_size,
        "ffprobe": artifact_probe_name(filename),
        "selected_av1_stream": selected,
        "selected_av1_packet_count": len(selected_packets),
        "selected_av1_packet_timing": {
            "pts": [packet.get("pts") for packet in selected_packets],
            "dts": [packet.get("dts") for packet in selected_packets],
            "duration": [packet.get("duration") for packet in selected_packets],
            "flags": [packet.get("flags") for packet in selected_packets],
        },
        "selected_av1_packet_sizes": [int(packet["size"]) for packet in selected_packets],
        "max_selected_av1_packet_bytes": max(int(packet["size"]) for packet in selected_packets),
        "selected_av1_packet_sha256": [packet["data_hash"] for packet in selected_packets],
        "selected_av1_packet_crc32": [packet["crc32"] for packet in selected_packets],
        "structure": structure,
    }
    if display is not None:
        record["ffprobe_display"] = display_probe_name(filename)
    if key == "multitrack_mp4":
        audio = [stream for stream in raw["streams"] if stream.get("codec_type") == "audio"]
        if len(audio) != 1:
            raise RuntimeError("multi-track MP4 must contain exactly one synthetic audio stream")
        record["synthetic_audio_stream"] = {
            key: audio[0][key]
            for key in ("index", "codec_type", "codec_name", "sample_rate", "channels", "time_base")
            if key in audio[0]
        }
    return record, {"raw": raw, "display": display}


def build() -> None:
    assert_safe_output_directory()
    OUT.mkdir(parents=True, exist_ok=True)
    source_record, native_crc, source_probe = source_records()
    run_commands()
    write_text(OUT / "source.ffprobe.json", json.dumps(source_probe, indent=2) + "\n")
    artifacts: dict[str, Any] = {}
    for key, filename in ARTIFACTS.items():
        record, probes = artifact_record(key, filename)
        write_text(OUT / record["ffprobe"], json.dumps(probes["raw"], indent=2) + "\n")
        if probes["display"] is not None:
            write_text(OUT / record["ffprobe_display"], json.dumps(probes["display"], indent=2) + "\n")
        artifacts[key] = record
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "generator": "scripts/generate-long-container-reference.py",
        "source": source_record,
        "tooling": {
            "ffmpeg": ffmpeg_version(),
            "ffprobe": ffprobe_version(),
            "commands": command_records(),
            "remux_policy": "all AV1 packets are stream-copied; no video re-encoding is performed",
            "fragment_timestamp_postprocess": "add 2500 timescale ticks to every fragmented MP4 tfdt base decode time",
            "synthetic_audio": {
                "provenance": "FFmpeg lavfi sine source generated locally; no external audio or media",
                "frequency_hz": 440,
                "sample_rate": 48000,
                "duration_seconds": 31,
                "codec": "AAC-LC at 64 kbit/s",
            },
        },
        "sequence": {
            "width": WIDTH,
            "height": HEIGHT,
            "depth": DEPTH,
            "sampling": SAMPLING,
            "presentations": FRAMES,
            "source_time_base": "1/1200000",
            "container_timescale": TIMESCALE,
            "timestamp_offset": TIMESTAMP_OFFSET,
            "frame_duration_ticks": 40,
            "native_mapping": "selected AV1 packet order 0..705 maps one-to-one to native reference frame order 0..705",
            "native_frame_index_for_packet": list(range(FRAMES)),
        },
        "native_reference": {
            "file": rel(SOURCE_PIXELS),
            "sha256": sha256_file(SOURCE_PIXELS),
            "bytes": SOURCE_PIXELS.stat().st_size,
            "frame_bytes": FRAME_BYTES,
            "frames": FRAMES,
            "frame_crc32": native_crc,
        },
        "stream_policy": {
            "max_frames": STREAM_MAX_FRAMES,
            "max_input_bytes": STREAM_MAX_INPUT_BYTES,
            "max_chunk_bytes": STREAM_MAX_CHUNK_BYTES,
            "full_file_bytes": {key: value["bytes"] for key, value in artifacts.items()},
            "max_selected_av1_packet_bytes": max(
                value["max_selected_av1_packet_bytes"] for value in artifacts.values()
            ),
            "frame_lifetime": "retain any returned native frame across later frames, reset, and MP4 replay; each result owns independent planes",
            "packet_lifetime": "packet payloads are owned by demux batches and may be released after decode",
            "chunk_sizes_for_consumer": [1, 7, 31, 257, 4093, 16384, STREAM_MAX_CHUNK_BYTES],
        },
        "artifacts": artifacts,
    }
    write_text(OUT / "manifest.json", json.dumps(manifest, indent=2) + "\n")
    print(f"Wrote {len(ARTIFACTS)} long AV1 container fixtures and {FRAMES} native mappings")


def check() -> None:
    manifest_path = OUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != SCHEMA_VERSION:
        raise SystemExit("long-container manifest schema version differs")
    if manifest.get("generator") != "scripts/generate-long-container-reference.py":
        raise SystemExit("long-container generator identity differs")
    source_record, native_crc, source_probe = source_records()
    if manifest["source"] != source_record:
        raise SystemExit("source metadata differs from immutable av1-realvideo source")
    saved_source_probe = json.loads((OUT / "source.ffprobe.json").read_text(encoding="utf-8"))
    if source_probe != saved_source_probe:
        raise SystemExit("saved source ffprobe record differs")
    native = manifest["native_reference"]
    if native["sha256"] != sha256_file(SOURCE_PIXELS) or native["frame_crc32"] != native_crc:
        raise SystemExit("native reference mapping differs")
    if native["bytes"] != SOURCE_PIXELS.stat().st_size or native["frames"] != FRAMES:
        raise SystemExit("native reference size/frame count differs")
    if manifest["sequence"]["native_frame_index_for_packet"] != list(range(FRAMES)):
        raise SystemExit("packet/native frame index mapping differs")
    policy = manifest.get("stream_policy")
    if policy is None or policy["max_frames"] <= FRAMES:
        raise SystemExit("stream frame policy must exceed the 706-frame corpus")
    if policy["max_input_bytes"] >= max(record["bytes"] for record in manifest["artifacts"].values()):
        raise SystemExit("stream compressed input cap is not below the full corpus files")
    for key, record in manifest["artifacts"].items():
        filename = record["file"]
        path = OUT / filename
        if path.stat().st_size != record["bytes"] or sha256_file(path) != record["sha256"]:
            raise SystemExit(f"{filename} hash or size differs")
        current = probe(path, filename.endswith(".mp4"))
        saved = json.loads((OUT / record["ffprobe"]).read_text(encoding="utf-8"))
        if current != saved:
            raise SystemExit(f"{filename} ffprobe packet timing/hash/CRC record differs")
        selected = select_av1_stream(current)
        if selected != record["selected_av1_stream"]:
            raise SystemExit(f"{filename} selected AV1 stream identity differs")
        selected_packets = stream_packets(current, int(selected["index"]))
        timing = {
            "pts": [packet.get("pts") for packet in selected_packets],
            "dts": [packet.get("dts") for packet in selected_packets],
            "duration": [packet.get("duration") for packet in selected_packets],
            "flags": [packet.get("flags") for packet in selected_packets],
        }
        if timing != record["selected_av1_packet_timing"]:
            raise SystemExit(f"{filename} selected AV1 packet timing oracle differs")
        if [int(packet["size"]) for packet in selected_packets] != record["selected_av1_packet_sizes"]:
            raise SystemExit(f"{filename} selected AV1 packet size oracle differs")
        if record["max_selected_av1_packet_bytes"] != max(int(packet["size"]) for packet in selected_packets):
            raise SystemExit(f"{filename} selected AV1 max packet bound differs")
        if [packet["data_hash"] for packet in selected_packets] != record["selected_av1_packet_sha256"]:
            raise SystemExit(f"{filename} selected AV1 packet SHA-256 mapping differs")
        if [packet["crc32"] for packet in selected_packets] != record["selected_av1_packet_crc32"]:
            raise SystemExit(f"{filename} selected AV1 packet CRC mapping differs")
        current_structure = mp4_structure(path)
        if current_structure != record["structure"]:
            raise SystemExit(f"{filename} MP4 structure differs")
        if "ffprobe_display" in record:
            display = probe(path, False)
            saved_display = json.loads((OUT / record["ffprobe_display"]).read_text(encoding="utf-8"))
            if display != saved_display:
                raise SystemExit(f"{filename} display-timeline ffprobe record differs")
    print("av1-long-containers: hashes, ffprobe packet SHA-256/CRC records, MP4 structure, and native mapping match")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify without writing or running FFmpeg")
    args = parser.parse_args()
    if args.check:
        check()
    else:
        build()


if __name__ == "__main__":
    main()
