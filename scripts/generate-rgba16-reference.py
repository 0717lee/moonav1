#!/usr/bin/env python3
"""Independent RGBA16 references from existing decoded native fixtures.

Fraction arithmetic supplies linear transforms and alpha. Decimal (80 digits)
supplies transfer curves. Forward normative matrices are solved independently;
no MoonAV1 output or inverse-matrix constant is used. Optional libavif 0.11.1
redecodes the containers and records its own RGBA16 conversion separately.
--check is read-only, including when --libavif is supplied.
"""

import argparse
import ctypes as C
from decimal import Decimal as D, localcontext
from fractions import Fraction as F
from functools import lru_cache
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests/fixtures'
OUT = FIXTURES / 'rgba16'
TEST = ROOT / 'rgba16_reference_test.mbt'


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


embed = load('rgba16_embed', 'generate-native-api-tests.py')


def decimal(value):
    return D(value.numerator) / D(value.denominator) if isinstance(value, F) else D(value)


def solve(matrix, rhs):
    rows = [list(row) + [rhs[i]] for i, row in enumerate(matrix)]
    for col in range(3):
        pivot = next(i for i in range(col, 3) if rows[i][col] != 0)
        rows[col], rows[pivot] = rows[pivot], rows[col]
        divisor = rows[col][col]
        rows[col] = [v / divisor for v in rows[col]]
        for i in range(3):
            if i != col:
                factor = rows[i][col]
                rows[i] = [a - factor * b for a, b in zip(rows[i], rows[col])]
    return [row[3] for row in rows]


@lru_cache(None)
def primary_matrix(primaries):
    # H.273 Table 2 xy coordinates and D65, not decoder coefficient constants.
    coordinates = {
        1: [('0.64', '0.33'), ('0.30', '0.60'), ('0.15', '0.06')],
        12: [('0.68', '0.32'), ('0.265', '0.69'), ('0.15', '0.06')],
    }[primaries]
    columns = [(F(x), F(y), 1 - F(x) - F(y)) for x, y in coordinates]
    matrix = list(zip(*columns))
    scales = solve(matrix, [F(3127, 3290), F(1), F(3583, 3290)])
    return [[matrix[r][c] * scales[c] for c in range(3)] for r in range(3)]


def transfer(value, code, inverse=False):
    v = max(D(0), decimal(value))
    if code == 8:
        return decimal(value)
    if code == 13:
        if inverse:
            return v / D('12.92') if v < D('12.92') * D('.0030412825601275209') else ((v + D('.0550107189475866')) / D('1.0550107189475866')) ** D('2.4')
        return D('12.92') * v if v < D('.0030412825601275209') else D('1.0550107189475866') * v ** (D(1) / D('2.4')) - D('.0550107189475866')
    if code in (1, 6, 14, 15):
        if inverse:
            return v / D('4.5') if v < D('4.5') * D('.018053968510807') else ((v + D('.099296826809442')) / D('1.099296826809442')) ** (D(1) / D('.45'))
        return D('4.5') * v if v < D('.018053968510807') else D('1.099296826809442') * v ** D('.45') - D('.099296826809442')
    if code == 16:
        m1, m2 = D(2610) / 16384, D(2523) / 32
        c1, c2, c3 = D(3424) / 4096, D(2413) / 128, D(2392) / 128
        if inverse:
            power = v ** (1 / m2)
            if c2 - c3 * power <= 0:
                raise ValueError('PQ inverse is outside its finite domain')
            return (max(D(0), power - c1) / (c2 - c3 * power)) ** (1 / m1)
        power = v ** m1
        return ((c1 + c2 * power) / (1 + c3 * power)) ** m2
    if code == 18:
        a, b, c = D('.17883277'), D('.28466892'), D('.55991073')
        if inverse:
            return v * v / 3 if v <= D('.5') else (((v - c) / a).exp() + b) / 12
        return (3 * v).sqrt() if v <= D(1) / 12 else a * (12 * v - b).ln() + c
    raise ValueError(f'unexpected reference transfer {code}')


