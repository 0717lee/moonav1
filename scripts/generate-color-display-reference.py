#!/usr/bin/env python3
"""Generate independent ICC, HDR, and fractional-display reference vectors.

The ICC references are produced by LittleCMS directly through its public C ABI.
The vectors
are intentionally independent of MoonAV1's color, tone-map, or resampling
code.  Generation writes only ``tests/fixtures/color-display`` and
``color_display_reference_wbtest.mbt``.  ``--check`` is read-only and does not
load or write any MoonAV1 output.
"""

from __future__ import annotations

import argparse
import ctypes as C
import ctypes.util
from decimal import Decimal, localcontext
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import struct
import subprocess


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tests/fixtures/color-display"
TEST = ROOT / "color_display_reference_wbtest.mbt"
LCMS_COPY_ALPHA = 0x04000000


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def lcms_format(colorspace: int, channels: int, extra: int = 0) -> int:
    # lcms2.h TYPE_* macros.  The reference uses native-endian UInt16 samples;
    # Windows and the recorded WSL runner are little endian.
    return (colorspace << 16) | (channels << 3) | 2 | (extra << 7)


TYPE_GRAYA16 = lcms_format(3, 1, 1)
TYPE_RGB16 = lcms_format(4, 3)
TYPE_RGBA16 = lcms_format(4, 3, 1)
TYPE_CMYK16 = lcms_format(6, 4)
TYPE_CMYKA16 = lcms_format(6, 4, 1)
TYPE_LAB16 = lcms_format(10, 3)
TYPE_LABV2_16 = lcms_format(30, 3)


