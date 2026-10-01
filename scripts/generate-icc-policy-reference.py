#!/usr/bin/env python3
"""Generate independent ICC intent/BPC policy references.

The oracle is LittleCMS 2.19's public ``cmsCreateTransform``/
``cmsDoTransform`` ABI.  The profiles are synthetic and are assembled by
this script so that no installed or vendor profile becomes a test fixture.
Generation writes only ``tests/fixtures/icc-policy`` and
``icc_policy_reference_wbtest.mbt``.  ``--check`` is read-only.
"""

from __future__ import annotations

import argparse
import ctypes as C
import ctypes.util
import hashlib
import json
from pathlib import Path
import struct
import subprocess


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tests/fixtures/icc-policy"
TEST = ROOT / "icc_policy_reference_wbtest.mbt"
TYPE_RGBA16 = (4 << 16) | (3 << 3) | 2 | (1 << 7)
TYPE_GRAYA16 = (3 << 16) | (1 << 3) | 2 | (1 << 7)
COPY_ALPHA = 0x04000000
NO_OPTIMIZE = 0x0100
BPC = 0x2000
INTENTS = {"perceptual": 0, "relative": 1, "saturation": 2, "absolute": 3}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class LittleCMS:
    """Only public symbols from lcms2.h are used by the reference."""

    def __init__(self) -> None:
        name = ctypes.util.find_library("lcms2")
        if not name:
            raise RuntimeError("LittleCMS (lcms2) was not found")
        self.lib = C.CDLL(name)
        handle = C.c_void_p
        self.lib.cmsGetEncodedCMMversion.argtypes = []
        self.lib.cmsGetEncodedCMMversion.restype = C.c_int
        if self.lib.cmsGetEncodedCMMversion() != 2190:
            raise RuntimeError("ICC policy references require LittleCMS 2.19")
        self.lib.cmsOpenProfileFromMem.argtypes = [C.c_void_p, C.c_uint32]
        self.lib.cmsOpenProfileFromMem.restype = handle
        self.lib.cmsCreate_sRGBProfile.argtypes = []
        self.lib.cmsCreate_sRGBProfile.restype = handle
        self.lib.cmsCreateTransform.argtypes = [handle, C.c_uint32, handle, C.c_uint32, C.c_uint32, C.c_uint32]
        self.lib.cmsCreateTransform.restype = handle
        self.lib.cmsDoTransform.argtypes = [handle, C.c_void_p, C.c_void_p, C.c_uint32]
        self.lib.cmsDoTransform.restype = None
        self.lib.cmsDeleteTransform.argtypes = [handle]
        self.lib.cmsDeleteTransform.restype = None
        self.lib.cmsCloseProfile.argtypes = [handle]
        self.lib.cmsCloseProfile.restype = C.c_int

    def transform(self, profile: bytes, samples: list[int], intent: int, bpc: bool = False, gray: bool = False, optimized: bool = False) -> list[int]:
        raw = struct.pack(f"<{len(samples)}H", *samples)
        source_mem = C.create_string_buffer(profile)
        source = self.lib.cmsOpenProfileFromMem(source_mem, len(profile))
        target = self.lib.cmsCreate_sRGBProfile()
        if not source or not target:
            if source:
                self.lib.cmsCloseProfile(source)
            if target:
                self.lib.cmsCloseProfile(target)
            raise RuntimeError("LittleCMS profile allocation failed")
        # Evaluate the actual profile stages. LittleCMS's optional composite
        # resampling LUT can differ by hundreds of UInt16 codes for these
        # deliberately steep synthetic Lab lattices. Keep that output as
        # diagnostic evidence; do not loosen the direct-transform tolerance.
        flags = COPY_ALPHA | (BPC if bpc else 0) | (0 if optimized else NO_OPTIMIZE)
        source_format = TYPE_GRAYA16 if gray else TYPE_RGBA16
        transform = self.lib.cmsCreateTransform(source, source_format, target, TYPE_RGBA16, intent, flags)
        if not transform:
            self.lib.cmsCloseProfile(source)
            self.lib.cmsCloseProfile(target)
            raise RuntimeError(f"LittleCMS transform creation failed for intent={intent}, bpc={bpc}")
        try:
            source_buffer = C.create_string_buffer(raw)
            count = len(samples) // (2 if gray else 4)
            result = (C.c_uint16 * (count * 4))()
            self.lib.cmsDoTransform(transform, source_buffer, result, count)
            return list(result)
        finally:
            self.lib.cmsDeleteTransform(transform)
            self.lib.cmsCloseProfile(source)
            self.lib.cmsCloseProfile(target)


