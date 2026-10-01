#!/usr/bin/env python3
"""Larger deterministic scenes, untouched AV1 streams and independent pixels.

Generation writes only tests/fixtures/av1-large-images and the large consumer's
embedded data. --check reads saved inputs/references without writing them;
--redecode additionally checks dav1d and, when supplied, libavif again.
"""

import argparse
import ctypes as C
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'tests/fixtures/av1-large-images'
EMBED = ROOT / 'benchmarks/large/fixtures.mbt'
SPECS = [
    dict(name='still_8bit_512x384', width=512, height=384, depth=8, frames=1),
    dict(name='still_12bit_512x384', width=512, height=384, depth=12, frames=1),
    dict(name='video_10bit_640x360', width=640, height=360, depth=10, frames=4),
]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


embed = load('large_embed', 'generate-native-api-tests.py')
mainline = load('large_trace', 'generate-av1-mainline-reference.py')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(command, cwd):
    proc = subprocess.run(command, cwd=cwd, capture_output=True, text=True, encoding='utf-8')
    if proc.returncode:
        raise RuntimeError(f'Command failed: {command}\n{proc.stderr[-4000:]}')
    return proc


def source(case):
    # Integer-only translated gradients, detailed patches and a moving circle.
    # This is original synthetic test imagery, not a photographic corpus.
    values = []
    scale = 1 << (case['depth'] - 8)
    for frame in range(case['frames']):
        for plane in range(3):
            width = case['width'] >> (plane != 0)
            height = case['height'] >> (plane != 0)
            for y in range(height):
                for x in range(width):
                    sx, sy = x + 3 * frame, y + 2 * frame
                    tx = abs((sx + plane * 13) % 128 - 64)
                    ty = abs((sy + plane * 19) % 96 - 48)
                    value = 32 + tx + ty
                    if (sx // 64 + sy // 48) % 3 == 0:
                        value += ((sx * 7 ^ sy * 11) & 31)
                    if (x - width // 2 - frame * 5) ** 2 + (y - height // 2) ** 2 < (height // 5) ** 2:
                        value = 200 - tx // 2 + plane * 5
                    values.append(value * scale + (sx * 3 + sy * 5 + plane) % scale)
    return bytes(values) if case['depth'] == 8 else struct.pack(f'<{len(values)}H', *values)


def temporal_units(data):
    # Low-overhead OBU sizes delimit payloads; TD starts a temporal unit.
    starts, pos = [], 0
    while pos < len(data):
        start, header = pos, data[pos]
        pos += 1
        if header & 4:
            pos += 1
        if not header & 2:
            raise ValueError('OBU without explicit size')
        size, shift = 0, 0
        while True:
            byte = data[pos]
            pos += 1
            size |= (byte & 127) << shift
            shift += 7
            if not byte & 128:
                break
            if shift > 56:
                raise ValueError('Invalid OBU size')
        if header >> 3 & 15 == 2:
            starts.append(start)
        pos += size
        if pos > len(data):
            raise ValueError('Truncated OBU')
    if not starts or starts[0] != 0:
        raise ValueError('Expected temporal delimiter at start')
    ends = starts[1:] + [len(data)]
    return [data[a:b] for a, b in zip(starts, ends)]


def sequence_metadata(trace):
    result = {}
    for field, default in [('color_primaries', 2), ('transfer_characteristics', 2),
                           ('matrix_coefficients', 2), ('color_range', 0)]:
        match = re.search(r'\b' + field + r'\s+\S+\s*=\s*(\d+)', trace.decode())
        result[field] = int(match[1]) if match else default
    return result


def libavif_native(module, lib, path, case):
    data = path.read_bytes()
    buffer = C.create_string_buffer(data)
    decoder = lib.avifDecoderCreate()
    if not decoder:
        raise RuntimeError('libavif decoder allocation failed')
    try:
        for status in (lib.avifDecoderSetSource(decoder, 1),
                       lib.avifDecoderSetIOMemory(decoder, buffer, len(data)),
                       lib.avifDecoderParse(decoder), lib.avifDecoderNextImage(decoder)):
            module.checked(status, 'large AVIF reference')
        state = module.animation.Decoder.from_address(decoder)
        image = module.color.FullImage.from_address(state.image)
        if (image.width, image.height, image.depth, image.format) != (case['width'], case['height'], case['depth'], 3):
            raise ValueError('Unexpected independent AVIF dimensions/depth/format')
        metadata = case['sequence_metadata']
        if (image.primaries, image.transfer, image.matrix, image.range) != tuple(metadata[k] for k in
                ('color_primaries', 'transfer_characteristics', 'matrix_coefficients', 'color_range')):
            raise ValueError('Independent AVIF/AV1 color metadata differs')
        size = 1 if image.depth == 8 else 2
        return b''.join(C.string_at(image.planes[p] + y * image.strides[p],
                                   (image.width >> (p != 0)) * size)
                        for p in range(3) for y in range(image.height >> (p != 0)))
    finally:
        lib.avifDecoderDestroy(decoder)


def embedded(cases):
    helpers = embed.HELPERS[embed.HELPERS.index('///|'):]
    helpers = helpers[:helpers.index('///|\nfn native_test_frame')]
    lines = ['/// Generated by scripts/generate-large-reference.py.\n'
             '/// Saved dav1d native samples; see tests/fixtures/av1-large-images.\n', helpers]
    for index, case in enumerate(cases):
        values = embed.samples(OUT / f"{case['name']}.reference.yuv", case['depth'])
        frame_size = case['width'] * case['height'] * 3 // 2
        for frame in range(case['frames']):
            reference = embed.reference_expr(values[frame * frame_size:(frame + 1) * frame_size])
            lines.append(f'///|\nfn large_reference_{index}_{frame}() -> Array[Int] {{\n{reference}\n}}')
        parts = '\n'.join(f'for sample in large_reference_{index}_{frame}() {{ result.push(sample) }}'
                          for frame in range(case['frames']))
        lines.append(f'///|\nfn large_reference_{index}() -> Array[Int] {{\nlet result = []\n{parts}\nresult\n}}')
    lines.append('///|\nfn large_fixtures() -> Array[LargeFixture] {\n[')
    for index, case in enumerate(cases):
        name = case['name']
        units = temporal_units((OUT / f'{name}.obu').read_bytes())
        unit_text = ',\n'.join('native_test_bytes(' + embed.hex_rows(u) + ')' for u in units)
        avif = 'Some(' + embed.input_expr(OUT / f'{name}.avif') + ')' if case['frames'] == 1 else 'None'
        metadata = case['sequence_metadata']
        lines.append(f'''{{ name: "{name}", width: {case['width']}, height: {case['height']},
            depth: {case['depth']}, frames: {case['frames']}, units: [{unit_text}],
            primaries: {metadata['color_primaries']}, transfer: {metadata['transfer_characteristics']},
            matrix: {metadata['matrix_coefficients']}, full: {str(bool(metadata['color_range'])).lower()},
            avif: {avif}, reference: large_reference_{index}() }},''')
    lines.append(']\n}\n')
    return subprocess.run(['moonfmt', '-'], input='\n'.join(lines), text=True,
                          encoding='utf-8', capture_output=True, check=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--embed-only', action='store_true', help='refresh only the MoonBit embedding from saved artifacts')
    parser.add_argument('--redecode', action='store_true', help='redecode saved bitstreams in a temporary directory')
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--dav1d', default='dav1d')
    parser.add_argument('--libavif', help='libavif 0.11.1 library; required for generation')
    args = parser.parse_args()
    module = lib = dll_directory = None
    if args.libavif:
        if hasattr(os, 'add_dll_directory'):
            dll_directory = os.add_dll_directory(str(Path(args.libavif).resolve().parent))
        module = load('large_libavif', 'generate-avif-premultiplied-alpha-reference.py')
        lib, lib_version = module.library(args.libavif)
    if args.check and args.embed_only:
        parser.error('--check and --embed-only are mutually exclusive')
    if not args.check and not args.embed_only and lib is None:
        parser.error('generation requires --libavif')
    if args.check or args.embed_only:
        manifest = json.loads((OUT / 'manifest.json').read_text(encoding='utf-8'))
        for case in manifest['cases']:
            if sequence_metadata((OUT / f"{case['name']}.trace.txt").read_bytes()) != case['sequence_metadata']:
                raise ValueError('Sequence metadata differs from independent trace')
            if source(case) != (OUT / f"{case['name']}.input.yuv").read_bytes():
                raise ValueError('Input recipe differs from saved scene')
            for name, expected in case['artifacts'].items():
                if sha((OUT / name).read_bytes()) != expected:
                    raise ValueError(f'Artifact differs: {name}')
            if args.redecode:
                with tempfile.TemporaryDirectory(prefix='moonav1-large-check-') as tmp:
                    command = [args.dav1d, '-q', '--threads=1', '--framedelay=1', '-i',
                               str(OUT / f"{case['name']}.obu"), '--muxer=yuv', '-o', 'decoded.yuv']
                    run(command, tmp)
                    if (Path(tmp) / 'decoded.yuv').read_bytes() != (OUT / f"{case['name']}.reference.yuv").read_bytes():
                        raise ValueError('dav1d pixels differ')
                if lib and case['frames'] == 1:
                    actual = libavif_native(module, lib, OUT / f"{case['name']}.avif", case)
                    if actual != (OUT / f"{case['name']}.reference.yuv").read_bytes():
                        raise ValueError('libavif pixels differ')
    else:
        OUT.mkdir(parents=True, exist_ok=True)
        dav1d_version = run([args.dav1d, '--version'], ROOT)
        manifest = {'source': 'Original integer-only synthetic scenes; no external imagery',
                    'pixel_contract': 'Frame-major Y/U/V 4:2:0, tight rows, byte at 8-bit or little-endian uint16 at 10/12-bit; exact samples',
                    'ffmpeg_version': run([args.ffmpeg, '-version'], ROOT).stdout.splitlines()[0],
                    'dav1d_version': (dav1d_version.stdout + dav1d_version.stderr).strip(),
                    'libavif_version': lib_version, 'cases': []}
        for spec in SPECS:
            case = dict(spec)
            name = case['name']
            print(f'Generating {name}...', flush=True)
            (OUT / f'{name}.input.yuv').write_bytes(source(case))
            pixfmt = 'yuv420p' + (f"{case['depth']}le" if case['depth'] > 8 else '')
            command = [args.ffmpeg, '-y', '-hide_banner', '-f', 'rawvideo', '-pixel_format', pixfmt,
                       '-video_size', f"{case['width']}x{case['height']}", '-framerate', '25',
                       '-i', f'{name}.input.yuv', '-frames:v', str(case['frames']),
                       '-c:v', 'libaom-av1', '-cpu-used', '6', '-crf', '32', '-b:v', '0',
                       '-threads', '1', '-lag-in-frames', '0', '-color_primaries', 'bt709',
                       '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv']
            if case['frames'] == 1:
                command += ['-still-picture', '1']
            command += ['-f', 'obu', f'{name}.obu']
            result = run(command, OUT)
            case['encoder_command'] = ['ffmpeg'] + command[1:]
            case['encoder_library_version'] = re.search(r'\[libaom-av1 @ [^\]]+\]\s+(v?\d+\.\d+\.\d+[^\r\n]*)', result.stderr)[1]
            trace, headers = mainline.header_trace(args.ffmpeg, OUT / f'{name}.obu', OUT)
            (OUT / f'{name}.trace.txt').write_bytes(trace)
            case['frame_headers'] = headers
            case['sequence_metadata'] = sequence_metadata(trace)
            command = [args.dav1d, '-q', '--threads=1', '--framedelay=1', '-i', f'{name}.obu',
                       '--muxer=yuv', '-o', f'{name}.reference.yuv']
            run(command, OUT)
            case['decoder_command'] = ['dav1d'] + command[1:]
            data = (OUT / f'{name}.reference.yuv').read_bytes()
            size = case['width'] * case['height'] * 3 // 2 * case['frames'] * (1 if case['depth'] == 8 else 2)
            if len(data) != size or len(temporal_units((OUT / f'{name}.obu').read_bytes())) != case['frames']:
                raise ValueError('Unexpected frame count or native plane size')
            if case['frames'] > 1 and [h.get('frame_type') for h in headers] != [0, 1, 1, 1]:
                raise ValueError('Expected one key frame and three inter frames')
            if case['frames'] == 1:
                command = [args.ffmpeg, '-y', '-hide_banner', '-i', f'{name}.obu',
                           '-c:v', 'copy', '-f', 'avif', f'{name}.avif']
                run(command, OUT)
                case['container_command'] = ['ffmpeg'] + command[1:]
                if libavif_native(module, lib, OUT / f'{name}.avif', case) != data:
                    raise ValueError('Independent libavif/dav1d native planes differ')
            case['artifacts'] = {p.name: sha(p.read_bytes()) for p in sorted(OUT.glob(name + '.*'))}
            manifest['cases'].append(case)
        (OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    content = embedded(manifest['cases'])
    if args.check:
        if EMBED.read_text(encoding='utf-8') != content:
            raise ValueError('Embedded large fixtures are stale')
        print(f"Large fixtures checked: {len(manifest['cases'])} cases, 6 native frames")
    else:
        EMBED.parent.mkdir(parents=True, exist_ok=True)
        EMBED.write_text(content, encoding='utf-8', newline='\n')
        print(f'Generated {EMBED.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