class LittleCMS:
    """Small, explicit ctypes wrapper around the LittleCMS profile API."""

    def __init__(self) -> None:
        name = ctypes.util.find_library("lcms2")
        if not name:
            raise RuntimeError("LittleCMS (lcms2) was not found")
        self.lib = C.CDLL(name)
        handle = C.c_void_p
        self.lib.cmsOpenProfileFromMem.argtypes = [C.c_void_p, C.c_uint32]
        self.lib.cmsOpenProfileFromMem.restype = handle
        self.lib.cmsCreate_sRGBProfile.argtypes = []
        self.lib.cmsCreate_sRGBProfile.restype = handle
        self.lib.cmsCreateGrayProfile.argtypes = [C.c_void_p, handle]
        self.lib.cmsCreateGrayProfile.restype = handle
        self.lib.cmsCreateLab2Profile.argtypes = [C.c_void_p]
        self.lib.cmsCreateLab2Profile.restype = handle
        self.lib.cmsCreateLab4Profile.argtypes = [C.c_void_p]
        self.lib.cmsCreateLab4Profile.restype = handle
        self.lib.cmsCreateBCHSWabstractProfile.argtypes = [
            C.c_uint32,
            C.c_double,
            C.c_double,
            C.c_double,
            C.c_double,
            C.c_uint32,
            C.c_uint32,
        ]
        self.lib.cmsCreateBCHSWabstractProfile.restype = handle
        self.lib.cmsCreateLinearizationDeviceLink.argtypes = [C.c_uint32, C.POINTER(handle)]
        self.lib.cmsCreateLinearizationDeviceLink.restype = handle
        self.lib.cmsBuildGamma.argtypes = [C.c_void_p, C.c_double]
        self.lib.cmsBuildGamma.restype = handle
        self.lib.cmsFreeToneCurve.argtypes = [handle]
        self.lib.cmsFreeToneCurve.restype = None
        self.lib.cmsSaveProfileToMem.argtypes = [handle, C.c_void_p, C.POINTER(C.c_uint32)]
        self.lib.cmsSaveProfileToMem.restype = C.c_int
        self.lib.cmsSetProfileVersion.argtypes = [handle, C.c_double]
        self.lib.cmsSetProfileVersion.restype = None
        self.lib.cmsReadTag.argtypes = [handle, C.c_uint32]
        self.lib.cmsReadTag.restype = handle
        self.lib.cmsWriteTag.argtypes = [handle, C.c_uint32, handle]
        self.lib.cmsWriteTag.restype = C.c_int
        self.lib.cmsPipelineDup.argtypes = [handle]
        self.lib.cmsPipelineDup.restype = handle
        self.lib.cmsPipelineFree.argtypes = [handle]
        self.lib.cmsPipelineFree.restype = None
        self.lib.cmsCreateTransform.argtypes = [
            handle,
            C.c_uint32,
            handle,
            C.c_uint32,
            C.c_uint32,
            C.c_uint32,
        ]
        self.lib.cmsCreateTransform.restype = handle
        self.lib.cmsDoTransform.argtypes = [handle, C.c_void_p, C.c_void_p, C.c_uint32]
        self.lib.cmsDoTransform.restype = None
        self.lib.cmsDeleteTransform.argtypes = [handle]
        self.lib.cmsDeleteTransform.restype = None
        self.lib.cmsCloseProfile.argtypes = [handle]
        self.lib.cmsCloseProfile.restype = C.c_int

    def _save_profile(self, profile: C.c_void_p) -> bytes:
        try:
            size = C.c_uint32(0)
            if not self.lib.cmsSaveProfileToMem(profile, None, C.byref(size)) or not size.value:
                raise RuntimeError("cmsSaveProfileToMem size query failed")
            data = C.create_string_buffer(size.value)
            if not self.lib.cmsSaveProfileToMem(profile, data, C.byref(size)):
                raise RuntimeError("cmsSaveProfileToMem failed")
            return data.raw[: size.value]
        finally:
            self.lib.cmsCloseProfile(profile)

    def save_rgb_profile(self, version: int) -> bytes:
        profile = self.lib.cmsCreate_sRGBProfile()
        if not profile:
            raise RuntimeError('cmsCreate_sRGBProfile failed')
        self.lib.cmsSetProfileVersion(profile, 2.1 if version == 2 else 4.4)
        return self._save_profile(profile)

    def save_gray_profile(self, x: float, y: float, gamma: float = 2.2, version: int = 4) -> bytes:
        # D65 white point in the ICC PCS.  The profile is generated once and
        # then retained byte-for-byte in the fixture corpus.
        class XYZY(C.Structure):
            _fields_ = [("x", C.c_double), ("y", C.c_double), ("Y", C.c_double)]

        white = XYZY(x, y, 1.0)
        curve = self.lib.cmsBuildGamma(None, gamma)
        if not curve:
            raise RuntimeError("cmsBuildGamma failed")
        profile = self.lib.cmsCreateGrayProfile(C.byref(white), curve)
        self.lib.cmsFreeToneCurve(curve)
        if not profile:
            raise RuntimeError("cmsCreateGrayProfile failed")
        self.lib.cmsSetProfileVersion(profile, 2.1 if version == 2 else 4.4)
        return self._save_profile(profile)

    def save_lab_profile(self, version: int, x: float, y: float) -> bytes:
        class XYZY(C.Structure):
            _fields_ = [("x", C.c_double), ("y", C.c_double), ("Y", C.c_double)]

        white = XYZY(x, y, 1.0)
        profile = (self.lib.cmsCreateLab2Profile if version == 2 else self.lib.cmsCreateLab4Profile)(
            C.byref(white)
        )
        if not profile:
            raise RuntimeError("cmsCreateLab profile failed")
        return self._save_profile(profile)

    def save_rgb_clut_profile(self, version: int) -> bytes:
        # LittleCMS's BCHSW abstract profile supplies a real, non-identity
        # mAB CLUT. Normalize the profile header to an RGB monitor profile so
        # the library's RGB A2B0 path can parse it without treating a printer
        # or abstract profile as a display profile.
        profile = self.lib.cmsCreateBCHSWabstractProfile(
            17, 1.2, 1.1, 0.0, 1.2, 6504, 5000
        )
        if not profile:
            raise RuntimeError("cmsCreateBCHSWabstractProfile failed")
        raw = bytearray(self._save_profile(profile))
        raw[8:12] = bytes.fromhex("02100000" if version == 2 else "04400000")
        raw[12:16] = b"mntr"
        raw[16:20] = b"RGB "
        return bytes(raw)

    def save_cmyk_profile(self, version: int) -> bytes:
        # A small synthetic CMYK device-link is retained only to prove that
        # the RGB/Gray API rejects unsupported device spaces. It contains no
        # installed printer profile or external attribution.
        curves = (C.c_void_p * 4)()
        for index, gamma in enumerate((1.8, 2.0, 2.2, 1.0)):
            curves[index] = self.lib.cmsBuildGamma(None, gamma)
        profile = self.lib.cmsCreateLinearizationDeviceLink(0x434D594B, curves)
        for curve in curves:
            self.lib.cmsFreeToneCurve(curve)
        if not profile:
            raise RuntimeError("cmsCreateLinearizationDeviceLink(CMYK) failed")
        raw = bytearray(self._save_profile(profile))
        raw[8:12] = bytes.fromhex("02100000" if version == 2 else "04400000")
        raw[12:16] = b"mntr"
        return bytes(raw)

    def convert_to_mab(self, raw: bytes) -> bytes:
        memory = C.create_string_buffer(raw)
        profile = self.lib.cmsOpenProfileFromMem(memory, len(raw))
        if not profile:
            raise RuntimeError('Unable to open LUT profile')
        pipeline = self.lib.cmsPipelineDup(self.lib.cmsReadTag(profile, 0x41324230))
        if not pipeline:
            self.lib.cmsCloseProfile(profile)
            raise RuntimeError('Unable to duplicate A2B0 pipeline')
        self.lib.cmsSetProfileVersion(profile, 4.4)
        ok = self.lib.cmsWriteTag(profile, 0x41324230, pipeline)
        self.lib.cmsPipelineFree(pipeline)
        if not ok:
            self.lib.cmsCloseProfile(profile)
            raise RuntimeError('Unable to serialize mAB pipeline')
        return self._save_profile(profile)

    def transform(
        self,
        profile: bytes,
        source_format: int,
        samples: list[int],
        intent: int = 1,
    ) -> list[int]:
        if source_format == TYPE_RGBA16:
            channels = 4
            destination = TYPE_RGBA16
        elif source_format == TYPE_GRAYA16:
            channels = 2
            destination = TYPE_RGBA16
        elif source_format == TYPE_CMYKA16:
            channels = 5
            destination = TYPE_RGBA16
        elif source_format in (TYPE_LAB16, TYPE_LABV2_16):
            channels = 3
            destination = TYPE_RGB16
        else:
            raise ValueError(f"unsupported source format {source_format:#x}")
        if len(samples) % channels:
            raise ValueError("sample count is not a whole source pixel")
        raw = struct.pack(f"<{len(samples)}H", *samples)
        src_buffer = C.create_string_buffer(raw)
        profile_buffer = C.create_string_buffer(profile)
        source = self.lib.cmsOpenProfileFromMem(profile_buffer, len(profile))
        target = self.lib.cmsCreate_sRGBProfile()
        if not source or not target:
            if source:
                self.lib.cmsCloseProfile(source)
            if target:
                self.lib.cmsCloseProfile(target)
            raise RuntimeError("LittleCMS profile allocation failed")
        transform = self.lib.cmsCreateTransform(
            source,
            source_format,
            target,
            destination,
            intent,
            LCMS_COPY_ALPHA,
        )
        if not transform:
            self.lib.cmsCloseProfile(source)
            self.lib.cmsCloseProfile(target)
            raise RuntimeError("LittleCMS transform creation failed")
        try:
            count = len(samples) // channels
            output_channels = 3 if source_format in (TYPE_LAB16, TYPE_LABV2_16) else 4
            output = (C.c_uint16 * (count * output_channels))()
            self.lib.cmsDoTransform(transform, src_buffer, output, count)
            values = list(output)
            if source_format in (TYPE_LAB16, TYPE_LABV2_16):
                with_alpha = []
                for index in range(0, len(values), 3):
                    with_alpha.extend(values[index : index + 3])
                    with_alpha.append(65535)
                values = with_alpha
            return values
        finally:
            self.lib.cmsDeleteTransform(transform)
            self.lib.cmsCloseProfile(source)
            self.lib.cmsCloseProfile(target)