def u16(value: int) -> bytes:
    return struct.pack(">H", value)


def u32(value: int) -> bytes:
    return struct.pack(">I", value)


def s15f16(value: float) -> bytes:
    return struct.pack(">i", round(value * 65536.0))


def align(data: bytearray) -> None:
    data.extend(b"\0" * ((-len(data)) % 4))


def xyz(x: float, y: float, z: float) -> bytes:
    return b"XYZ " + b"\0" * 4 + s15f16(x) + s15f16(y) + s15f16(z)


def identity_curve() -> bytes:
    return b"curv" + b"\0" * 4 + u32(0)


def mab_tag(offset_values: tuple[float, float, float], grids: tuple[int, int, int] = (2, 3, 4)) -> bytes:
    """A v4 A-CLUT-B Lab pipeline with nonuniform grid dimensions."""
    data = bytearray(b"\0" * 32)
    data[0:4] = b"mAB "
    data[8] = data[9] = 3
    clut_offset = len(data)
    data[24:28] = u32(clut_offset)
    data.extend(bytes((grids[0], grids[1], grids[2])) + b"\0" * 13)
    data.append(2)
    data.extend(b"\0" * 3)
    for r in range(grids[0]):
        for g in range(grids[1]):
            for b in range(grids[2]):
                rr = r / (grids[0] - 1)
                gg = g / (grids[1] - 1)
                bb = b / (grids[2] - 1)
                values = (
                    int(max(0.0, min(1.0, offset_values[0] + 0.64 * rr + 0.20 * gg + 0.16 * bb)) * 65535.0 + 0.5),
                    int(max(0.0, min(1.0, offset_values[1] + 0.18 * rr + 0.56 * gg + 0.26 * bb)) * 65535.0 + 0.5),
                    int(max(0.0, min(1.0, offset_values[2] + 0.22 * rr + 0.24 * gg + 0.54 * bb)) * 65535.0 + 0.5),
                )
                for value in values:
                    data.extend(u16(value))
    align(data)
    b_offset = len(data)
    data[12:16] = u32(b_offset)
    data.extend(identity_curve() * 3)
    align(data)
    a_offset = len(data)
    data[28:32] = u32(a_offset)
    data.extend(identity_curve() * 3)
    return bytes(data)


def profile(
    tags: list[tuple[str, bytes]],
    with_black_point: bool = False,
    version: int = 4,
    color_space: bytes = b"RGB ",
    pcs: bytes = b"Lab ",
    media_white: tuple[float, float, float] = (0.9642, 1.0, 0.8249),
    add_media_white: bool = True,
) -> bytes:
    if with_black_point:
        # This tag is an ignored control: stock LittleCMS computes input black
        # from the transform rather than trusting bkpt. The paired no-bkpt
        # profile must produce the same compensated result.
        tags = tags + [("bkpt", xyz(-0.01033396, 0.00774863, 0.08483864))]
    if add_media_white:
        tags = tags + [("wtpt", xyz(*media_white))]
    table_end = 132 + len(tags) * 12
    data = bytearray(b"\0" * table_end)
    data[8:12] = bytes.fromhex("04400000" if version == 4 else "02100000")
    data[12:16] = b"mntr"
    data[16:20] = color_space
    data[20:24] = pcs
    data[36:40] = b"acsp"
    data[68:80] = s15f16(0.9642) + s15f16(1.0) + s15f16(0.8249)
    struct.pack_into(">I", data, 128, len(tags))
    for index, (name, payload) in enumerate(tags):
        align(data)
        offset = len(data)
        data.extend(payload)
        struct.pack_into(">4sII", data, 132 + index * 12, name.encode("ascii"), offset, len(payload))
    struct.pack_into(">I", data, 0, len(data))
    return bytes(data)


