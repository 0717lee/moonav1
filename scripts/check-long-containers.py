#!/usr/bin/env python3
"""Verify long AV1 containers through complete and incremental MoonBit APIs.

The child process performs all demuxing, decoding, native pixel comparison and
packet CRC checks. This script only validates the independent ffprobe manifest,
builds the file-backed consumer, supplies bounded host file readers, and
records reproducible identities. It never writes fixture files or a duplicate
native reference. --standalone copies only the consumer into an ignored local
module; the decoder is a path dependency, and execution uses that module's
working directory. --chunk-seed varies read boundaries without changing media.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
FIXTURE_ROOT = ROOT / "tests" / "fixtures" / "av1-long-containers"
TARGETS = ("native", "js", "wasm-gc")
FORMAT_CODES = {
    "ivf": 0,
    "faststart_mp4": 1,
    "moov_tail_mp4": 1,
    "fragmented_mp4": 1,
    "webm": 2,
    "multitrack_mp4": 1,
}

spec = importlib.util.spec_from_file_location(
    "benchmark", Path(__file__).with_name("benchmark.py")
)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

reference_spec = importlib.util.spec_from_file_location(
    "long_container_reference", Path(__file__).with_name("generate-long-container-reference.py")
)
reference = importlib.util.module_from_spec(reference_spec)
reference_spec.loader.exec_module(reference)


def fail(message):
    raise SystemExit(message)


def parse_time_base(value):
    numerator, denominator = value.split("/", 1)
    numerator, denominator = int(numerator), int(denominator)
    if numerator <= 0 or denominator <= 0:
        fail(f"Unsupported time base: {value}")
    return numerator, denominator


def scale_time_base(value, numerator, denominator, label):
    """Scale a stream timestamp to nanoseconds without floating point loss."""
    scaled = int(value) * numerator * 1_000_000_000
    if scaled % denominator:
        fail(f"{label} does not have an integral nanosecond representation")
    return scaled // denominator


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def packet_crc32(data):
    return zlib.crc32(data) & 0xffffffff


def packet_payload(raw, packet):
    try:
        position = int(packet["pos"])
        size = int(packet["size"])
    except (KeyError, TypeError, ValueError) as error:
        fail(f"ffprobe packet has no usable pos/size: {error}")
    expected = packet.get("data_hash", "")
    expected = expected.split(":", 1)[1] if ":" in expected else expected
    # ffprobe's packet position is the record/block header for IVF and WebM,
    # while MP4 positions point at the sample. Resolve the actual payload by
    # the independent hash recorded in the same ffprobe manifest.
    for offset in range(0, 65):
        payload = raw[position + offset:position + offset + size]
        if len(payload) == size and sha256_bytes(payload) == expected:
            return payload
    fail(f"ffprobe packet payload hash cannot be located: pos={position} size={size}")


def validate_schema1_manifest(manifest_path, manifest):
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 1:
        fail("Unsupported legacy long-container manifest schema")
    if set(manifest["artifacts"]) != set(FORMAT_CODES):
        fail("The long-container corpus must contain all six variants")
    policy = manifest["stream_policy"]
    chunk_sizes = policy["chunk_sizes_for_consumer"]
    if (not chunk_sizes or any(type(value) is not int or value <= 0 for value in chunk_sizes)
            or max(chunk_sizes) != policy["max_chunk_bytes"]
            or policy["max_chunk_bytes"] > policy["max_input_bytes"]):
        fail("Invalid bounded chunk sequence")
    source = manifest["source"]
    native = manifest["native_reference"]
    source_ffprobe_path = FIXTURE_ROOT / source["ffprobe"]
    source_probe = json.loads(source_ffprobe_path.read_text(encoding="utf-8"))
    source_record, native_crc, _ = reference.source_records(saved_probe=source_probe)
    if source != source_record or native["frame_crc32"] != native_crc:
        fail("Source provenance or native frame mapping changed")
    source_path = ROOT / source["file"]
    reference_path = ROOT / native["file"]
    if bench.sha256(source_path) != source["sha256"]:
        fail(f"Source OBU changed: {source_path}")
    if bench.sha256(reference_path) != native["sha256"]:
        fail(f"Native reference changed: {reference_path}")
    if native["frames"] != manifest["sequence"]["presentations"]:
        fail("Native frame/presentation count differs")
    if native["bytes"] != reference_path.stat().st_size:
        fail("Native reference byte count differs")
    raw_source = source_path.read_bytes()
    for index, packet in enumerate(source_probe["packets"]):
        payload = packet_payload(raw_source, packet)
        if packet_crc32(payload) != packet.get("crc32"):
            fail(f"Saved source packet CRC differs at index {index}")

    records = {}
    fixture_hashes = {
        source_path.relative_to(ROOT).as_posix(): source["sha256"],
        reference_path.relative_to(ROOT).as_posix(): native["sha256"],
        manifest_path.relative_to(ROOT).as_posix(): bench.sha256(manifest_path),
        source_ffprobe_path.relative_to(ROOT).as_posix(): bench.sha256(source_ffprobe_path),
    }
    for name, artifact in manifest["artifacts"].items():
        if name not in FORMAT_CODES:
            fail(f"Unknown long-container artifact: {name}")
        path = FIXTURE_ROOT / artifact["file"]
        if "bytes" in artifact and path.stat().st_size != int(artifact["bytes"]):
            fail(f"Container byte count differs: {path}")
        if bench.sha256(path) != artifact["sha256"]:
            fail(f"Container changed: {path}")
        ffprobe_path = FIXTURE_ROOT / artifact["ffprobe"]
        ffprobe = json.loads(ffprobe_path.read_text(encoding="utf-8"))
        raw = path.read_bytes()
        stream_index = artifact["selected_av1_stream"]["index"]
        streams = [s for s in ffprobe.get("streams", []) if s.get("index") == stream_index]
        if len(streams) != 1 or streams[0].get("codec_name") != "av1":
            fail(f"Selected AV1 stream missing in {ffprobe_path}")
        packets = [
            packet for packet in ffprobe.get("packets", [])
            if packet.get("stream_index") == stream_index
        ]
        if len(packets) != artifact["selected_av1_packet_count"]:
            fail(f"Packet count differs in {ffprobe_path}")
        timing = {key: [packet.get(key) for packet in packets]
                  for key in ("pts", "dts", "duration", "flags")}
        if timing != artifact["selected_av1_packet_timing"]:
            fail(f"Packet timing or sync oracle differs in {name}")
        if [int(packet["size"]) for packet in packets] != artifact["selected_av1_packet_sizes"]:
            fail(f"Packet size oracle differs in {name}")
        if ("max_selected_av1_packet_bytes" in artifact and
                int(artifact["max_selected_av1_packet_bytes"]) != max(int(packet["size"]) for packet in packets)):
            fail(f"Maximum packet size oracle differs in {name}")
        packet_hashes = artifact["selected_av1_packet_sha256"]
        packet_crcs = artifact["selected_av1_packet_crc32"]
        if len(packet_hashes) != len(packets) or len(packet_crcs) != len(packets):
            fail(f"Packet evidence length differs in {name}")
        stream_time_base_numerator, stream_time_base = parse_time_base(
            artifact["selected_av1_stream"]["time_base"]
        )
        format_code = FORMAT_CODES[name]
        timescale = 1_000_000_000 if format_code == 2 else stream_time_base
        packet_records = []
        for index, packet in enumerate(packets):
            payload = packet_payload(raw, packet)
            digest = f"SHA256:{sha256_bytes(payload)}"
            if packet.get("data_hash") != digest or packet_hashes[index] != digest:
                fail(f"Packet SHA-256 differs in {name} at index {index}")
            crc = packet_crc32(payload)
            if int(packet.get("crc32", -1)) != crc or int(packet_crcs[index]) != crc:
                fail(f"Packet CRC differs in {name} at index {index}")
            flags = 0
            values = []
            for key, bit in (("pts", 1), ("dts", 2), ("duration", 4)):
                value = packet.get(key)
                if value is None:
                    values.append(0)
                else:
                    flags |= bit
                    values.append(int(value))
            if format_code != 0:
                flags |= 8
                if "K" in packet.get("flags", ""):
                    flags |= 16
            # IVF exposes timestamps only. WebM's public decoder deliberately
            # scales PTS/duration to nanoseconds and keeps DTS unknown.
            if format_code == 0:
                flags &= ~2
                values[1] = 0
                flags &= ~4
                values[2] = 0
            elif format_code == 2:
                flags &= ~2
                values[1] = 0
                for position in (0, 2):
                    if flags & (1 << position):
                        values[position] = scale_time_base(
                            values[position], stream_time_base_numerator,
                            stream_time_base, f"{name} packet {index}"
                        )
            packet_records.append({
                "flags": flags,
                "pts": values[0],
                "dts": values[1],
                "duration": values[2],
                "size": int(packet["size"]),
                "crc": crc,
            })
        records[name] = {
            "name": name,
            "format_code": format_code,
            "file": path,
            "ffprobe": ffprobe_path,
            "packets": packet_records,
            "width": int(artifact["selected_av1_stream"]["width"]),
            "height": int(artifact["selected_av1_stream"]["height"]),
            "depth": int(manifest["sequence"]["depth"]),
            "timescale": timescale,
            "frames": int(native["frames"]),
            "frame_bytes": int(native["frame_bytes"]),
            "reference": reference_path,
            "chunk_sizes": chunk_sizes,
            "schema_version": 1,
            "declared_width": int(artifact["selected_av1_stream"]["width"]),
            "declared_height": int(artifact["selected_av1_stream"]["height"]),
            "sampling": manifest["sequence"].get("sampling", "420"),
            "full_range": bool(manifest["sequence"].get("color_range", 0)),
            "color_primaries": int(manifest["sequence"].get("color_primaries", 1)),
            "transfer_characteristics": int(manifest["sequence"].get("transfer_characteristics", 1)),
            "matrix_coefficients": int(manifest["sequence"].get("matrix_coefficients", 1)),
            "frame_crc32": [int(value) for value in native["frame_crc32"]],
            "native_frame_index_for_packet": list(range(int(native["frames"]))),
            "max_input_bytes": int(policy["max_input_bytes"]),
            "complete_max_input_bytes": int(policy.get("complete_max_input_bytes", 2 * 1024 * 1024)),
            "max_frames": int(policy.get("max_frames", native["frames"] + 1)),
            "max_total_pixels": int(policy.get("max_total_pixels", 128 * 1024 * 1024)),
            "max_chunk_bytes": int(policy["max_chunk_bytes"]),
            "tail_replay": (
                name == "moov_tail_mp4"
                or not (artifact.get("structure") or {}).get("moov_before_mdat", True)
            ),
        }
        fixture_hashes[path.relative_to(ROOT).as_posix()] = artifact["sha256"]
        fixture_hashes[ffprobe_path.relative_to(ROOT).as_posix()] = bench.sha256(
            ffprobe_path
        )
    return manifest, records, fixture_hashes


def resolve_repo_path(value, label):
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        fail(f"{label} must be a repository-relative path")
    return ROOT / path


def resolve_manifest_path(manifest_path, value, label):
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        fail(f"{label} must be relative to the manifest directory")
    return manifest_path.parent / path


def validate_native_reference(path, native, label):
    """Validate native references a frame at a time, keeping memory bounded."""
    try:
        frames = int(native["frames"])
        frame_bytes = int(native["frame_bytes"])
        byte_count = int(native["bytes"])
    except (KeyError, TypeError, ValueError) as error:
        fail(f"Invalid {label} native reference metadata: {error}")
    if frames <= 0 or frame_bytes <= 0 or byte_count != frames * frame_bytes:
        fail(f"Invalid {label} native reference dimensions")
    if path.stat().st_size != byte_count:
        fail(f"Native reference byte count differs: {path}")
    crc_records = native.get("frame_crc32")
    if not isinstance(crc_records, list) or len(crc_records) != frames:
        fail(f"Native reference frame CRC mapping differs: {path}")
    hash_records = native.get("frame_sha256")
    if hash_records is not None and (not isinstance(hash_records, list) or len(hash_records) != frames):
        fail(f"Native reference frame SHA-256 mapping differs: {path}")
    with path.open("rb") as stream:
        for index in range(frames):
            data = stream.read(frame_bytes)
            if len(data) != frame_bytes:
                fail(f"Native reference frame is truncated at index {index}: {path}")
            if (zlib.crc32(data) & 0xffffffff) != int(crc_records[index]):
                fail(f"Native reference frame CRC differs at index {index}: {path}")
            if hash_records is not None and sha256_bytes(data) != hash_records[index]:
                fail(f"Native reference frame SHA-256 differs at index {index}: {path}")


def _schema2_artifact_record(manifest_path, sequence, native, policy, name, artifact,
                             source_frame_indices):
    if name not in FORMAT_CODES:
        fail(f"Unknown diverse-video artifact: {name}")
    try:
        path = resolve_manifest_path(manifest_path, artifact["file"], f"{name} artifact")
        ffprobe_path = resolve_manifest_path(manifest_path, artifact["ffprobe"], f"{name} ffprobe")
    except (KeyError, TypeError) as error:
        fail(f"Invalid {name} artifact paths: {error}")
    if "bytes" in artifact and path.stat().st_size != int(artifact["bytes"]):
        fail(f"Container byte count differs: {path}")
    if bench.sha256(path) != artifact["sha256"]:
        fail(f"Container changed: {path}")
    ffprobe = json.loads(ffprobe_path.read_text(encoding="utf-8"))
    raw = path.read_bytes()
    stream_index = artifact["selected_av1_stream"]["index"]
    streams = [s for s in ffprobe.get("streams", []) if s.get("index") == stream_index]
    if len(streams) != 1 or streams[0].get("codec_name") != "av1":
        fail(f"Selected AV1 stream missing in {ffprobe_path}")
    packets = [packet for packet in ffprobe.get("packets", [])
               if packet.get("stream_index") == stream_index]
    if len(packets) != artifact["selected_av1_packet_count"]:
        fail(f"Packet count differs in {ffprobe_path}")
    frames_path = resolve_manifest_path(manifest_path, artifact["ffprobe_frames"], f"{name} frame probe")
    frames = json.loads(frames_path.read_text(encoding="utf-8"))["frames"]
    pixel_format = 'yuv' + sequence['sampling'] + 'p' + (str(sequence['depth'])+'le' if sequence['depth'] > 8 else '')
    if len(frames) != len(packets) or any(
            str(frame.get('pkt_pos')) != str(packet.get('pos')) or frame.get('pts') != packet.get('pts') or
            (frame.get('width'),frame.get('height'),frame.get('pix_fmt')) !=
            (sequence['width'],sequence['height'],pixel_format)
            for frame,packet in zip(frames,packets)):
        fail(f"Independent decoded frame/packet mapping differs in {name}")
    timing = {key: [packet.get(key) for packet in packets]
              for key in ("pts", "dts", "duration", "flags")}
    if timing != artifact["selected_av1_packet_timing"]:
        fail(f"Packet timing or sync oracle differs in {name}")
    if [int(packet["size"]) for packet in packets] != artifact["selected_av1_packet_sizes"]:
        fail(f"Packet size oracle differs in {name}")
    if ("max_selected_av1_packet_bytes" in artifact and
            int(artifact["max_selected_av1_packet_bytes"]) != max(int(packet["size"]) for packet in packets)):
        fail(f"Maximum packet size oracle differs in {name}")
    packet_hashes = artifact["selected_av1_packet_sha256"]
    packet_crcs = artifact["selected_av1_packet_crc32"]
    if len(packet_hashes) != len(packets) or len(packet_crcs) != len(packets):
        fail(f"Packet evidence length differs in {name}")
    time_numerator, time_denominator = parse_time_base(
        artifact["selected_av1_stream"]["time_base"]
    )
    format_code = FORMAT_CODES[name]
    timescale = 1_000_000_000 if format_code == 2 else time_denominator
    native_durations = artifact.get("native_packet_durations_ns")
    if native_durations is not None:
        if format_code != 2 or len(native_durations) != len(packets):
            fail(f"Native WebM duration evidence length differs in {name}")
        native_durations = [None if value is None else int(value) for value in native_durations]
    packet_records = []
    for index, packet in enumerate(packets):
        payload = packet_payload(raw, packet)
        digest = f"SHA256:{sha256_bytes(payload)}"
        if packet.get("data_hash") != digest or packet_hashes[index] != digest:
            fail(f"Packet SHA-256 differs in {name} at index {index}")
        crc = packet_crc32(payload)
        if int(packet.get("crc32", -1)) != crc or int(packet_crcs[index]) != crc:
            fail(f"Packet CRC differs in {name} at index {index}")
        flags = 0
        values = []
        for key, bit in (("pts", 1), ("dts", 2), ("duration", 4)):
            value = packet.get(key)
            if value is None:
                values.append(0)
            else:
                flags |= bit
                values.append(int(value))
        if format_code != 0:
            flags |= 8
            if "K" in packet.get("flags", ""):
                flags |= 16
        if format_code == 0:
            flags &= ~2
            values[1] = 0
            flags &= ~4
            values[2] = 0
        elif format_code == 2:
            flags &= ~2
            values[1] = 0
            if flags & 1:
                values[0] = scale_time_base(values[0], time_numerator, time_denominator,
                                             f"{name} packet {index} PTS")
            if native_durations is not None:
                if native_durations[index] is None:
                    flags &= ~4
                    values[2] = 0
                else:
                    flags |= 4
                    values[2] = native_durations[index]
            elif flags & 4:
                values[2] = scale_time_base(values[2], time_numerator, time_denominator,
                                             f"{name} packet {index} duration")
        packet_records.append({
            "flags": flags, "pts": values[0], "dts": values[1], "duration": values[2],
            "size": int(packet["size"]), "crc": crc,
        })
    width = int(sequence["width"])
    height = int(sequence["height"])
    declared_dimensions = artifact.get("declared_dimensions") or {}
    declared_width = int(artifact.get(
        "declared_width", declared_dimensions.get("width", artifact["selected_av1_stream"]["width"])
    ))
    declared_height = int(artifact.get(
        "declared_height", declared_dimensions.get("height", artifact["selected_av1_stream"]["height"])
    ))
    rejected = artifact.get('rejected_original_export')
    rejected_path = None
    if rejected:
        rejected_path = resolve_manifest_path(manifest_path,rejected['file'],f'{name} rejected original')
        if bench.sha256(rejected_path) != rejected['sha256']:
            fail(f'Rejected original export changed: {rejected_path}')
    return {
        "name": name, "format_code": format_code, "file": path, "ffprobe": ffprobe_path,
        "packets": packet_records, "width": width, "height": height,
        "declared_width": declared_width, "declared_height": declared_height,
        "depth": int(sequence["depth"]), "sampling": sequence.get("sampling", "420"),
        "full_range": bool(sequence["full_range"]),
        "color_primaries": int(sequence["color_primaries"]),
        "transfer_characteristics": int(sequence["transfer_characteristics"]),
        "matrix_coefficients": int(sequence["matrix_coefficients"]),
        "timescale": timescale, "frames": int(native["frames"]),
        "frame_bytes": int(native["frame_bytes"]), "reference": None,
        "schema_version": 2,
        "frame_crc32": [int(value) for value in native["frame_crc32"]],
        "chunk_sizes": [int(value) for value in policy["chunk_sizes_for_consumer"]],
        "max_input_bytes": int(policy["max_input_bytes"]),
        "complete_max_input_bytes": int(policy.get("complete_max_input_bytes", 2 * 1024 * 1024)),
        "max_frames": int(policy["max_frames"]),
        "max_total_pixels": int(policy.get("max_total_pixels", 128 * 1024 * 1024)),
        "max_chunk_bytes": int(policy["max_chunk_bytes"]),
        "tail_replay": (name == "moov_tail_mp4" or
                         not (artifact.get("structure") or {}).get("moov_before_mdat", True)),
        "native_frame_index_for_packet": source_frame_indices,
        "frame_probe": frames_path,
        "rejected_original": rejected_path,
    }


def validate_schema2_manifest(manifest_path, manifest):
    cases = manifest.get("cases")
    if not isinstance(cases, list) or not cases:
        fail("Diverse-video manifest has no cases")
    records = {}
    case_names = set()
    fixture_hashes = {manifest_path.relative_to(ROOT).as_posix(): bench.sha256(manifest_path)}
    for case in cases:
        if not isinstance(case, dict) or not case.get("name"):
            fail("Invalid diverse-video case")
        name = case["name"]
        if name in case_names:
            fail(f"Duplicate diverse-video case: {name}")
        case_names.add(name)
        sequence = case.get("sequence") or {}
        native = case.get("native_reference") or {}
        policy = case.get("stream_policy") or {}
        source = case.get("source") or {}
        if sequence.get("sampling", "420") not in ("420", "444"):
            fail(f"Unsupported native reference sampling in {name}")
        source_path = resolve_repo_path(source["file"], f"{name} source")
        native_path = resolve_repo_path(native["file"], f"{name} native reference")
        if bench.sha256(source_path) != source["sha256"]:
            fail(f"Source OBU changed: {source_path}")
        if bench.sha256(native_path) != native["sha256"]:
            fail(f"Native reference changed: {native_path}")
        validate_native_reference(native_path, native, name)
        if int(native["frames"]) != int(sequence["presentations"]):
            fail(f"Native frame/presentation count differs in {name}")
        mapping = sequence.get("native_frame_index_for_packet")
        artifacts = case.get("artifacts") or {}
        if not artifacts:
            fail(f"Diverse-video case has no artifacts: {name}")
        # Packet mapping is checked after the selected artifact establishes its count.
        for artifact_name, artifact in artifacts.items():
            selected_count = int(artifact["selected_av1_packet_count"])
            if mapping is None:
                packet_mapping = list(range(selected_count))
            else:
                packet_mapping = [int(value) for value in mapping]
                if len(packet_mapping) != selected_count:
                    fail(f"Packet/native mapping length differs in {name}/{artifact_name}")
            if packet_mapping != list(range(int(native["frames"]))):
                fail(f"Packet/native mapping value differs in {name}/{artifact_name}")
            record = _schema2_artifact_record(
                manifest_path, sequence, native, policy, artifact_name, artifact,
                packet_mapping,
            )
            if sum(value >= 0 for value in packet_mapping) != int(native["frames"]):
                fail(f"Packet/native presentation mapping differs in {name}/{artifact_name}")
            record["reference"] = native_path
            record_name = re.sub(r"[^A-Za-z0-9._-]+", "_", f"{name}--{artifact_name}")
            if record_name in records:
                fail(f"Duplicate flattened artifact name: {record_name}")
            records[record_name] = record
            fixture_hashes[record["file"].relative_to(ROOT).as_posix()] = artifact["sha256"]
            fixture_hashes[record["ffprobe"].relative_to(ROOT).as_posix()] = bench.sha256(record["ffprobe"])
            fixture_hashes[record['frame_probe'].relative_to(ROOT).as_posix()] = bench.sha256(record['frame_probe'])
            if record['rejected_original']:
                fixture_hashes[record['rejected_original'].relative_to(ROOT).as_posix()] = bench.sha256(record['rejected_original'])
        # Source/native identities are shared by all formats in this case.
        fixture_hashes[source_path.relative_to(ROOT).as_posix()] = source["sha256"]
        fixture_hashes[native_path.relative_to(ROOT).as_posix()] = native["sha256"]
    return manifest, records, fixture_hashes


def validate_manifest(manifest_path):
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    schema = manifest.get("schema_version")
    if schema == 1:
        return validate_schema1_manifest(manifest_path, manifest)
    if schema == 2:
        return validate_schema2_manifest(manifest_path, manifest)
    fail("Unsupported long-container manifest schema")


def write_expectation(path, record):
    with path.open("wb") as stream:
        if record.get("schema_version", 1) == 2:
            sampling = {"420": 1, "444": 2}.get(record["sampling"])
            if sampling is None:
                fail(f"Unsupported native reference sampling: {record['sampling']}")
            stream.write(b"LCE2")
            stream.write(struct.pack(
                "<15Iq",
                record["format_code"], record["width"], record["height"],
                record["declared_width"], record["declared_height"], record["depth"],
                sampling, int(record["full_range"]), record["color_primaries"],
                record["transfer_characteristics"], record["matrix_coefficients"],
                len(record["packets"]), record["frames"], record["frame_bytes"],
                record["max_total_pixels"], record["timescale"],
            ))
            mapping = record["native_frame_index_for_packet"]
            stream.write(struct.pack("<I", len(mapping)))
            for value in mapping:
                stream.write(struct.pack("<i", int(value)))
            frame_crc32 = record["frame_crc32"]
            if len(frame_crc32) != record["frames"]:
                fail("Native frame CRC mapping length differs")
            for value in frame_crc32:
                stream.write(struct.pack("<I", int(value)))
            for packet in record["packets"]:
                stream.write(struct.pack(
                    "<BqqqII", packet["flags"], packet["pts"], packet["dts"],
                    packet["duration"], packet["size"], packet["crc"],
                ))
            stream.write(struct.pack("<I", len(record["chunk_sizes"])))
            for size in record["chunk_sizes"]:
                stream.write(struct.pack("<I", size))
            return
        stream.write(b"LCE1")
        stream.write(struct.pack(
            "<IIIIqIII",
            record["format_code"],
            record["width"],
            record["height"],
            record["depth"],
            record["timescale"],
            len(record["packets"]),
            record["frames"],
            record["frame_bytes"],
        ))
        for packet in record["packets"]:
            stream.write(struct.pack(
                "<BqqqII",
                packet["flags"],
                packet["pts"],
                packet["dts"],
                packet["duration"],
                packet["size"],
                packet["crc"],
            ))
        stream.write(struct.pack("<I", len(record["chunk_sizes"])))
        for size in record["chunk_sizes"]:
            stream.write(struct.pack("<I", size))


def command(target, artifact, consumer):
    if target == "native":
        return [str(artifact)]
    if target == "js":
        return [
            "node", "--require",
            str(consumer / "io-node.cjs"),
            str(artifact),
        ]
    return [
        "node",
        str(consumer / "run-wasm.cjs"),
        str(artifact),
    ]


def build(target, target_dir, consumer, standalone):
    result = subprocess.run([
        "moon", "run", "." if standalone else "tests/container_decode", "--frozen", "--release",
        "--target", target, "--target-dir", str(target_dir.resolve()),
        "--build-only", "--output-json",
    ], cwd=consumer if standalone else ROOT, capture_output=True, text=True, encoding="utf-8")
    if result.returncode:
        fail(result.stdout + result.stderr)
    candidates = [
        json.loads(line)["artifacts_path"]
        for line in result.stdout.splitlines()
        if line.startswith("{") and '"artifacts_path"' in line
    ]
    if len(candidates) != 1 or len(candidates[0]) != 1:
        fail(f"Unexpected Moon artifact output for {target}")
    path = Path(candidates[0][0]).resolve()
    return path


def prepare_consumer(standalone, harness_files):
    if not standalone:
        return ROOT / "tests" / "container_decode"
    consumer = ROOT / "_build" / f"standalone-container-consumer-{platform.system().lower()}"
    consumer.mkdir(parents=True, exist_ok=True)
    (consumer / "moon.mod.json").write_text(json.dumps({
        "name": "local/moonav1_file_consumer",
        "deps": {"0717lee/moonav1": {"path": ROOT.as_posix()}},
    }, indent=2) + "\n", encoding="utf-8")
    for path in harness_files:
        shutil.copyfile(path, consumer / path.name)
    return consumer


def chunk_schedule(seed, cap, max_chunk=None):
    # Split initial signatures byte by byte, cross usual header/alignment
    # boundaries, then exercise varying reads up to the selected chunk cap.
    chunk_limit = min(cap, max_chunk) if max_chunk is not None else cap
    rng = random.Random(seed)
    boundaries = [min(chunk_limit, n) for n in (7, 8, 11, 12, 31, 32, 33, 4095, 4096, 4097)]
    return [1] * 32 + boundaries + [chunk_limit, max(1, chunk_limit - 1)] + [
        rng.randint(1, chunk_limit) for _ in range(64)
    ]


def parse_result(stdout):
    lines = [
        line.strip() for line in stdout.splitlines()
        if line.strip().startswith("RESULT ")
    ]
    if not lines:
        return None
    result = {}
    for field in lines[-1][len("RESULT "):].split():
        key, value = field.split("=", 1)
        if key == "mode":
            result[key] = value
        elif value in ("true", "false"):
            result[key] = value == "true"
        else:
            result[key] = int(value)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=FIXTURE_ROOT / "manifest.json")
    parser.add_argument("--case", action="append", default=[])
    parser.add_argument("--targets", nargs="+", choices=TARGETS, default=list(TARGETS))
    parser.add_argument("--target-dir", type=Path, default=ROOT / "_build" / "long-container")
    parser.add_argument("--output", type=Path, default=ROOT / "_build" / "long-container-results.json")
    parser.add_argument("--timeout", type=float, default=1200)
    parser.add_argument("--standalone", action="store_true", help="build a separate local path-dependency module and run outside the library module")
    parser.add_argument("--chunk-seed", type=int, help="use a reproducible varied chunk schedule instead of the manifest schedule")
    parser.add_argument("--modes", nargs="+", choices=("complete", "stream"), default=["complete", "stream"])
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--check", action="store_true", help="validate fixture and ffprobe evidence without building")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    manifest_path = args.manifest.resolve()
    manifest, records, fixture_hashes = validate_manifest(manifest_path)
    selected = list(records)
    if args.case:
        selected = [name for name in records
                    if name in args.case or any(name.startswith(case + "--") for case in args.case)]
        unknown = set(args.case) - set(records) - {
            name.split("--", 1)[0] for name in records
        }
        if unknown:
            parser.error(f"Unknown container case(s): {', '.join(sorted(unknown))}")
    for name, record in records.items():
        stream_cap = record["max_input_bytes"]
        complete_cap = record["complete_max_input_bytes"]
        max_frames = record["max_frames"]
        if (not record["chunk_sizes"] or
                any(type(value) is not int or value <= 0 for value in record["chunk_sizes"]) or
                max(record["chunk_sizes"]) > record["max_chunk_bytes"] or
                record["max_chunk_bytes"] > stream_cap):
            fail(f"Invalid bounded chunk policy for {name}")
        if max_frames <= record["frames"]:
            fail(f"Stream frame cap must exceed frame count for {name}")
        if complete_cap <= 0 or stream_cap <= 0:
            fail(f"Invalid input cap for {name}")
        max_packet = max(packet["size"] for packet in record["packets"])
        if max_packet >= stream_cap or max_packet >= complete_cap:
            fail(f"Reference packet does not fit selected input cap for {name}")
        if not 0 < record["max_total_pixels"] <= 0x7fffffff:
            fail(f"Invalid pixel cap for {name}")
    if args.check:
        print(f"Validated {len(selected)} long-container fixture(s) and ffprobe packet evidence")
        return

    if args.chunk_seed is not None:
        for record in records.values():
            record["chunk_sizes"] = chunk_schedule(
                args.chunk_seed, record["max_input_bytes"], record["max_chunk_bytes"]
            )

    source_files = [
        path for path in ROOT.glob("*.mbt")
        if not path.stem.endswith(("_test", "_wbtest"))
    ]
    harness_files = [
        path for path in (ROOT / "tests" / "container_decode").iterdir()
        if path.suffix in (".mbt", ".c", ".cjs") or path.name == "moon.pkg"
    ]
    consumer = prepare_consumer(args.standalone, harness_files)
    report = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "machine": platform.platform(),
        "source_sha256": bench.digest(source_files + [ROOT / "moon.mod", ROOT / "moon.pkg"]),
        "harness_sha256": bench.digest(harness_files + [
            Path(__file__).resolve(), Path(reference.__file__).resolve(),
        ]),
        "manifest_sha256": bench.sha256(manifest_path),
        "fixture_hashes": fixture_hashes,
        "moon_version": bench.run(["moon", "version", "--all"]).stdout.strip(),
        "node_version": bench.run(["node", "--version"]).stdout.strip(),
        "node_runtime": bench.run(["node", "-p", "process.platform + ':' + process.arch"]).stdout.strip(),
        "git_head": bench.run(["git", "rev-parse", "HEAD"]).stdout.strip(),
        "timeout_seconds": args.timeout,
        "consumer": "local/moonav1_file_consumer" if args.standalone else "0717lee/moonav1/tests/container_decode",
        "dependency": "local path" if args.standalone else "same module",
        "reference_check": "saved source/container packets and native pixels; no external tools invoked",
        "process_cwd": consumer.relative_to(ROOT).as_posix() if args.standalone else ".",
        "chunk_seed": args.chunk_seed,
        "chunk_sizes": {name: records[name]["chunk_sizes"] for name in selected},
        "artifacts": {},
        "runs": [],
    }
    args.output.resolve().parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="moonav1-long-container-") as temporary:
        temporary_root = Path(temporary)
        expectations = {}
        for name in selected:
            safe_name = re.sub(r"[^A-Za-z0-9._-]+", "_", name)
            expectation = temporary_root / f"{safe_name}.expect"
            write_expectation(expectation, records[name])
            expectations[name] = expectation
        for target in args.targets:
            print(f"Building long-container consumer: {target}", flush=True)
            artifact = build(target, args.target_dir, consumer, args.standalone)
            report["artifacts"][target] = {
                "path": artifact.relative_to(ROOT).as_posix(),
                "sha256": bench.sha256(artifact),
            }
        if args.build_only:
            args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
            print(f"Saved build identity: {args.output}")
            return
        for target in args.targets:
            artifact = ROOT / report["artifacts"][target]["path"]
            for name in selected:
                record = records[name]
                stream_cap = record["max_input_bytes"]
                complete_cap = record["complete_max_input_bytes"]
                max_frames = record["max_frames"]
                for mode_name, mode_code in (
                    ("complete", 0), ("stream", 2 if record["tail_replay"] else 1)
                ):
                    if mode_name not in args.modes:
                        continue
                    cap = complete_cap if mode_name == "complete" else stream_cap
                    environment = os.environ.copy()
                    environment.update({
                        "MOONAV1_CONTAINER_INPUT": str(record["file"]),
                        "MOONAV1_CONTAINER_REFERENCE": str(record["reference"]),
                        "MOONAV1_CONTAINER_EXPECTATION": str(expectations[name]),
                        "MOONAV1_CONTAINER_CONFIG": f"{mode_code},{cap},{max_frames},{record['max_total_pixels']},{int(bool(record.get('rejected_original')))}",
                        "MOONAV1_CONTAINER_REJECTED": str(record.get("rejected_original") or ""),
                    })
                    started = time.monotonic()
                    try:
                        process = subprocess.run(
                            command(target, artifact, consumer), cwd=consumer if args.standalone else ROOT, env=environment,
                            capture_output=True, text=True, encoding="utf-8",
                            timeout=args.timeout,
                        )
                        stdout, stderr = process.stdout, process.stderr
                        status = "passed" if process.returncode == 0 else "failed"
                    except subprocess.TimeoutExpired as error:
                        stdout = error.stdout or ""
                        stderr = error.stderr or ""
                        if isinstance(stdout, bytes):
                            stdout = stdout.decode("utf-8", errors="replace")
                        if isinstance(stderr, bytes):
                            stderr = stderr.decode("utf-8", errors="replace")
                        status = "timeout"
                    if record.get("rejected_original") and "REJECTED original_error=InvalidData" not in stdout:
                        status = "failed"
                    parsed = parse_result(stdout)
                    dx = 2 if record["sampling"] != "444" else 1
                    dy = 2 if record["sampling"] == "420" else 1
                    frame_samples = (
                        record["width"] * record["height"]
                        + 2 * ((record["width"] + dx - 1) // dx)
                        * ((record["height"] + dy - 1) // dy)
                    )
                    expected_samples = record["frames"] * frame_samples
                    if status == "passed":
                        if parsed is None:
                            status = "failed"
                        elif (
                            parsed.get("mode") != mode_name
                            or parsed.get("frames") != record["frames"]
                            or parsed.get("samples") != expected_samples
                            or parsed.get("reset") is not True
                            or (mode_name == "stream" and parsed.get("pre_eof") is not True)
                            or (mode_name == "stream" and parsed.get("peak_pending", cap + 1) > cap)
                            or (mode_name == "stream" and parsed.get("replay") != record["tail_replay"])
                            or (mode_name == "stream" and any(parsed.get(key) is not True for key in (
                                "input_reuse", "recovery", "metadata_owned", "auto_format"
                            )))
                        ):
                            status = "failed"
                    run = {
                        "target": target,
                        "case": name,
                        "mode": mode_name,
                        "status": status,
                        "frames": parsed.get("frames") if parsed else None,
                        "samples": parsed.get("samples") if parsed else None,
                        "expected_frames": record["frames"],
                        "expected_samples": expected_samples,
                        "peak_pending": parsed.get("peak_pending") if parsed else None,
                        "pending_cap": cap if mode_name == "stream" else 0,
                        "artifact_sha256": report["artifacts"][target]["sha256"],
                        "elapsed_seconds": time.monotonic() - started,
                        "output": (stdout + stderr)[-6000:],
                    }
                    report["runs"].append(run)
                    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
                    print(
                        f"{target} {name} {mode_name}: {status} "
                        f"frames={run['frames']} samples={run['samples']} "
                        f"peak_pending={run['peak_pending']}",
                        flush=True,
                    )
                    if status != "passed":
                        fail(f"Long-container verification failed; see {args.output}")
    print(f"Passed {len(report['runs'])} long-container checks")


if __name__ == "__main__":
    main()