def profile_version(profile: bytes) -> str:
    if len(profile) < 12:
        return "invalid"
    major = profile[8]
    minor = profile[9] >> 4
    bugfix = profile[9] & 0x0F
    return f"{major}.{minor}.{bugfix}"


def source_profiles(lcms: LittleCMS) -> dict[str, bytes]:
    matrix_v2 = lcms.save_rgb_profile(2)
    matrix_v4 = lcms.save_rgb_profile(4)
    gray_d65 = lcms.save_gray_profile(0.3127, 0.3290)
    gray_d50 = lcms.save_gray_profile(0.3457, 0.3585)
    # The generated gray profile is a valid matrix/TRC profile.  Retain a v2
    # copy so both ICC header generations exercise the parser while the D65 vs
    # D50 media white remains independently observable.
    gray_d65_v2 = lcms.save_gray_profile(0.3127, 0.3290, version=2)
    gray_d50_v2 = lcms.save_gray_profile(0.3457, 0.3585, version=2)
    return {
        "matrix_rgb_v2": matrix_v2,
        "matrix_rgb_v4": matrix_v4,
        "gray_d65_trc_v2": gray_d65_v2,
        "gray_d50_trc_v2": gray_d50_v2,
        "gray_d65_trc_v4": gray_d65,
        "gray_d50_trc_v4": gray_d50,
        "lab_v2": lcms.save_lab_profile(2, 0.3457, 0.3585),
        "lab_v4": lcms.save_lab_profile(4, 0.3457, 0.3585),
        "lut_cmyk_v2": lcms.save_cmyk_profile(2),
        "lut_cmyk_v4": lcms.save_cmyk_profile(4),
        "lut_rgb_v2": lcms.save_rgb_clut_profile(2),
        "lut_rgb_v4": lcms.save_rgb_clut_profile(4),
        "mab_rgb_v4": lcms.convert_to_mab(lcms.save_rgb_clut_profile(4)),
        "mft1_rgb_v4": make_lut8_profile(),
    }