def gamma_curve(gamma: float = 1.0) -> bytes:
    value = max(1, min(65535, round(gamma * 256.0)))
    return b"curv" + b"\0" * 4 + u32(1) + u16(value) + b"\0" * 2


def matrix_rgb_profile(version: int, media_white: tuple[float, float, float]) -> bytes:
    x, y, z = media_white
    return profile([
        ("rXYZ", xyz(x, 0.0, 0.0)),
        ("gXYZ", xyz(0.0, y, 0.0)),
        ("bXYZ", xyz(0.0, 0.0, z)),
        ("rTRC", gamma_curve()),
        ("gTRC", gamma_curve()),
        ("bTRC", gamma_curve()),
    ], version=version, color_space=b"RGB ", pcs=b"XYZ ", media_white=media_white)


def matrix_gray_profile(version: int, media_white: tuple[float, float, float]) -> bytes:
    return profile([
        ("kTRC", gamma_curve()),
    ], version=version, color_space=b"GRAY", pcs=b"XYZ ", media_white=media_white)


def mft2_tag(lightness: int) -> bytes:
    data = bytearray(52)
    data[:4] = b"mft2"
    data[8:11] = bytes((3, 3, 2))
    for index in (0, 4, 8):
        struct.pack_into(">i", data, 12 + 4 * index, 65536)
    data[48:52] = u16(2) + u16(2)
    data.extend((u16(0) + u16(65535)) * 3)
    for r in (0, 1):
        for g in (0, 1):
            for b in (0, 1):
                # Colored nonzero black and different intent lightness make
                # v2 input black detection and intent selection observable.
                for value in (lightness + 25000 * r + 8000 * g + 4000 * b,
                              31000 + 1000 * r + 1500 * g,
                              34000 - 1000 * b - 500 * g):
                    data.extend(u16(value))
    data.extend((u16(0) + u16(65535)) * 3)
    return bytes(data)


def make_profiles() -> dict[str, bytes]:
    all_intents = profile([
        ("A2B0", mab_tag((0.04, 0.28, 0.26))),
        ("A2B1", mab_tag((0.07, 0.22, 0.29))),
        ("A2B2", mab_tag((0.12, 0.18, 0.23))),
        ("A2B3", mab_tag((0.16, 0.14, 0.20))),
    ], with_black_point=True)
    relative_only = profile([("A2B1", mab_tag((0.07, 0.22, 0.29)))])
    no_bkpt = profile([
        ("A2B0", mab_tag((0.04, 0.28, 0.26))),
        ("A2B1", mab_tag((0.07, 0.22, 0.29))),
        ("A2B2", mab_tag((0.12, 0.18, 0.23))),
        ("A2B3", mab_tag((0.16, 0.14, 0.20))),
    ])
    matrix_rgb_v2 = matrix_rgb_profile(2, (0.95047, 1.0, 1.08883))
    matrix_rgb_v4_d65 = matrix_rgb_profile(4, (0.95047, 1.0, 1.08883))
    gray_v2 = matrix_gray_profile(2, (0.9642, 1.0, 0.8249))
    gray_v4_d65 = matrix_gray_profile(4, (0.95047, 1.0, 1.08883))
    bad_grid = bytearray(relative_only)
    a2b_offset = struct.unpack_from(">I", bad_grid, 136)[0]
    clut_offset = struct.unpack_from(">I", bad_grid, a2b_offset + 24)[0]
    bad_grid[a2b_offset + clut_offset] = 1
    return {
        "all_intents_mab_nonuniform": all_intents,
        "relative_only": relative_only,
        "all_intents_without_bkpt": no_bkpt,
        "matrix_rgb_v2_all_intents": matrix_rgb_v2,
        "matrix_rgb_v4_d65_all_intents": matrix_rgb_v4_d65,
        "gray_v2_all_intents": gray_v2,
        "gray_v4_d65_all_intents": gray_v4_d65,
        "matrix_rgb_v2_d65_all_intents": matrix_rgb_profile(2, (0.9505, 1.0, 1.089)),
        "gray_v2_d65_all_intents": matrix_gray_profile(2, (0.9505, 1.0, 1.089)),
        "lut_v2_all_intents": profile([
            ("A2B0", mft2_tag(4000)), ("A2B1", mft2_tag(6000)),
            ("A2B2", mft2_tag(8000)),
        ], version=2),
        "saturation_perceptual_fallback": profile([
            ("A2B0", mab_tag((0.04, 0.28, 0.26))),
            ("A2B1", mab_tag((0.07, 0.22, 0.29))),
        ]),
        "malformed_mab_grid": bytes(bad_grid),
    }


