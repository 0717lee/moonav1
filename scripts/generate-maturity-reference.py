#!/usr/bin/env python3
"""File-backed 4K, photographic, sampling/alpha and sustained-video references.

Only the new av1-maturity corpus is written. Saved cases are checked and reused;
encoding a case never silently replaces its manifest. --check is read-only.
"""
import argparse
from array import array
import ctypes as C
import json
import os
from pathlib import Path
import re
import sys
import tempfile

sys.dont_write_bytecode = True
import importlib.util
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'tests/fixtures/av1-maturity'
spec = importlib.util.spec_from_file_location('maturity_large', Path(__file__).with_name('generate-large-reference.py'))
large = importlib.util.module_from_spec(spec)
spec.loader.exec_module(large)
grid = large.load('maturity_grid', 'generate-avif-grid-reference.py')
PHOTO_SHA = 'cb4c3d2da98ee72130ebfd2ea472fc84ede6726002c2a8c9cabd86e4deea9f0f'
PHOTO_URL = 'https://images-assets.nasa.gov/image/as17-148-22727/as17-148-22727~orig.jpg'
SPECS = [
    dict(name='photo_8bit_3840x2160', width=3840, height=2160, depth=8, sampling='420', frames=1, photo=True),
    dict(name='scene_10bit_3840x2160', width=3840, height=2160, depth=10, sampling='420', frames=1),
    dict(name='scene_12bit_2048x1152_422', width=2048, height=1152, depth=12, sampling='422', frames=1),
    dict(name='photo_12bit_1921x1081_444', width=1921, height=1081, depth=12, sampling='444', frames=1, photo=True),
    dict(name='video_10bit_320x180_300', width=320, height=180, depth=10, sampling='420', frames=300),
]
HD_SPECS = [
    dict(name='video_10bit_1920x1080_16', width=1920, height=1080, depth=10,
         sampling='420', frames=16, key_interval=8),
]


def plane_shapes(case):
    w, h = case['width'], case['height']
    if case['sampling'] == '400':
        return [(w, h)]
    sx, sy = case['sampling'] != '444', case['sampling'] == '420'
    return [(w, h), ((w + sx) >> sx, (h + sy) >> sy), ((w + sx) >> sx, (h + sy) >> sy)]