def make_lut8_profile() -> bytes:
    # Small project-owned Lab lattice. R varies slowest in the ICC CLUT.
    table = bytearray(48)
    table[:4] = b'mft1'
    table[8:11] = bytes((3,3,2))
    for i in range(9):
        struct.pack_into('>i',table,12+4*i,65536 if i%4==0 else 0)
    table.extend(bytes(range(256))*3)
    for r in (0,1):
        for g in (0,1):
            for b in (0,1):
                table.extend((64+64*r,112+32*g,112+32*b))
    table.extend(bytes(range(256))*3)
    profile = bytearray(144)
    struct.pack_into('>I',profile,0,len(profile)+len(table))
    profile[8:12] = bytes.fromhex('04400000')
    profile[12:24] = b'mntrRGB Lab '
    profile[36:40] = b'acsp'
    for i,value in enumerate((0.9642,1.0,0.8249)):
        struct.pack_into('>i',profile,68+4*i,round(value*65536))
    struct.pack_into('>I4sII',profile,128,1,b'A2B0',144,len(table))
    return bytes(profile+table)


def pq_eotf(code: int, maximum: int = 4095) -> Decimal:
    """ST 2084 absolute luminance, BT.2100 Table 4; 100-digit arithmetic."""
    with localcontext() as ctx:
        ctx.prec = 100
        x = Decimal(code) / maximum
        m1 = Decimal(2610) / 16384
        m2 = Decimal(2523) / 32
        c1 = Decimal(3424) / 4096
        c2 = Decimal(2413) / 128
        c3 = Decimal(2392) / 128
        power = x ** (Decimal(1) / m2)
        numerator = max(Decimal(0), power - c1)
        denominator = c2 - c3 * power
        if denominator <= 0:
            raise ValueError("PQ code is outside the finite EOTF domain")
        return (numerator / denominator) ** (Decimal(1) / m1) * 10000


def hlg_scene(code: int, maximum: int = 4095) -> Decimal:
    """BT.2100 Table 5 inverse OETF, normalized scene light (not nits)."""
    with localcontext() as ctx:
        ctx.prec = 100
        e = Decimal(code) / maximum
        if e <= Decimal(1) / Decimal(2):
            return e * e / 3
        a = Decimal("0.17883277")
        b = Decimal("0.28466892")
        c = Decimal("0.55991073")
        return (((e - c) / a).exp() + b) / 12