def moon_bytes(data: bytes) -> str:
    rows = []
    for index in range(0, len(data), 16):
        rows.append("  " + ", ".join(f"0x{byte:02x}" for byte in data[index:index + 16]) + ",")
    return "[\n" + "\n".join(rows) + "\n]"


def make_manifest(lcms: LittleCMS, profiles: dict[str, bytes]) -> dict[str, object]:
    samples = [0, 8192, 16384, 65535, 32768, 49152, 24576, 61166, 65535, 65535, 0, 32768, 12345, 54321, 22222, 77]
    gray_samples = [samples[index] for index in range(0, len(samples), 4) for _ in (0, 1)]
    for index in range(0, len(gray_samples), 2):
        gray_samples[index + 1] = samples[index * 2 + 3]
    rows: list[dict[str, object]] = []
    for name, data in profiles.items():
        is_gray = name.startswith("gray_")
        oracle_samples = gray_samples if is_gray else samples
        row: dict[str, object] = {"name": name, "file": f"{name}.icc", "bytes": len(data), "sha256": sha256(data), "gray": is_gray}
        if not name.startswith(("matrix_", "gray_")):
            row["grid"] = ([2, 2, 2] if name == "lut_v2_all_intents"
                           else [1, 3, 4] if name == "malformed_mab_grid" else [2, 3, 4])
        if name == "malformed_mab_grid":
            row["library_expected"] = "Rejected"
        elif name == "relative_only":
            row["library_expected"] = "Accepted"
            row["relative_rgba16"] = lcms.transform(data, oracle_samples, INTENTS["relative"], gray=is_gray)
            row["relative_bpc_rgba16"] = lcms.transform(data, oracle_samples, INTENTS["relative"], True, gray=is_gray)
        else:
            row["library_expected"] = "Accepted"
            row["intents_rgba16"] = {intent: lcms.transform(data, oracle_samples, code, gray=is_gray) for intent, code in INTENTS.items()}
            row["relative_bpc_rgba16"] = lcms.transform(data, oracle_samples, INTENTS["relative"], True, gray=is_gray)
        if row["library_expected"] == "Accepted":
            selected_intents = {"relative": 1} if name == "relative_only" else INTENTS
            row["optimized_diagnostic_rgba16"] = {
                intent: lcms.transform(data, oracle_samples, code, gray=is_gray, optimized=True)
                for intent, code in selected_intents.items()
            }
        row["samples"] = samples
        row["oracle_samples"] = oracle_samples
        rows.append(row)
    return {
        "oracle": {
            "littlecms": "2.19",
            "abi": "cmsCreateTransform/cmsDoTransform",
            "flags": {"cmsFLAGS_COPY_ALPHA": COPY_ALPHA, "cmsFLAGS_NOOPTIMIZE": NO_OPTIMIZE, "cmsFLAGS_BLACKPOINTCOMPENSATION": BPC},
            "intent_codes": INTENTS,
            "target": "LittleCMS cmsCreate_sRGBProfile",
        },
        "profiles": rows,
        "references": [
            "https://www.color.org/specification/ICC1v43_2010-12.pdf",
            "https://www.color.org/specification/ICC.1-2022-05.pdf",
            "https://github.com/mm2/Little-CMS/blob/master/include/lcms2.h",
            "https://raw.githubusercontent.com/mm2/Little-CMS/lcms2.19/src/cmsio1.c",
            "https://raw.githubusercontent.com/mm2/Little-CMS/lcms2.19/src/cmscnvrt.c",
            "https://raw.githubusercontent.com/mm2/Little-CMS/lcms2.19/src/cmssamp.c",
        ],
    }