def scene(case, output):
    scale = 1 << (case['depth'] - 8)
    for frame in range(case.get('frame_offset', 0), case.get('frame_offset', 0) + case['frames']):
        for p, (w, h) in enumerate(plane_shapes(case)):
            values = bytearray() if case['depth'] == 8 else array('H')
            for y in range(h):
                for x in range(w):
                    if case['sampling'] == '400':
                        value = (x * 7 + y * 11 + frame * 31) % (1 << case['depth'])
                    else:
                        sx, sy = x + 3 * frame, y + 2 * frame
                        tx, ty = abs((sx + p * 13) % 128 - 64), abs((sy + p * 19) % 96 - 48)
                        value = 32 + tx + ty
                        if (sx // 64 + sy // 48) % 3 == 0:
                            value += (sx * 7 ^ sy * 11) & 31
                        if (x - w // 2 - frame * 5) ** 2 + (y - h // 2) ** 2 < (h // 5) ** 2:
                            value = 200 - tx // 2 + p * 5
                        value = value * scale + (sx * 3 + sy * 5 + p) % scale
                    values.append(value)
            if isinstance(values, array):
                if sys.byteorder != 'little':
                    values.byteswap()
                output.write(values.tobytes())
            else:
                output.write(values)


def native_avif(module, library, path):
    data = path.read_bytes()
    buffer = C.create_string_buffer(data)
    decoder = library.avifDecoderCreate()
    try:
        for status in (library.avifDecoderSetSource(decoder, 1), library.avifDecoderSetIOMemory(decoder, buffer, len(data)),
                       library.avifDecoderParse(decoder), library.avifDecoderNextImage(decoder)):
            module.checked(status, 'maturity AVIF')
        state = module.animation.Decoder.from_address(decoder)
        image = module.color.FullImage.from_address(state.image)
        sx = image.format in (2, 3)
        sy = image.format == 3
        size = 1 if image.depth == 8 else 2
        planes = []
        for p in range(1 if image.format == 4 else 3):
            w, h = image.width, image.height
            if p:
                w, h = (w + sx) >> sx, (h + sy) >> sy
            planes.append(b''.join(C.string_at(image.planes[p] + y * image.strides[p], w * size) for y in range(h)))
        alpha = b''.join(C.string_at(image.alpha + y * image.alpha_stride, image.width * size) for y in range(image.height)) if image.alpha else None
        metadata = dict(width=image.width, height=image.height, depth=image.depth, format=image.format,
                        color_primaries=image.primaries, transfer_characteristics=image.transfer,
                        matrix_coefficients=image.matrix, color_range=image.range)
        return b''.join(planes), alpha, metadata
    finally:
        library.avifDecoderDestroy(decoder)


def encode(case, args, module, library):
    case = dict(case)
    name = case['name']
    print(f'Generating {name}...', flush=True)
    pixel = ('gray' if case['sampling'] == '400' else f"yuv{case['sampling']}p") + (f"{case['depth']}le" if case['depth'] > 8 else '')
    if case.get('photo'):
        # Center crop keeps native photographic detail at 4K; the second case
        # downsamples that same field of view to an odd 4:4:4 surface.
        command = [args.ffmpeg, '-y', '-hide_banner', '-i', 'apollo17-blue-marble.jpg',
                   '-vf', f"crop=3840:2160,scale={case['width']}:{case['height']}:flags=lanczos:out_color_matrix=bt709:out_range=tv",
                   '-frames:v', '1', '-pix_fmt', pixel, '-f', 'rawvideo', f'{name}.input.yuv']
        large.run(command, OUT)
        case['input_command'] = ['ffmpeg'] + command[1:]
    else:
        with (OUT / f'{name}.input.yuv').open('wb') as output:
            scene(case, output)
    command = [args.ffmpeg, '-y', '-hide_banner', '-f', 'rawvideo', '-pixel_format', pixel,
               '-video_size', f"{case['width']}x{case['height']}", '-framerate', '25', '-i', f'{name}.input.yuv',
               '-frames:v', str(case['frames']), '-c:v', 'libaom-av1', '-cpu-used', '6', '-crf', '32', '-b:v', '0',
               '-threads', '1', '-lag-in-frames', '16' if case['frames'] > 1 else '0',
               '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
               '-color_range', 'pc' if case['sampling'] == '400' else 'tv']
    if case['frames'] == 1:
        command += ['-still-picture', '1']
    else:
        command += ['-g', str(case.get('key_interval', 64))]
    command += ['-f', 'obu', f'{name}.obu']
    result = large.run(command, OUT)
    case['encoder_command'] = ['ffmpeg'] + command[1:]
    case['encoder_library_version'] = re.search(r'\[libaom-av1 @ [^\]]+\]\s+(v?\d+\.\d+\.\d+[^\r\n]*)', result.stderr)[1]
    trace, headers = large.mainline.header_trace(args.ffmpeg, OUT / f'{name}.obu', OUT)
    (OUT / f'{name}.trace.txt').write_bytes(trace)
    case['sequence_metadata'] = large.sequence_metadata(trace)
    case['headers'] = dict(coded_frames=sum(not h.get('show_existing_frame') for h in headers),
                           key_frames=sum(h.get('frame_type', 0) == 0 and not h.get('show_existing_frame') for h in headers),
                           hidden_frames=sum(h.get('show_frame') == 0 and not h.get('show_existing_frame') for h in headers),
                           show_existing=sum(h.get('show_existing_frame', 0) for h in headers))
    command = [args.dav1d, '-q', '--threads=1', '--framedelay=1', '-i', f'{name}.obu', '--muxer=yuv', '-o', f'{name}.reference.yuv']
    large.run(command, OUT)
    case['decoder_command'] = ['dav1d'] + command[1:]
    size = sum(w * h for w, h in plane_shapes(case)) * case['frames'] * (1 if case['depth'] == 8 else 2)
    reference = (OUT / f'{name}.reference.yuv').read_bytes()
    if len(reference) != size or len(large.temporal_units((OUT / f'{name}.obu').read_bytes())) != case['frames']:
        raise ValueError('Unexpected independent reference/temporal-unit extent')
    if case['frames'] > 1 and not (case['headers']['key_frames'] > 1 and case['headers']['hidden_frames'] and case['headers']['show_existing']):
        raise ValueError('Long video failed to exercise GOP reset and reordering')
    if case['frames'] == 1:
        command = [args.ffmpeg, '-y', '-hide_banner', '-i', f'{name}.obu', '-c:v', 'copy', '-f', 'avif', f'{name}.avif']
        large.run(command, OUT)
        case['container_command'] = ['ffmpeg'] + command[1:]
        yuv, alpha, metadata = native_avif(module, library, OUT / f'{name}.avif')
        if yuv != reference or alpha is not None:
            raise ValueError('Independent AVIF/AV1 pixels differ')
        for key, value in case['sequence_metadata'].items():
            if metadata[key] != value:
                raise ValueError('Independent AVIF metadata differs')
        case['libavif_metadata'] = metadata
    case['artifacts'] = {p.name: large.sha(p.read_bytes()) for p in sorted(OUT.glob(name + '.*'))}
    return case


def add_grid(args, module, library, manifest):
    name = 'alpha_grid_12bit_1920x1088'
    record = OUT / f'{name}.case.json'
    if record.exists():
        case = json.loads(record.read_text(encoding='utf-8'))
        for cell_name in case['source_cells']:
            manifest['cells'][cell_name] = json.loads((OUT / f'{cell_name}.case.json').read_text(encoding='utf-8'))
        return case
    sources = []
    for mono in (False, True):
        cells = []
        for index in range(4):
            cell_name = f"grid_{'alpha' if mono else 'color'}_{index}"
            spec = dict(name=cell_name, width=960, height=576, depth=12, sampling='400' if mono else '420', frames=1, frame_offset=index * 11)
            cache = OUT / f'{cell_name}.case.json'
            if cache.exists():
                case = json.loads(cache.read_text(encoding='utf-8'))
            else:
                case = encode(spec, args, module, library)
                cache.write_text(json.dumps(case, indent=2) + '\n', encoding='utf-8')
            data = (OUT / f'{cell_name}.avif').read_bytes()
            extract = grid.helpers.box_payloads
            cells.append(dict(depth=12, monochrome=mono, payload=extract(data, b'mdat')[0],
                              av1c=extract(data, b'av1C')[0], colr=extract(data, b'colr')[0]))
            manifest['cells'][cell_name] = case
        sources.append(cells)
    data, graph = grid.assemble_alpha_grids(sources[0], sources[1], 2, 2, 1920, 1088,
                                          color_grid=True, alpha_grid=True, cell_size=(960, 576),
                                          handler_name=b'MoonAV1 independent alpha grid')
    (OUT / f'{name}.avif').write_bytes(data)
    color, alpha, metadata = native_avif(module, library, OUT / f'{name}.avif')
    if alpha is None:
        raise ValueError('Independent alpha missing')
    (OUT / f'{name}.reference.yuv').write_bytes(color)
    (OUT / f'{name}.alpha.yuv').write_bytes(alpha)
    case = dict(name=name, width=1920, height=1088, depth=12, sampling='420', frames=1,
                alpha=True, alpha_full_range=True, premultiplied=False, grid=graph,
                sequence_metadata={key:metadata[key] for key in ('color_primaries','transfer_characteristics','matrix_coefficients','color_range')},
                libavif_metadata=metadata, source_cells=list(manifest['cells']))
    case['artifacts'] = {p.name: large.sha(p.read_bytes()) for p in sorted(OUT.glob(name + '.*'))}
    record.write_text(json.dumps(case, indent=2) + '\n', encoding='utf-8')
    return case


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--redecode', action='store_true')
    parser.add_argument('--group', choices=['main','hd-video'], default='main')
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--dav1d', default='dav1d')
    parser.add_argument('--libavif', help='libavif 0.11.1 library')
    args = parser.parse_args()
    manifest_path = OUT / ('manifest.json' if args.group == 'main' else 'hd-video-manifest.json')
    photo = OUT / 'apollo17-blue-marble.jpg'
    if not photo.exists() or large.sha(photo.read_bytes()) != PHOTO_SHA:
        raise SystemExit(f'Download the pinned NASA photograph from {PHOTO_URL} to {photo}')
    module = library = dll_directory = None
    if args.libavif:
        if hasattr(os, 'add_dll_directory'):
            dll_directory = os.add_dll_directory(str(Path(args.libavif).resolve().parent))
        module = large.load('maturity_libavif', 'generate-avif-premultiplied-alpha-reference.py')
        library, version = module.library(args.libavif)
    if not args.check:
        if library is None:
            parser.error('generation requires --libavif')
        if manifest_path.exists():
            parser.error('saved corpus exists; use --check')
        dav1d = large.run([args.dav1d, '--version'], ROOT)
        manifest = dict(photo=dict(url=PHOTO_URL, sha256=PHOTO_SHA, dimensions=[4579,4579], credit='NASA / Apollo 17 crew',
                                  source_page='https://www.nasa.gov/image-article/blue-marble-view-from-apollo-17/',
                                  usage='https://www.nasa.gov/nasa-brand-center/images-and-media/'),
                        ffmpeg_version=large.run([args.ffmpeg,'-version'],ROOT).stdout.splitlines()[0],
                        dav1d_version=(dav1d.stdout+dav1d.stderr).strip(), libavif_version=version, cases=[], cells={})
        for definition in (SPECS if args.group == 'main' else HD_SPECS):
            record = OUT / f"{definition['name']}.case.json"
            if record.exists():
                case = json.loads(record.read_text(encoding='utf-8'))
            else:
                case = encode(definition,args,module,library)
                record.write_text(json.dumps(case,indent=2)+'\n',encoding='utf-8')
            manifest['cases'].append(case)
        if args.group == 'main':
            manifest['cases'].append(add_grid(args,module,library,manifest))
        manifest_path.write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    else:
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    all_cases = manifest['cases'] + list(manifest['cells'].values())
    for case in all_cases:
        for filename, digest in case['artifacts'].items():
            if large.sha((OUT/filename).read_bytes()) != digest:
                raise ValueError(f'Artifact differs: {filename}')
        if args.redecode:
            reference = (OUT/f"{case['name']}.reference.yuv").read_bytes()
            if not case.get('grid'):
                with tempfile.TemporaryDirectory(prefix='moonav1-maturity-') as temporary:
                    large.run([args.dav1d,'-q','--threads=1','--framedelay=1','-i',str(OUT/f"{case['name']}.obu"),
                               '--muxer=yuv','-o','reference.yuv'],temporary)
                    if (Path(temporary)/'reference.yuv').read_bytes()!=reference:
                        raise ValueError('dav1d reference differs')
            if library and case['frames']==1:
                color,alpha,metadata=native_avif(module,library,OUT/f"{case['name']}.avif")
                if color!=reference or metadata!=case['libavif_metadata']:
                    raise ValueError('libavif reference differs')
                if case.get('alpha') and alpha!=(OUT/f"{case['name']}.alpha.yuv").read_bytes():
                    raise ValueError('libavif alpha differs')
    print(f"Maturity references checked: {len(manifest['cases'])} workloads and {len(manifest['cells'])} independent grid cells")


if __name__=='__main__':
    main()