def hdr_vectors() -> dict[str, object]:
    cases = []
    # BT.2020 to BT.709 linear-light matrix derived from the H.273
    # chromaticities with exact rational matrix algebra (same D65 white).
    # Derive the matrix rather than relying on rounded printed coefficients.
    def inverse(a):
        det = sum(a[0][i] * (a[1][(i+1)%3]*a[2][(i+2)%3] - a[1][(i+2)%3]*a[2][(i+1)%3]) for i in range(3))
        return [[(a[(j+1)%3][(i+1)%3]*a[(j+2)%3][(i+2)%3] - a[(j+1)%3][(i+2)%3]*a[(j+2)%3][(i+1)%3]) / det for j in range(3)] for i in range(3)]
    def rgb_xyz(coords):
        columns = [(Fraction(x)/Fraction(y), Fraction(1), (1-Fraction(x)-Fraction(y))/Fraction(y)) for x,y in coords]
        matrix = [[columns[j][i] for j in range(3)] for i in range(3)]
        white = [Fraction(3127,3290), Fraction(1), Fraction(3583,3290)]
        inv = inverse(matrix)
        scales = [sum(inv[i][j]*white[j] for j in range(3)) for i in range(3)]
        return [[matrix[i][j]*scales[j] for j in range(3)] for i in range(3)]
    bt709 = rgb_xyz([('0.640','0.330'),('0.300','0.600'),('0.150','0.060')])
    bt2020 = rgb_xyz([('0.708','0.292'),('0.170','0.797'),('0.131','0.046')])
    inverse709 = inverse(bt709)
    gamut = [[sum(inverse709[i][k]*bt2020[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
    with localcontext() as ctx:
        ctx.prec = 100
        weights = [Decimal('0.2126'), Decimal('0.7152'), Decimal('0.0722')]
        source_weights = [Decimal('0.2627'), Decimal('0.6780'), Decimal('0.0593')]
        for depth in (10, 12):
            maximum = (1 << depth) - 1
            grays = [0, 1, maximum//16, maximum//4, maximum//2, maximum//2+1, 3*maximum//4, maximum-1, maximum]
            pixels = [(g,g,g) for g in grays] + [(3*maximum//4,maximum//2,maximum//4), (maximum//4,3*maximum//4,maximum//2)]
            for transfer in (16,18):
                for rgb in pixels:
                    linear = [pq_eotf(code,maximum) if transfer==16 else hlg_scene(code,maximum) for code in rgb]
                    if transfer==18:
                        scene_y = sum(c*w for c,w in zip(linear,source_weights))
                        gain = Decimal(0) if scene_y==0 else Decimal(1000)*scene_y**Decimal('0.2')
                        linear = [c*gain for c in linear]
                    target = [sum(Decimal(gamut[i][j].numerator)/Decimal(gamut[i][j].denominator)*linear[j] for j in range(3)) for i in range(3)]
                    y = sum(c*w for c,w in zip(target,weights))
                    x = y/100
                    mapped = min(Decimal(1),max(Decimal(0),x*(1+x/100)/(1+x)))
                    target = [Decimal(0) if y<=0 else min(Decimal(1),max(Decimal(0),c*mapped/y)) for c in target]
                    encoded = [Decimal('12.92')*c if c<=Decimal('0.0031308') else Decimal('1.055')*c**(Decimal(1)/Decimal('2.4'))-Decimal('0.055') for c in target]
                    cases.append({'depth':depth,'transfer':transfer,'rgb':list(rgb),'rgba16':[int(c*65535+Decimal('0.5')) for c in encoded]+[65535]})
    return {'precision_digits':100,'peak_nits':1000,'reference_white_nits':100,'exposure_stops':0,'pq_absolute_peak_nits':10000,'cases':cases}


def resample_vectors() -> dict[str, object]:
    # Premultiplied linear interpolation is evaluated in exact rationals.  The
    # vectors cover transparent edges, fractional origins, and a two-pixel
    # opaque/transparent transition; alpha is divided only after interpolation.
    cases = []
    source = [(65535, 0, 0, 65535), (0, 65535, 0, 32768), (0, 0, 65535, 0)]
    for origin in [Fraction(-1, 2), Fraction(0), Fraction(1, 2), Fraction(3, 4)]:
        for position in [Fraction(0), Fraction(1, 2), Fraction(1), Fraction(3, 2)]:
            coordinate = max(Fraction(0), min(Fraction(len(source) - 1), origin + position))
            left = max(0, min(len(source) - 1, int(coordinate.numerator // coordinate.denominator)))
            frac = coordinate - left
            right = min(len(source) - 1, left + 1)
            prem = []
            for c in range(3):
                lv = Fraction(source[left][c] * source[left][3], 65535)
                rv = Fraction(source[right][c] * source[right][3], 65535)
                prem.append((1 - frac) * lv + frac * rv)
            alpha = (1 - frac) * source[left][3] + frac * source[right][3]
            rgb = [Fraction(0) if alpha == 0 else min(Fraction(65535), x * 65535 / alpha) for x in prem]
            cases.append({
                "origin_num": origin.numerator,
                "origin_den": origin.denominator,
                "position_num": position.numerator,
                "position_den": position.denominator,
                "rgba16": [int(x + Fraction(1, 2)) for x in rgb] + [int(alpha + Fraction(1, 2))],
            })
    grid = [
        [(65535, 0, 0, 65535), (0, 65535, 0, 32768)],
        [(0, 0, 65535, 16384), (65535, 65535, 65535, 0)],
    ]
    grid_cases = []
    for x in (Fraction(1, 2), Fraction(1, 3), Fraction(3, 4)):
        for y in (Fraction(1, 2), Fraction(2, 3), Fraction(1, 4)):
            weights = [(1 - x) * (1 - y), x * (1 - y), (1 - x) * y, x * y]
            pixels = [grid[0][0], grid[0][1], grid[1][0], grid[1][1]]
            alpha = sum(weight * pixel[3] for weight, pixel in zip(weights, pixels))
            prem = [
                sum(
                    weight * Fraction(pixel[c] * pixel[3], 65535)
                    for weight, pixel in zip(weights, pixels)
                )
                for c in range(3)
            ]
            rgb = [
                Fraction(0) if alpha == 0 else min(Fraction(65535), value * 65535 / alpha)
                for value in prem
            ]
            grid_cases.append({
                "x_num": x.numerator,
                "x_den": x.denominator,
                "y_num": y.numerator,
                "y_den": y.denominator,
                "rgba16": [int(value + Fraction(1, 2)) for value in rgb]
                + [int(alpha + Fraction(1, 2))],
            })
    return {
        "source_rgba16": source,
        "cases": cases,
        "grid_source_rgba16": grid,
        "grid_cases": grid_cases,
    }


def moon_byte_array(data: bytes, indent: str = "  ") -> str:
    rows = []
    for index in range(0, len(data), 16):
        rows.append(indent + ", ".join(f"0x{byte:02x}" for byte in data[index : index + 16]) + ",")
    return "[\n" + "\n".join(rows) + "\n]"


def reference_test(manifest: dict[str, object], profile_bytes: dict[str, bytes]) -> str:
    hdr = manifest["hdr"]
    resample = manifest["resample"]
    rows = [
        "/// Generated by scripts/generate-color-display-reference.py.",
        "/// ICC outputs come from LittleCMS; HDR and geometry use Decimal/Fraction.",
        "",
        "///|",
        "fn icc_reference_check(profile_bytes : Array[Byte], source : Array[Int], expected : Array[Int], tolerance : Int) -> Unit raise {",
        "  let profile = IccProfile::parse(profile_bytes).unwrap()",
        "  let image : Image16 = { width: source.length() / 4, height: 1, data: FixedArray::makei(source.length(), i => source[i].to_uint16()), }",
        "  let actual = profile.apply_rgba16(image).unwrap()",
        "  assert_eq(actual.data.length(), expected.length())",
        "  for i in 0..<expected.length() {",
        "    let difference = actual.data[i].to_int() - expected[i]",
        "    if i % 4 == 3 { assert_eq(difference, 0) } else { assert_true(difference >= -tolerance && difference <= tolerance, msg=\"ICC channel differs at \\{i}: \\{actual.data[i]} versus \\{expected[i]}\") }",
        "  }",
        "}",
        "",
    ]
    for index, row in enumerate(hdr['cases']):
        r,g,b = row['rgb']
        rows.extend([
            '///|',
            f'test "Decimal HDR native output {index}" {{',
            '  let frame : Av1NativeFrame = {',
            f"    width: 1, height: 1, bit_depth: {row['depth']}, subsampling_x: false, subsampling_y: false, full_range: true, matrix_coefficients: 0, color_primaries: 9, transfer_characteristics: {row['transfer']},",
            f'    planes: [{{width:1,height:1,data:[{g}]}}, {{width:1,height:1,data:[{b}]}}, {{width:1,height:1,data:[{r}]}}],',
            '  }',
            '  let output = frame.to_sdr_rgba16().unwrap()',
            f"  let expected = {json.dumps(row['rgba16'])}",
            '  for channel in 0..<4 {',
            '    let difference = output.data[channel].to_int() - expected[channel]',
            '    if channel == 3 { assert_eq(difference, 0) } else { assert_true(difference >= -1 && difference <= 1, msg="HDR channel \\{channel}: \\{output.data[channel]} versus \\{expected[channel]}") }',
            '  }', '}', '',
        ])
    def resample_case(name, width, height, source, x, y, expected):
        dx = x - Fraction(width-1,2)
        dy = y - Fraction(height-1,2)
        return [
            '///|', f'test "Fraction public resampling {name}" {{',
            f'  let source : Image16 = {{ width: {width}, height: {height}, data: {json.dumps(source)}, }}',
            '  let metadata : AvifMetadata = { primary_item_id: None, track_id: None, icc: None, exif: None, exif_tiff_offset: None, xmp: None, pixel_aspect_ratio: None,',
            f'    transforms: [Crop({{ width_n: 1L, width_d: 1L, height_n: 1L, height_d: 1L, horizontal_n: {dx.numerator}L, horizontal_d: {dx.denominator}L, vertical_n: {dy.numerator}L, vertical_d: {dy.denominator}L, }})],',
            '  }', '  let output = metadata.resample_rgba16(source, 1, 1).unwrap()',
            f'  let expected : FixedArray[UInt16] = {json.dumps(expected)}',
            '  assert_eq(output.data, expected)', '}', '',
        ]
    for index, row in enumerate(resample['cases']):
        x = max(Fraction(0),min(Fraction(2),Fraction(row['origin_num'],row['origin_den'])+Fraction(row['position_num'],row['position_den'])))
        # Exact integer maps intentionally preserve transparent RGB. Select
        # fractional cases to exercise interpolation's transparent-black rule.
        if x.denominator == 1:
            continue
        rows.extend(resample_case(f'line {index}',3,1,[v for p in resample['source_rgba16'] for v in p],x,Fraction(0),row['rgba16']))
    for index, row in enumerate(resample['grid_cases']):
        rows.extend(resample_case(f'grid {index}',2,2,[v for line in resample['grid_source_rgba16'] for p in line for v in p],Fraction(row['x_num'],row['x_den']),Fraction(row['y_num'],row['y_den']),row['rgba16']))
    for row in manifest["profiles"]:
        name = row["name"]
        if row['library_expected'] == 'Unsupported':
            rows.extend(['///|', f'test "ICC explicitly rejects {name}" {{',
                         f'  let bytes : Array[Byte] = {moon_byte_array(profile_bytes[name])}',
                         '  match IccProfile::parse(bytes) { Err(error) => assert_eq(error.kind, Unsupported); Ok(_) => fail("Unsupported ICC form was accepted") }', '}', ''])
            continue
        source = []
        if row["input_kind"] == "gray":
            values = row["input_samples"]
            for index in range(0, len(values), 2):
                source.extend([values[index], values[index], values[index], values[index + 1]])
        elif row["input_kind"] == "lab_v2" or row["input_kind"] == "lab_v4":
            values = row["input_samples"]
            for index in range(0, len(values), 3):
                source.extend(values[index : index + 3] + [65535])
        else:
            source = row["input_samples"]
        tolerance = 8
        rows.extend([
            "///|",
            f"test \"LittleCMS independent ICC {name}\" {{",
            f"  let profile : Array[Byte] = {moon_byte_array(profile_bytes[name])}",
            f"  let source = {json.dumps(source)}",
            f"  let expected = {json.dumps(row['output_rgba16'])}",
            f"  icc_reference_check(profile, source, expected, {tolerance})",
            "}",
            "",
        ])
    return subprocess.run(
        ["moonfmt", "-"], input="\n".join(rows), text=True,
        encoding="utf8", capture_output=True, check=True,
    ).stdout


def build_manifest(lcms: LittleCMS, profiles: dict[str, bytes], args: argparse.Namespace) -> dict[str, object]:
    profile_meta = []
    inputs: dict[str, list[int]] = {
        "matrix_rgb": [0, 65535, 32768, 65535, 65535, 32768, 0, 49152, 4096, 16384, 65535, 32768],
        "gray": [0, 65535, 32768, 49152, 65535, 12345],
        "lab_v2": [0, 32768, 32768, 32768, 40000, 24000, 65535, 65535, 0],
        "lab_v4": [0, 32768, 32768, 32768, 40000, 24000, 65535, 65535, 0],
        "lut_rgb": [0, 65535, 32768, 65535, 65535, 32768, 0, 49152, 4096, 16384, 65535, 32768],
        "lut_cmyk": [0, 0, 0, 0, 65535, 65535, 0, 0, 0, 32768, 65535, 32768, 65535, 32768, 65535],
    }
    formats = {
        "matrix_rgb": TYPE_RGBA16,
        "gray": TYPE_GRAYA16,
        "lab_v2": TYPE_LABV2_16,
        "lab_v4": TYPE_LAB16,
        "lut_cmyk": TYPE_CMYKA16,
        "lut_rgb": TYPE_RGBA16,
    }
    profile_case = {
        "matrix_rgb_v2": "matrix_rgb",
        "matrix_rgb_v4": "matrix_rgb",
        "gray_d65_trc_v2": "gray",
        "gray_d50_trc_v2": "gray",
        "gray_d65_trc_v4": "gray",
        "gray_d50_trc_v4": "gray",
        "lab_v2": "lab_v2",
        "lab_v4": "lab_v4",
        "lut_cmyk_v2": "lut_cmyk",
        "lut_cmyk_v4": "lut_cmyk",
        "lut_rgb_v2": "lut_rgb",
        "lut_rgb_v4": "lut_rgb",
        "mab_rgb_v4": "lut_rgb",
        "mft1_rgb_v4": "lut_rgb",
    }
    profile_intent = {name: 1 for name in profiles}
    for name, profile in profiles.items():
        filename = f"{name}.icc"
        unsupported_cmyk = name.startswith("lut_cmyk_")
        output = [] if unsupported_cmyk else lcms.transform(
            profile,
            formats[profile_case[name]],
            inputs[profile_case[name]],
            profile_intent[name],
        )
        profile_meta.append({
            "name": name,
            "file": filename,
            "sha256": sha256(profile),
            "bytes": len(profile),
            "icc_version": profile_version(profile),
            "source": {
                "matrix_rgb_v2": "LittleCMS cmsCreate_sRGBProfile serialized as ICC v2.1",
                "matrix_rgb_v4": "LittleCMS cmsCreate_sRGBProfile serialized as ICC v4.4",
                "gray_d65_trc_v2": "LittleCMS cmsCreateGrayProfile(D65, gamma=2.2), ICC v2 header",
                "gray_d50_trc_v2": "LittleCMS cmsCreateGrayProfile(D50, gamma=2.2), ICC v2 header",
                "gray_d65_trc_v4": "LittleCMS cmsCreateGrayProfile(D65, gamma=2.2), ICC v4 header",
                "gray_d50_trc_v4": "LittleCMS cmsCreateGrayProfile(D50, gamma=2.2), ICC v4 header",
                "lab_v2": "LittleCMS cmsCreateLab2Profile(D50), TYPE_LabV2_16",
                "lab_v4": "LittleCMS cmsCreateLab4Profile(D50), TYPE_Lab_16",
        "lut_cmyk_v2": "LittleCMS synthetic CMYK linearization profile, ICC v2 header; unsupported color-space boundary",
        "lut_cmyk_v4": "LittleCMS synthetic CMYK linearization profile, ICC v4 header; unsupported color-space boundary",
                "lut_rgb_v2": "LittleCMS cmsCreateBCHSWabstractProfile CLUT, normalized to RGB monitor, ICC v2 header",
                "lut_rgb_v4": "LittleCMS cmsCreateBCHSWabstractProfile CLUT, normalized to RGB monitor, ICC v4 header",
                "mab_rgb_v4": "LittleCMS A2B0 pipeline serialized as ICC v4 mAB using cmsWriteTag",
                "mft1_rgb_v4": "Project-owned ICC lut8Type Lab lattice evaluated by LittleCMS",
            }[name],
            "input_kind": profile_case[name],
            "rendering_intent_code": profile_intent[name],
            "input_samples": inputs[profile_case[name]],
            "output_rgba16": output,
            "perceptual_rgba16": [] if unsupported_cmyk else lcms.transform(profile, formats[profile_case[name]], inputs[profile_case[name]], 0),
            "output_sha256": sha256(struct.pack(f"<{len(output)}H", *output)),
            "library_expected": "Unsupported" if unsupported_cmyk or name in ("lab_v2", "lab_v4") else "Accepted",
        })
    return {
        "oracle": {
            "icc": "LittleCMS 2.x cmsCreateTransform/cmsDoTransform, copy-alpha flag, native UInt16",
            "littlecms": "2.19 on Windows reference host",
            "target": "LittleCMS-created sRGB profile",
            "rendering_intent": "relative colorimetric (1), no black-point compensation",
            "flags": "cmsFLAGS_COPY_ALPHA",
        },
        "profiles": profile_meta,
        "hdr": hdr_vectors(),
        "resample": resample_vectors(),
        "references": [
            "https://www.color.org/specification/ICC1V43_2010-12.pdf",
            "https://www.itu.int/rec/R-REC-BT.2100",
            "https://www.itu.int/rec/R-REC-BT.1886",
        ],
    }


def load_saved() -> dict[str, object]:
    return json.loads((OUT / "manifest.json").read_text(encoding="utf8"))


def write_generation(manifest: dict[str, object], profiles: dict[str, bytes]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for row in manifest["profiles"]:
        (OUT / row["file"]).write_bytes(profiles[row["name"]])
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf8", newline="\n")
    TEST.write_text(reference_test(manifest, profiles), encoding="utf8", newline="\n")


def check() -> None:
    manifest = load_saved()
    if manifest['hdr'] != hdr_vectors() or manifest['resample'] != json.loads(json.dumps(resample_vectors())):
        raise SystemExit('Independent Decimal/Fraction vectors differ')
    for row in manifest["profiles"]:
        path = OUT / row["file"]
        data = path.read_bytes()
        if sha256(data) != row["sha256"]:
            raise SystemExit(f"{path} hash differs")
        if len(data) != row["bytes"]:
            raise SystemExit(f"{path} length differs")
    lcms = LittleCMS()
    for row in manifest["profiles"]:
        if row["output_rgba16"] == []:
            continue
        profile = (OUT / row["file"]).read_bytes()
        kind = row["input_kind"]
        fmt = {
            "matrix_rgb": TYPE_RGBA16,
            "gray": TYPE_GRAYA16,
            "lab_v2": TYPE_LABV2_16,
            "lab_v4": TYPE_LAB16,
            "lut_cmyk": TYPE_CMYKA16,
            "lut_rgb": TYPE_RGBA16,
        }[kind]
        actual = lcms.transform(profile, fmt, row["input_samples"], row["rendering_intent_code"])
        if actual != row["output_rgba16"]:
            raise SystemExit(f"{row['name']} LittleCMS output differs")
        if lcms.transform(profile, fmt, row['input_samples'], 0) != row['perceptual_rgba16']:
            raise SystemExit(f"{row['name']} retained perceptual comparison differs")
    profile_bytes = {row["name"]: (OUT / row["file"]).read_bytes() for row in manifest["profiles"]}
    expected = reference_test(manifest, profile_bytes)
    if not TEST.is_file() or TEST.read_text(encoding="utf8") != expected:
        raise SystemExit(f"{TEST.name} differs; regenerate from saved references")
    print("color-display: profiles, LittleCMS outputs, HDR vectors, and tests match")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify without writing")
    args = parser.parse_args()
    if args.check:
        check()
        return
    lcms = LittleCMS()
    profiles = source_profiles(lcms)
    manifest = build_manifest(lcms, profiles, args)
    write_generation(manifest, profiles)
    print(f"Wrote {len(profiles)} color-display profiles, manifest, and {TEST.name}")


if __name__ == "__main__":
    main()