def make_test(manifest: dict[str, object], profiles: dict[str, bytes]) -> str:
    lines = [
        "/// Generated by scripts/generate-icc-policy-reference.py.",
        "/// Outputs are independent LittleCMS 2.19 public-ABI references.",
        "",
        "fn icc_policy_assert(profile_bytes : Array[Byte], source : Array[Int], expected : Array[Int], options : IccTransformOptions) -> Unit raise {",
        "  let profile = IccProfile::parse(profile_bytes).unwrap()",
        "  let source_image : Image16 = { width: source.length() / 4, height: 1, data: FixedArray::makei(source.length(), i => source[i].to_uint16()), }",
        "  let actual = profile.apply_rgba16_with_options(source_image, options).unwrap()",
        "  assert_eq(actual.data.length(), expected.length())",
        "  for i in 0..<expected.length() {",
        "    let difference = actual.data[i].to_int() - expected[i]",
        "    if i % 4 == 3 { assert_eq(difference, 0) } else { assert_true(difference >= -8 && difference <= 8, msg=\"ICC policy channel differs at \\{i}: \\{actual.data[i]} versus \\{expected[i]}\") }",
        "  }",
        "}",
        "",
    ]
    for row in manifest["profiles"]:
        name = row["name"]
        bytes_literal = moon_bytes(profiles[name])
        lines += ["///|", f'test "ICC policy fixture {name}" {{', f"  let profile : Array[Byte] = {bytes_literal}"]
        samples = json.dumps(row["samples"])
        if row["library_expected"] == "Rejected":
            lines += [
                "  match IccProfile::parse(profile) { Err(error) => assert_eq(error.kind, InvalidData); Ok(_) => fail(\"malformed nonuniform CLUT was accepted\") }",
                "}", "",
            ]
            continue
        if name == "relative_only":
            lines += [f"  let source = {samples}", f"  let expected = {json.dumps(row['relative_rgba16'])}", "  icc_policy_assert(profile, source, expected, IccTransformOptions::new(RelativeColorimetric, false))", f"  let expected_bpc = {json.dumps(row['relative_bpc_rgba16'])}", "  icc_policy_assert(profile, source, expected_bpc, IccTransformOptions::new(RelativeColorimetric, true))", "}", ""]
            continue
        for intent in ("perceptual", "relative", "saturation", "absolute"):
            lines += [f"  let source_{intent} = {samples}", f"  let expected_{intent} = {json.dumps(row['intents_rgba16'][intent])}", f"  icc_policy_assert(profile, source_{intent}, expected_{intent}, IccTransformOptions::new({'Perceptual' if intent == 'perceptual' else 'RelativeColorimetric' if intent == 'relative' else 'Saturation' if intent == 'saturation' else 'AbsoluteColorimetric'}, false))"]
        if row.get("relative_bpc_rgba16") is not None:
            lines += [f"  let expected_bpc = {json.dumps(row['relative_bpc_rgba16'])}", "  icc_policy_assert(profile, source_relative, expected_bpc, IccTransformOptions::new(RelativeColorimetric, true))"]
        lines += ["}", ""]
    lines += [
        "///|",
        'test "ICC policy rejects unavailable perceptual table and derives relative BPC" {',
        f"  let profile : Array[Byte] = {moon_bytes(profiles['relative_only'])}",
        "  let source : Image16 = { width: 1, height: 1, data: [0, 0, 0, 77], }",
        "  let parsed = IccProfile::parse(profile).unwrap()",
        "  match parsed.apply_rgba16_with_options(source, IccTransformOptions::new(Perceptual, false)) { Err(error) => assert_eq(error.kind, Unsupported); Ok(_) => fail(\"missing perceptual table was accepted\") }",
        "  let _ = parsed.apply_rgba16_with_options(source, IccTransformOptions::new(RelativeColorimetric, true)).unwrap()",
        "}",
        "",
    ]
    return subprocess.run(
        ["moonfmt", "-"], input="\n".join(lines), text=True,
        encoding="utf8", capture_output=True, check=True,
    ).stdout