def rgb_values(y, u, v, matrix, primaries, tc):
    if matrix == 8:
        return [y - u + v, y + u, y - u - v]
    if matrix == 11:
        return [2 * v + F(991902, 1000000) * y, y, (2 * u + y) / F(986566, 1000000)]
    if matrix == 14:
        ictcp = ((2048, 2048, 0), (3625, -7465, 3840), (9500, -9212, -288)) if tc == 18 else ((2048, 2048, 0), (6610, -13613, 7003), (17933, -17390, -543))
        nonlinear = solve([[F(n, 4096) for n in row] for row in ictcp], [y, u, v])
        lms = [transfer(x, tc, inverse=True) for x in nonlinear]
        linear = solve([[D(n) / 4096 for n in row] for row in ((1688, 2146, 262), (683, 2951, 462), (99, 309, 3688))], lms)
        return [transfer(x, tc) for x in linear]
    if matrix in (12, 13):
        weights = primary_matrix(primaries)[1]
        kr, kb = weights[0], weights[2]
    else:
        kr, kb = {1: (F(2126, 10000), F(722, 10000)), 2: (F(299, 1000), F(114, 1000)),
                  4: (F(30, 100), F(11, 100)), 5: (F(299, 1000), F(114, 1000)),
                  6: (F(299, 1000), F(114, 1000)), 7: (F(212, 1000), F(87, 1000)),
                  9: (F(2627, 10000), F(593, 10000)), 10: (F(2627, 10000), F(593, 10000))}[matrix]
    if matrix in (10, 13):
        y, u, v, kr, kb = map(decimal, (y, u, v, kr, kb))
        r = y + 2 * v * (transfer(1 - kr, tc) if v <= 0 else 1 - transfer(kr, tc))
        b = y + 2 * u * (transfer(1 - kb, tc) if u <= 0 else 1 - transfer(kb, tc))
        g = (transfer(y, tc, True) - kr * transfer(r, tc, True) - kb * transfer(b, tc, True)) / (1 - kr - kb)
        return [r, transfer(g, tc), b]
    # Solve the normative forward YCbCr matrix rather than using inverse
    # constants from MoonAV1 or its conversion implementation.
    kg = 1 - kr - kb
    forward = [[kr, kg, kb], [-kr / (2 * (1 - kb)), -kg / (2 * (1 - kb)), F(1, 2)],
               [F(1, 2), -kg / (2 * (1 - kr)), -kb / (2 * (1 - kr))]]
    return solve(forward, [y, u, v])


def quantize(value):
    value = min(1, max(0, value))
    if isinstance(value, F):
        return (value.numerator * 65535 * 2 + value.denominator) // (2 * value.denominator)
    return int(value * 65535 + D('.5'))


def convert(record, planes, alpha):
    w, h, depth = record['width'], record['height'], record['depth']
    maximum, scale = (1 << depth) - 1, 1 << (depth - 8)
    black, span = (0, maximum) if record['full'] else (16 * scale, 219 * scale)
    chroma_span = maximum if record['full'] else (219 if record['matrix'] == 8 else 224) * scale
    cw = (w + (1 << record['sx']) - 1) >> record['sx']
    ch = (h + (1 << record['sy']) - 1) >> record['sy']
    assert len(planes) == w * h + (0 if record['mono'] else 2 * cw * ch)
    assert alpha is None or len(alpha) == w * h
    out = []
    with localcontext() as ctx:
        ctx.prec = 80
        for i in range(w * h):
            y = F(planes[i] - black, span)
            if record['mono']:
                rgb = [y, y, y]
            else:
                ci = (i // w >> record['sy']) * cw + (i % w >> record['sx'])
                u, v = planes[w * h + ci], planes[w * h + cw * ch + ci]
                rgb = [F(v - black, span), y, F(u - black, span)] if record['matrix'] == 0 else rgb_values(y, F(u - (1 << (depth - 1)), chroma_span), F(v - (1 << (depth - 1)), chroma_span), record['matrix'], record['primaries'], record['transfer'])
            a = maximum if alpha is None else alpha[i]
            if not record.get('alpha_full', True):
                a = min(maximum, max(0, ((a - 16 * scale) * maximum + 219 * scale // 2) // (219 * scale)))
            if record['prem']:
                rgb = [F(0) if a == 0 else min(1, max(0, v)) * (D(maximum) / a if isinstance(v, D) else F(maximum, a)) for v in rgb]
                rgb = [min(1, v) for v in rgb]
            if not record['mono'] and record['primaries'] == 10:
                matrix = [[decimal(v) for v in row] for row in primary_matrix(1)]
                linear = solve(matrix, [transfer(v, record['transfer'], True) for v in rgb])
                rgb = [transfer(v, 13) for v in linear]
            out.extend(quantize(v) for v in rgb)
            out.append(quantize(F(a, maximum)))
    return out


def cases():
    color = json.loads((FIXTURES / 'av1-color/manifest.json').read_text())
    for row in color['cases']:
        p, t, m = row.get('nclx', [row['p'], row['t'], row['m']])
        prefix = 'av1-color/' + row['name']
        yield dict(name=row['name'], source=prefix + '.avif', width=16, height=16,
                   depth=row['depth'], sx=0, sy=0, mono=False, full=row['full'],
                   matrix=m, primaries=p, transfer=t, prem=False,
                   frames=[dict(yuv=prefix + '.yuv', alpha=None)],
                   obu=None if 'nclx' in row else prefix + '.obu')
    prem = json.loads((FIXTURES / 'avif-premultiplied-alpha/manifest.json').read_text())
    for row in prem['cases']:
        prefix = 'avif-premultiplied-alpha/'
        yield dict(name=row['name'], source=prefix + row['file'], width=16, height=16,
                   depth=row['depth'], sx=0, sy=0, mono=row['monochrome'], full=True,
                   matrix=row['matrix'], primaries=1, transfer=13, prem=row['premultiplied'],
                   animated=row['animated'], frames=[dict(yuv=f"{prefix}{row['reference']}_frame{i}.yuv.bin", alpha=f"{prefix}{row['reference']}_frame{i}.alpha.bin") for i in range(3 if row['animated'] else 1)])
    for depth in (8, 10, 12):
        prefix = f'av1-monochrome/mono_64x64_1tile_{depth}bit_q0'
        yield dict(name=f'mono_{depth}bit', source=prefix + '.avif', width=64, height=64,
                   depth=depth, sx=0, sy=0, mono=True, full=True, matrix=2,
                   primaries=2, transfer=2, prem=False,
                   frames=[dict(yuv=prefix + '.reference.yuv', alpha=None)])
    for layout, depth, width in (('422', 10, 98), ('444', 12, 99)):
        name = f'nclx709_{layout}_{depth}bit_2x2_odd_crop'
        yield dict(name=name, source=f'avif-grid-sampling-color/{name}.avif', width=width, height=97,
                   depth=depth, sx=int(layout == '422'), sy=0, mono=False, full=True,
                   matrix=1, primaries=1, transfer=13, prem=False,
                   frames=[dict(yuv=f'avif-grid-sampling-color/{name}.native.bin', alpha=None)])
    name = 'alpha_grid_grid_12bit'
    yield dict(name=name, source=f'avif-grid/{name}.avif', width=96, height=98,
               depth=12, sx=1, sy=1, mono=False, full=False, matrix=2,
               primaries=2, transfer=2, prem=False,
               frames=[dict(yuv=f'avif-grid/{name}.color.yuv', alpha=f'avif-grid/{name}.alpha.yuv')])


def libavif_frames(module, lib, record):
    data = (FIXTURES / record['source']).read_bytes()
    decoder = lib.avifDecoderCreate()
    if not decoder:
        raise RuntimeError('libavif decoder allocation failed')
    buf = C.create_string_buffer(data)
    frames = []
    try:
        for status in (lib.avifDecoderSetSource(decoder, 2 if record.get('animated') else 1),
                       lib.avifDecoderSetIOMemory(decoder, buf, len(data)), lib.avifDecoderParse(decoder)):
            module.checked(status, 'libavif parse')
        state = module.animation.Decoder.from_address(decoder)
        if state.count != len(record['frames']):
            raise RuntimeError('independent frame count differs')
        for ref in record['frames']:
            module.checked(lib.avifDecoderNextImage(decoder), 'libavif decode')
            info = module.color.FullImage.from_address(state.image)
            expected_format = 4 if record['mono'] else (3 if record['sy'] else 2 if record['sx'] else 1)
            if (info.width, info.height, info.depth, info.format) != (record['width'], record['height'], record['depth'], expected_format):
                raise RuntimeError(f"libavif native geometry differs: {record['name']}")
            if bool(info.range) != record['full'] or bool(info.premultiplied) != record['prem']:
                raise RuntimeError(f"libavif range/prem metadata differs: {record['name']}")
            if not record['mono'] and (info.primaries, info.transfer, info.matrix) != (record['primaries'], record['transfer'], record['matrix']):
                raise RuntimeError(f"libavif color metadata differs: {record['name']}")
            sx, sy = record['sx'], record['sy']
            native = []
            for p in range(1 if record['mono'] else 3):
                w = info.width if p == 0 else (info.width + (1 << sx) - 1) >> sx
                h = info.height if p == 0 else (info.height + (1 << sy) - 1) >> sy
                ctype = C.c_ubyte if info.depth == 8 else C.c_uint16
                for y in range(h):
                    native.extend(C.cast(info.planes[p] + y * info.strides[p], C.POINTER(ctype))[:w])
            if native != embed.samples(FIXTURES / ref['yuv'], record['depth']):
                raise RuntimeError(f"libavif native color differs: {record['name']}")
            if ref['alpha']:
                actual = []
                ctype = C.c_ubyte if info.depth == 8 else C.c_uint16
                for y in range(info.height):
                    actual.extend(C.cast(info.alpha + y * info.alpha_stride, C.POINTER(ctype))[:info.width])
                if actual != embed.samples(FIXTURES / ref['alpha'], record['depth']):
                    raise RuntimeError('libavif native alpha differs')
            rgb = module.animation.helpers.ScalarRGB0111()
            lib.avifRGBImageSetDefaults(C.byref(rgb), state.image)
            rgb.depth, rgb.avoidLibYUV, rgb.chromaUpsampling, rgb.alphaPremultiplied = 16, 1, 3, 0
            lib.avifRGBImageAllocatePixels(C.byref(rgb))
            if not rgb.pixels:
                raise RuntimeError('libavif RGBA16 allocation failed')
            try:
                status = lib.avifImageYUVToRGB(state.image, C.byref(rgb))
                rgba = []
                if status == 0:
                    for y in range(rgb.height):
                        rgba.extend(C.cast(rgb.pixels + y * rgb.rowBytes, C.POINTER(C.c_uint16))[:rgb.width * 4])
                frames.append((status, rgba))
            finally:
                lib.avifRGBImageFreePixels(C.byref(rgb))
    finally:
        lib.avifDecoderDestroy(decoder)
    return frames


def pack(values):
    return struct.pack(f'<{len(values)}H', *values)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--libavif', help='libavif 0.11.1 library (required for initial generation)')
    args = parser.parse_args()
    lib = module = None
    dll_directory = None
    if args.libavif:
        if hasattr(os, 'add_dll_directory'):
            dll_directory = os.add_dll_directory(str(Path(args.libavif).resolve().parent))
        module = load('rgba16_libavif', 'generate-avif-premultiplied-alpha-reference.py')
        lib, _ = module.library(args.libavif)
    if not args.check and lib is None:
        parser.error('generation requires --libavif; --check can use the saved independent output')
    previous = json.loads((OUT / 'manifest.json').read_text()) if args.check else None
    outputs = {}
    rows = []
    tests = ['''/// Generated by scripts/generate-rgba16-reference.py.
/// Independent Fraction/80-digit Decimal references; RGB error <= 1 UNORM16
/// unit, alpha exact. Native fixture pixels are unchanged.

///|
fn rgba16_reference_check(image : Image16, expected : Array[Int], width : Int, height : Int) -> Unit raise {
  assert_eq((image.width, image.height), (width, height))
  assert_eq(image.data.length(), expected.length())
  for i in 0..<expected.length() {
    let difference = image.data[i].to_int() - expected[i]
    if i % 4 == 3 { assert_eq(difference, 0) } else {
      assert_true(difference >= -1 && difference <= 1, msg="RGBA16 channel \\{i}: \\{image.data[i]} versus \\{expected[i]}")
    }
  }
}
''']
    for record in cases():
        reference = []
        independent = libavif_frames(module, lib, record) if lib else None
        for index, frame in enumerate(record['frames']):
            yuv = embed.samples(FIXTURES / frame['yuv'], record['depth'])
            alpha = embed.samples(FIXTURES / frame['alpha'], record['depth']) if frame['alpha'] else None
            expected = convert(record, yuv, alpha)
            filename = f"{record['name']}_frame{index}.rgba16le"
            outputs[OUT / filename] = pack(expected)
            reference.append(expected)
            comparison = f"{record['name']}_frame{index}.libavif.rgba16le"
            if independent:
                status, actual = independent[index]
                if status == 0:
                    outputs[OUT / comparison] = pack(actual)
            else:
                saved = next(r for r in previous['cases'] if r['name'] == record['name'])['frames'][index]
                status = saved['libavif_status']
                actual = embed.samples(OUT / comparison, 16) if status == 0 else []
            frame.update(output=filename, output_sha256=hashlib.sha256(pack(expected)).hexdigest(),
                         yuv_sha256=hashlib.sha256((FIXTURES / frame['yuv']).read_bytes()).hexdigest(),
                         alpha_sha256=hashlib.sha256((FIXTURES / frame['alpha']).read_bytes()).hexdigest() if frame['alpha'] else None,
                         libavif_status=status, libavif_rgba16=comparison if status == 0 else None,
                         libavif_rgba16_sha256=hashlib.sha256(pack(actual)).hexdigest() if actual else None,
                         libavif_max_difference=max(abs(a-b) for a,b in zip(expected,actual)) if actual else None)
        record['source_sha256'] = hashlib.sha256((FIXTURES / record['source']).read_bytes()).hexdigest()
        rows.append(record)
        name, w, h = record['name'], record['width'], record['height']
        tests.append(f'\n///|\ntest "RGBA16 independent {name}" {{\n  let input = {embed.input_expr(FIXTURES / record["source"])}\n')
        if record.get('animated'):
            tests.append('  let animation = avif_decode_animation_native(input).unwrap()\n')
            for index, expected in enumerate(reference):
                tests.append(f'  rgba16_reference_check(animation.frames[{index}].image.to_rgba16().unwrap(), {embed.reference_expr(expected)}, {w}, {h})\n')
        else:
            tests.append(f'  let expected = {embed.reference_expr(reference[0])}\n')
            tests.append(f'  rgba16_reference_check(avif_decode_rgba16(input).unwrap(), expected, {w}, {h})\n')
            tests.append(f'  rgba16_reference_check(avif_decode_native(input).unwrap().to_rgba16().unwrap(), expected, {w}, {h})\n')
            if record.get('obu'):
                tests.append(f'  let obu = {embed.input_expr(FIXTURES / record["obu"])}\n')
                tests.append(f'  rgba16_reference_check(av1_decode_rgba16(obu).unwrap(), expected, {w}, {h})\n')
                tests.append(f'  rgba16_reference_check(av1_decode_native(obu).unwrap().to_rgba16().unwrap(), expected, {w}, {h})\n')
        tests.append('}\n')
    manifest = dict(oracle='Fraction forward-matrix solve and 80-digit Decimal H.273 transfer; native-depth alpha before final quantization',
                    output='RGBA UNORM16 little endian, nearest chroma, straight alpha; source color except XYZ to BT709/sRGB',
                    tolerance=dict(rgb=1, alpha=0), libavif=dict(version='0.11.1', depth=16, avoidLibYUV=1, chromaUpsampling=3, alphaPremultiplied=0),
                    references=['https://www.itu.int/rec/T-REC-H.273-202407-I/en', 'https://github.com/sekrit-twc/zimg/blob/master/src/zimg/colorspace/colorspace_param.cpp', 'https://github.com/AOMediaCodec/libavif/blob/v0.11.1/src/reformat.c'], cases=rows)
    outputs[OUT / 'manifest.json'] = (json.dumps(manifest, indent=2) + '\n').encode()
    formatted = subprocess.run(['moonfmt', '-'], input=''.join(tests), text=True, encoding='utf8', capture_output=True, check=True).stdout
    outputs[TEST] = formatted.encode()
    for path, data in outputs.items():
        if args.check:
            if not path.exists() or path.read_bytes() != data:
                raise SystemExit(f'reference differs: {path.relative_to(ROOT)}')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    print(f'RGBA16: {len(rows)} cases; {len(outputs)} artifacts checked' if args.check else f'RGBA16: wrote {len(rows)} cases and {len(outputs)} artifacts')
    if dll_directory:
        dll_directory.close()


if __name__ == '__main__':
    main()