def write(manifest: dict[str, object], profiles: dict[str, bytes]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for row in manifest["profiles"]:
        (OUT / row["file"]).write_bytes(profiles[row["name"]])
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    (OUT / "README.md").write_text(
        "# ICC policy references\n\n"
        "Synthetic v4 RGB/Lab profiles generated by `scripts/generate-icc-policy-reference.py`. "
        "Expected pixels come from LittleCMS 2.19's public `cmsCreateTransform` and `cmsDoTransform` ABI, "
        "using intent codes 0–3, `cmsFLAGS_COPY_ALPHA | cmsFLAGS_NOOPTIMIZE`, and the explicit BPC flag. "
        "NOOPTIMIZE evaluates the profile stages directly rather than an approximate composite LUT; "
        "optimized outputs are retained separately as diagnostic evidence. RGB tolerance remains 8 UInt16 codes; alpha is exact. "
        "The corpus also contains synthetic RGB/Gray matrix/TRC v2/v4 profiles, including a non-D50 v4 "
        "absolute-colorimetric case. The nonuniform mAB CLUT is 2×3×4; its A2B3 tag is retained as an "
        "ignored fixed-point absolute-intent control. The one-point grid is a negative case for the library's 2–65-point contract. "
        "No installed or vendor profile is included. `--check` is read-only.\n",
        encoding="utf-8", newline="\n",
    )
    TEST.write_text(make_test(manifest, profiles), encoding="utf-8", newline="\n")


def check() -> None:
    manifest = json.loads((OUT / "manifest.json").read_text(encoding="utf-8"))
    profiles = {row["name"]: (OUT / row["file"]).read_bytes() for row in manifest["profiles"]}
    for row in manifest["profiles"]:
        data = profiles[row["name"]]
        if len(data) != row["bytes"] or sha256(data) != row["sha256"]:
            raise SystemExit(f"{row['name']} profile hash or length differs")
    lcms = LittleCMS()
    for row in manifest["profiles"]:
        if row["library_expected"] != "Accepted":
            continue
        data = profiles[row["name"]]
        oracle_samples = row["oracle_samples"]
        if row["name"] == "relative_only":
            if lcms.transform(data, oracle_samples, INTENTS["relative"], gray=row["gray"]) != row["relative_rgba16"]:
                raise SystemExit("relative-only LittleCMS output differs")
        for intent, code in INTENTS.items():
            if row["name"] == "relative_only":
                break
            if lcms.transform(data, oracle_samples, code, gray=row["gray"]) != row["intents_rgba16"][intent]:
                raise SystemExit(f"{row['name']} {intent} output differs")
        if row.get("relative_bpc_rgba16") is not None and lcms.transform(data, oracle_samples, 1, True, gray=row["gray"]) != row["relative_bpc_rgba16"]:
            raise SystemExit(f"{row['name']} BPC output differs")
        for intent, expected in row["optimized_diagnostic_rgba16"].items():
            if lcms.transform(data, oracle_samples, INTENTS[intent], gray=row["gray"], optimized=True) != expected:
                raise SystemExit(f"{row['name']} optimized diagnostic differs")
    if TEST.read_text(encoding="utf-8") != make_test(manifest, profiles):
        raise SystemExit("icc_policy_reference_wbtest.mbt differs")
    print("icc-policy: profiles, LittleCMS outputs, and tests match")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify saved output without writing")
    args = parser.parse_args()
    if args.check:
        check()
    else:
        lcms = LittleCMS()
        profiles = make_profiles()
        write(make_manifest(lcms, profiles), profiles)
        print(f"Wrote {len(profiles)} ICC policy profiles and {TEST.name}")


if __name__ == "__main__":
    main()
