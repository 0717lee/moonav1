#!/usr/bin/env python3
"""Real-media/encoder interoperability references, kept separate from old fixtures.

Generation uses the saved licensed sources, FFmpeg and dav1d. Each completed
case is immutable and can be resumed without re-encoding. --check is read-only;
--redecode compares a fresh independent decode without replacing its reference.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'tests/fixtures/av1-diverse-video'
SOURCE_LICENSES = {
    'tos': dict(license='CC BY 3.0',license_url='https://creativecommons.org/licenses/by/3.0/',
                primary_source='https://mango.blender.org/about/',
                attribution='(CC) Blender Foundation | mango.blender.org; directed by Ian Hubert, 2012',
                soundtrack=dict(license='CC BY-ND 3.0',attribution='Joram Letwory',
                                record='sources/tears-of-steel-copyright.txt'),
                derivation='Retain the original MOV unchanged, including credits; derived video exports remove audio with -an.'),
    'sparks': dict(license='CC BY 4.0',license_url='https://creativecommons.org/licenses/by/4.0/',
                  primary_source='https://opencontent.netflix.com/',attribution='Netflix Inc.; Sparks (2017)',
                  record='sources/sparks-license.txt',
                  derivation='Contiguous original HDR10 BT.2020/PQ master TIFFs 1200-1207; scaling and PQ-to-HLG conversion are recorded per case.'),
    'browser': dict(license='CC0 1.0',license_url='https://creativecommons.org/publicdomain/zero/1.0/',
                   primary_source='tests/fixtures/avif-real-images/webpage_dashboard_768x512.source.html',
                   derivation='Locally rendered synthetic page content with deterministic DOM changes; no external site recording.'),
}


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bench = load('diverse_bench', 'benchmark.py')
large = load('diverse_large', 'generate-large-reference.py')
containers = load('diverse_containers', 'generate-long-container-reference.py')

SPECS = [
    dict(name='tos_svt8_640x360', source='tos', start=52, width=640, height=360,
         depth=8, encoder='libsvtav1', fps='24', frames=96),
    dict(name='tos_rav1e10_640x360', source='tos', start=165, width=640, height=360,
         depth=10, encoder='librav1e', fps='24', frames=64),
    dict(name='tos_amf8_640x360', source='tos', start=290, width=640, height=360,
         depth=8, encoder='av1_amf', fps='24', frames=96),
    dict(name='tos_rav1e12_444_320x180', source='tos', start=190, width=320, height=180,
         depth=12, sampling='444', encoder='librav1e', fps='24', frames=32),
    dict(name='tos_vfr_svt8_512x288', source='tos', start=65, width=512, height=288,
         depth=8, encoder='libsvtav1', fps='25', frames=120, vfr=True, containers=True),
    dict(name='tos_long_svt8_1280x720', source='tos', start=90, width=1280, height=720,
         depth=8, encoder='libsvtav1', fps='24', frames=4320, long=True),
    dict(name='sparks_pq10_svt_512x270', source='sparks', width=512, height=270,
         depth=10, encoder='libsvtav1', fps='60000/1001', frames=8, hdr='pq'),
    dict(name='sparks_hlg10_rav1e_512x270', source='sparks', width=512, height=270,
         depth=10, encoder='librav1e', fps='60000/1001', frames=8, hdr='hlg'),
    dict(name='sparks_pq12_still_512x270', source='sparks', width=512, height=270,
         depth=12, encoder='libaom-av1', fps='60000/1001', frames=1, hdr='pq'),
    dict(name='sparks_4k60_amf10_4096x2160', source='sparks', width=4096, height=2160,
         depth=10, encoder='av1_amf', fps='60000/1001', frames=8, hdr='pq'),
    dict(name='browser_rav1e8_444_768x512', source='browser', width=768, height=512,
         depth=8, sampling='444', encoder='librav1e', fps='30', frames=96),
]


def run(command, log=None):
    completed = subprocess.run(command, cwd=OUT, capture_output=True, text=True, encoding='utf-8')
    if log:
        (OUT / log).write_text(completed.stdout + completed.stderr, encoding='utf-8')
    if completed.returncode:
        raise RuntimeError(f'Command failed: {command}\n{completed.stderr[-6000:]}')
    return completed


def pixel_format(case):
    return 'yuv' + case.get('sampling', '420') + 'p' + (str(case['depth']) + 'le' if case['depth'] > 8 else '')


def frame_bytes(case):
    w, h = case['width'], case['height']
    sx, sy = case.get('sampling', '420') != '444', case.get('sampling', '420') == '420'
    return (w*h + 2*((w+sx)>>sx)*((h+sy)>>sy)) * (1 if case['depth'] == 8 else 2)


def reference_frames(path, size):
    crcs = []
    with path.open('rb') as stream:
        while data := stream.read(size):
            if len(data) != size:
                raise ValueError('Incomplete native reference frame')
            crcs.append(zlib.crc32(data) & 0xffffffff)
    return crcs


def case_artifact_names(case):
    suffixes = ['.encoder.log','.mp4','.obu','.reference.yuv','.trace.txt']
    if case['frames'] == 1:
        suffixes.append('.avif')
    if case.get('containers'):
        suffixes.append('.webm')
    return sorted(case['name']+suffix for suffix in suffixes)


def source_records():
    rows = json.loads((OUT/'sources/downloads.json').read_text(encoding='utf-8'))
    for row in rows:
        path = OUT/'sources'/row['file']
        if path.stat().st_size != row['bytes'] or bench.sha256(path) != row['sha256']:
            raise ValueError('Original source changed: ' + row['file'])
    return rows


def browser_frames():
    """Retain actual Chromium screenshots of deterministic, owned page content."""
    folder = OUT/'sources/browser-ui'
    record = folder/'capture.json'
    if record.exists():
        capture = json.loads(record.read_text(encoding='utf-8'))
        for filename, digest in capture['artifacts'].items():
            if bench.sha256(folder/filename) != digest:
                raise ValueError('Browser source changed: '+filename)
        return capture
    from importlib.metadata import version
    from playwright.sync_api import sync_playwright
    folder.mkdir(parents=True, exist_ok=True)
    source = ROOT/'tests/fixtures/avif-real-images/webpage_dashboard_768x512.source.html'
    shutil.copyfile(source, folder/'page.html')
    mutation = """n => {
      document.querySelectorAll('.bar').forEach((bar, i) => {
        bar.style.height = (25 + ((n * (i + 1) + i * 13) % 72)) + '%';
      });
      document.querySelector('.metric span').textContent = (24.8 + n / 10).toFixed(1) + 'k';
      document.querySelector('.tag').textContent = 'FRAME ' + String(n).padStart(3, '0');
      document.querySelector('main').style.transform = 'translateY(' + (-Math.floor(n / 3) % 24) + 'px)';
    }"""
    (folder/'mutation.js').write_text(mutation+'\n', encoding='utf-8')
    options = dict(viewport=dict(width=768, height=512), device_scale_factor=1)
    screenshot = dict(type='png', animations='disabled', full_page=False)
    with sync_playwright() as engine:
        browser = engine.chromium.launch(headless=True, args=['--force-color-profile=srgb'])
        page = browser.new_page(**options)
        page.route('**/*', lambda route: route.abort())
        page.set_content((folder/'page.html').read_text(encoding='utf-8'), wait_until='load')
        page.evaluate('document.fonts.ready')
        for index in range(96):
            page.evaluate(mutation, index)
            page.screenshot(path=str(folder/f'{index:03d}.png'), **screenshot)
        chromium_version = browser.version
        browser.close()
    capture = dict(kind='browser-rendered screen recording; synthetic owned page content',
                   source_file=source.relative_to(ROOT).as_posix(), license='CC0 1.0, MoonAV1 test content',
                   frames=96, fps='30', playwright_version=version('playwright'),
                   chromium_version=chromium_version, platform=sys.platform,
                   browser_args=['--force-color-profile=srgb'], page_options=options,
                   screenshot_options=screenshot, mutation_file='mutation.js',
                   artifacts={path.name:bench.sha256(path) for path in sorted(folder.iterdir()) if path.is_file()})
    record.write_text(json.dumps(capture,indent=2)+'\n',encoding='utf-8')
    return capture


def make_case(definition):
    case = dict(definition, sampling=definition.get('sampling', '420'))
    name = case['name']
    common = ['ffmpeg', '-hide_banner', '-y']
    if case['source'] == 'tos':
        source = 'sources/tears_of_steel_720p.mov'
        common += ['-ss', str(case['start']), '-i', source]
        filters = [f"fps={case['fps']}"]
        if case.get('vfr'):
            filters += ["select='lt(mod(n,10),5)+eq(mod(n,10),7)'"]
        filters += [f"scale={case['width']}:{case['height']}:flags=lanczos:force_original_aspect_ratio=decrease:force_divisible_by=2:in_color_matrix=bt709:out_color_matrix=bt709:out_range=tv",
                    f"pad={case['width']}:{case['height']}:(ow-iw)/2:(oh-ih)/2,setsar=1",
                    'setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709']
        color = ['-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709']
        case['source_transform'] = 'Extract real film interval, remove audio, rescale preserving aspect ratio and letterbox to stated geometry. The original has no CICP tags; this test conversion explicitly interprets/signals BT.709. 10/12-bit variants are not native HDR capture.'
    elif case['source'] == 'browser':
        case['browser_capture'] = browser_frames()
        source = 'sources/browser-ui/%03d.png'
        common += ['-framerate', case['fps'], '-i', source]
        filters = ['scale=in_range=full:out_range=tv:out_color_matrix=bt709',
                   'setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709']
        color = ['-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709']
        case['source_transform'] = 'Chromium renders 96 changing dashboard frames from retained local HTML and deterministic DOM mutations. Synthetic page content; actual browser pixels. sRGB screenshots are encoded with the documented BT.709 SDR interpretation.'
    else:
        source = 'sources/SPARKS_HDR10_4K_2020_PQ_1000nits_%05d.tif'
        common += ['-framerate', case['fps'], '-start_number', '1200', '-i', source]
        target_transfer = 'smpte2084' if case['hdr'] == 'pq' else 'arib-std-b67'
        filters = [f"zscale=w={case['width']}:h={case['height']}:pin=bt2020:tin=smpte2084:min=gbr:rin=full:p=bt2020:t={target_transfer}:m=bt2020nc:r=limited:npl=1000",
                   f'setparams=range=limited:color_primaries=bt2020:color_trc={target_transfer}:colorspace=bt2020nc']
        color = ['-color_primaries', 'bt2020', '-color_trc', target_transfer, '-colorspace', 'bt2020nc']
        case['source_transform'] = 'Contiguous 16-bit RGB BT.2020/PQ 1000-nit master TIFFs 1200-1207; scaled and converted to YUV. HLG is an explicitly recorded transform of this HDR master, not a native HLG camera recording.'
    codec = case['encoder']
    options = {
        'libsvtav1': ['-preset', '10', '-crf', '32', '-svtav1-params', 'lp=4'],
        'librav1e': ['-speed', '8', '-qp', '100', '-threads', '4'],
        'av1_amf': ['-quality', 'speed', '-rc', 'cqp', '-qp_i', '30', '-qp_p', '32', '-bitdepth', str(case['depth'])],
        'libaom-av1': ['-cpu-used', '6', '-crf', '30', '-b:v', '0', '-threads', '4', '-lag-in-frames', '0', '-still-picture', '1'],
    }[codec]
    command = common + ['-map', '0:v:0', '-an', '-vf', ','.join(filters), '-frames:v', str(case['frames']),
                        '-pix_fmt', pixel_format(case), '-c:v', codec, *options, '-g', '48',
                        *color, '-color_range', 'tv', '-fps_mode', 'vfr' if case.get('vfr') else 'cfr',
                        '-movflags', '+faststart', name+'.mp4']
    run(command, name+'.encoder.log')
    case['encoder_command'] = command
    # Normalize only transport delimiters for the raw temporal-unit consumer.
    # The original MP4 and its untouched packet payloads are retained too.
    extract = ['ffmpeg', '-hide_banner', '-y', '-i', name+'.mp4', '-map', '0:v:0', '-c:v', 'copy',
               '-bsf:v', 'av1_metadata=td=insert', '-f', 'obu', name+'.obu']
    run(extract)
    case['raw_transport_command'] = extract
    probe_command = ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                     'stream=width,height,pix_fmt,color_primaries,color_transfer,color_space,color_range',
                     '-of', 'json', name+'.obu']
    probe = json.loads(run(probe_command).stdout)['streams'][0]
    case['input_geometry'] = {'width':case['width'], 'height':case['height']}
    case['width'], case['height'] = probe['width'], probe['height']
    case['native_stream_probe'] = probe
    case['native_stream_probe_command'] = probe_command
    decode = ['dav1d', '-q', '--threads=1', '--framedelay=1', '-i', name+'.obu', '--muxer=yuv', '-o', name+'.reference.yuv']
    run(decode)
    case['decoder_command'] = decode
    crcs = reference_frames(OUT/(name+'.reference.yuv'), frame_bytes(case))
    if len(crcs) != case['frames']:
        raise ValueError(f"Presentation count differs: {name}: {len(crcs)}")
    trace, headers = large.mainline.header_trace('ffmpeg', OUT/(name+'.obu'), OUT)
    (OUT/(name+'.trace.txt')).write_bytes(trace)
    case['sequence_metadata'] = large.sequence_metadata(trace)
    expected_color = dict(color_primaries=9 if case.get('hdr') else 1,
                          transfer_characteristics=(16 if case['hdr']=='pq' else 18) if case.get('hdr') else 1,
                          matrix_coefficients=9 if case.get('hdr') else 1, color_range=0)
    if case['sequence_metadata'] != expected_color:
        raise ValueError(f"Encoded CICP differs from intended source conversion: {case['sequence_metadata']}")
    case['evidence'] = dict(presentations=len(crcs), temporal_units=len(large.temporal_units((OUT/(name+'.obu')).read_bytes())),
                            hidden_frames=sum(h.get('show_frame')==0 and not h.get('show_existing_frame') for h in headers),
                            show_existing=sum(h.get('show_existing_frame',0) for h in headers),
                            key_frames=sum(h.get('frame_type',0)==0 and not h.get('show_existing_frame') for h in headers),
                            distinct_reference_crc32=len(set(crcs)))
    case['native_frame_crc32'] = crcs
    case['modes'] = ['av1'] if case.get('long') else ['av1','chunks']
    if case['frames'] == 1:
        remux = ['ffmpeg', '-hide_banner', '-y', '-i', name+'.obu', '-c:v', 'copy', '-f', 'avif', name+'.avif']
        run(remux)
        case['avif_command'] = remux
        case['modes'].append('avif')
    if case.get('containers'):
        webm = ['ffmpeg', '-hide_banner', '-y', '-i', name+'.mp4', '-map', '0:v:0', '-c:v', 'copy',
                '-cluster_time_limit', '1000', name+'.webm']
        run(webm)
        case['webm_command'] = webm
    case['artifacts'] = {filename:bench.sha256(OUT/filename) for filename in case_artifact_names(case)}
    return case


def mp4_declared_geometry(path):
    data = path.read_bytes()
    matches = []

    def walk(start, end):
        for kind, offset, size, header, body in containers._iter_boxes(data, start, end):
            if kind == b'stsd':
                for entry, _, _, _, payload in containers._iter_boxes(data, body+8, offset+size):
                    if entry == b'av01':
                        matches.append(struct.unpack('>HH', data[payload+24:payload+28]))
            elif kind in (b'moov', b'trak', b'mdia', b'minf', b'stbl'):
                walk(body, offset+size)
    walk(0, len(data))
    if len(matches) != 1:
        raise ValueError('Expected one AV1 visual sample entry')
    return matches[0]


def webm_native_durations(path):
    """Read retained WebM DefaultDuration/BlockDuration in exact nanoseconds.

    This independent fixture parser accepts this unlaced, single-track export.
    ffprobe packet duration is rounded to its millisecond stream time base.
    """
    data = path.read_bytes()

    def vint(at, identifier=False):
        lead = data[at]
        length = next((n for n in range(1, 9) if lead & (1 << (8-n))), None)
        if length is None or at+length > len(data):
            raise ValueError('Invalid EBML integer')
        value = int.from_bytes(data[at:at+length], 'big')
        if not identifier:
            value &= (1 << (7*length))-1
            if value == (1 << (7*length))-1:
                value = None
        return value, at+length

    def elements(start, end):
        while start < end:
            kind, at = vint(start, True)
            size, body = vint(at)
            finish = end if size is None else body+size
            if finish > end:
                raise ValueError('Truncated EBML element')
            yield kind, body, finish
            start = finish

    def uint(start, end):
        return int.from_bytes(data[start:end], 'big')

    segments = [(s, e) for kind, s, e in elements(0, len(data)) if kind == 0x18538067]
    if len(segments) != 1:
        raise ValueError('Expected one WebM segment')
    children = list(elements(*segments[0]))
    scale = 1000000
    track_number = None
    default_duration = None
    for kind, start, end in children:
        if kind == 0x1549A966:
            for child, s, e in elements(start, end):
                if child == 0x2AD7B1:
                    scale = uint(s, e)
        elif kind == 0x1654AE6B:
            entries = [(s, e) for child, s, e in elements(start, end) if child == 0xAE]
            if len(entries) != 1:
                raise ValueError('Expected one WebM track')
            for child, s, e in elements(*entries[0]):
                if child == 0xD7:
                    track_number = uint(s, e)
                elif child == 0x23E383:
                    default_duration = uint(s, e)
    durations = []

    def block(start, end, duration):
        track, at = vint(start)
        if track != track_number or at+3 > end or data[at+2] & 6:
            raise ValueError('Unexpected track or lacing in fixture export')
        durations.append(duration)

    for kind, start, end in children:
        if kind != 0x1F43B675:
            continue
        for child, s, e in elements(start, end):
            if child == 0xA3:
                block(s, e, default_duration)
            elif child == 0xA0:
                group = list(elements(s, e))
                duration = next((uint(a, b)*scale for k, a, b in group if k == 0x9B), default_duration)
                blocks = [(a, b) for k, a, b in group if k == 0xA1]
                if len(blocks) != 1:
                    raise ValueError('Expected one WebM block per group')
                block(*blocks[0], duration)
    return durations


def container_manifest(cases, check=False):
    target = OUT/'container-manifest.json'
    if not check and target.exists():
        raise ValueError('Completed container manifest exists; use --check --containers')
    records = []
    for case in cases:
        if case['frames'] == 1:
            continue
        name = case['name']
        artifacts = {}
        variants = [('faststart_mp4', name+'.mp4')]
        if case.get('containers'):
            variants.append(('webm', name+'.webm'))
        for variant, filename in variants:
            path = OUT/filename
            is_mp4 = variant.endswith('mp4')
            original = None
            if is_mp4 and mp4_declared_geometry(path) != (case['width'],case['height']):
                if name != 'tos_amf8_640x360' or mp4_declared_geometry(path) != (640,360) or (case['width'],case['height']) != (640,362):
                    raise ValueError('Unexpected MP4 sample-entry/sequence mismatch: '+filename)
                # Retain this real, nonconformant AMF/FFmpeg export as negative
                # evidence. A separately named FFmpeg stream copy obtains its
                # sample-entry dimensions from the decoded sequence header.
                remux_name = name+'.remux.mp4'
                command = ['ffmpeg','-hide_banner','-loglevel','error','-n','-i',filename,
                           '-map','0:v:0','-c:v','copy','-movflags','+faststart',remux_name]
                original = dict(file=filename,sha256=bench.sha256(path),declared_width=640,declared_height=360,
                                expected_error='InvalidData: av01/av1C dimensions differ',
                                reference='https://aomediacodec.github.io/av1-isobmff/#av1-sample-entry-semantics',
                                remux_command=command)
                original_probe = containers.probe(path,True)
                filename, path = remux_name, OUT/remux_name
                if not path.exists():
                    if check:
                        raise ValueError('Missing retained remux: '+filename)
                    run(command)
                if mp4_declared_geometry(path) != (case['width'],case['height']):
                    raise ValueError('FFmpeg remux sample entry still differs from sequence')
            probe = containers.probe(path, is_mp4)
            selected = containers.select_av1_stream(probe)
            packets = containers.stream_packets(probe, int(selected['index']))
            if len(packets) != case['frames']:
                raise ValueError('One-presentation-per-packet count differs: '+filename)
            if original:
                original_stream = containers.select_av1_stream(original_probe)
                original_packets = containers.stream_packets(original_probe,original_stream['index'])
                keys = ('pts','dts','duration','flags','size','data_hash','crc32')
                if [[p.get(k) for k in keys] for p in original_packets] != [[p.get(k) for k in keys] for p in packets]:
                    raise ValueError('Remux changed AV1 packets or their media timing')
            frame_command = ['ffprobe','-v','error', *(['-ignore_editlist','1'] if is_mp4 else []),
                             '-select_streams','v:0','-show_frames','-show_entries',
                             'frame=pts,pkt_dts,pkt_pos,width,height,pix_fmt','-of','json',filename]
            frame_probe = json.loads(run(frame_command).stdout)
            frames = frame_probe['frames']
            if len(frames) != len(packets) or any(
                    str(frame.get('pkt_pos')) != str(packet.get('pos')) or frame.get('pts') != packet.get('pts')
                    for frame, packet in zip(frames, packets)):
                raise ValueError('Independent decoded frame/packet mapping differs: '+filename)
            for frame in frames:
                if (frame['width'],frame['height'],frame['pix_fmt']) != (case['width'],case['height'],pixel_format(case)):
                    raise ValueError('Container decoded geometry differs: '+filename)
            probe_name = filename+'.ffprobe.json'
            frame_name = filename+'.frames.json'
            for output_name, value in [(probe_name,probe),(frame_name,frame_probe)]:
                if check:
                    if json.loads((OUT/output_name).read_text(encoding='utf-8')) != value:
                        raise ValueError('Saved independent probe differs: '+output_name)
                else:
                    (OUT/output_name).write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
            record = dict(file=filename,sha256=bench.sha256(path),bytes=path.stat().st_size,
                          ffprobe=probe_name,ffprobe_frames=frame_name,ffprobe_frames_command=frame_command,
                          selected_av1_stream=selected,selected_av1_packet_count=len(packets),
                          selected_av1_packet_timing={key:[p.get(key) for p in packets] for key in ('pts','dts','duration','flags')},
                          selected_av1_packet_sizes=[int(p['size']) for p in packets],
                          max_selected_av1_packet_bytes=max(int(p['size']) for p in packets),
                          selected_av1_packet_sha256=[p['data_hash'] for p in packets],
                          selected_av1_packet_crc32=[p['crc32'] for p in packets],
                          structure=containers.mp4_structure(path))
            if original:
                record['rejected_original_export'] = original
            if is_mp4:
                record['declared_width'],record['declared_height'] = mp4_declared_geometry(path)
            else:
                record['native_packet_durations_ns'] = webm_native_durations(path)
                if len(record['native_packet_durations_ns']) != len(packets):
                    raise ValueError('WebM native duration count differs')
            artifacts[variant] = record
        metadata = case['sequence_metadata']
        # A budget applies to one decoder call/batch, not all presentations in
        # the file. Descriptor count and compressed retention have separate caps.
        max_packet = max(a['max_selected_av1_packet_bytes'] for a in artifacts.values())
        cap = max(65536, 2*max_packet+65536)
        record = dict(name=name,
                      source=dict(file=(OUT/(name+'.obu')).relative_to(ROOT).as_posix(),
                                  sha256=case['artifacts'][name+'.obu'], provenance=case['source_transform']),
                      sequence=dict(width=case['width'],height=case['height'],depth=case['depth'],
                                    sampling=case['sampling'],full_range=bool(metadata['color_range']),
                                    color_primaries=metadata['color_primaries'],
                                    transfer_characteristics=metadata['transfer_characteristics'],
                                    matrix_coefficients=metadata['matrix_coefficients'],
                                    presentations=case['frames'],native_frame_index_for_packet=list(range(case['frames']))),
                      native_reference=dict(file=(OUT/(name+'.reference.yuv')).relative_to(ROOT).as_posix(),
                                            sha256=case['artifacts'][name+'.reference.yuv'],
                                            frames=case['frames'],frame_bytes=frame_bytes(case),
                                            bytes=(OUT/(name+'.reference.yuv')).stat().st_size,
                                            frame_crc32=case['native_frame_crc32']),
                      stream_policy=dict(max_input_bytes=cap,max_chunk_bytes=32768,
                                         max_frames=case['frames']+64,max_total_pixels=536870912,
                                         complete_max_input_bytes=max(a['bytes'] for a in artifacts.values())+1,
                                         chunk_sizes_for_consumer=[1,7,31,257,4093,16384,32768]),
                      artifacts=artifacts)
        records.append(record)
    manifest = dict(schema_version=2,generator='scripts/generate-diverse-video-reference.py',
                    ffprobe_version=containers.ffprobe_version(),cases=records)
    if check:
        if json.loads(target.read_text(encoding='utf-8')) != manifest:
            raise ValueError('Container manifest differs from independent sources')
    else:
        target.write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    print(f'Diverse container references checked: {len(records)} cases')


def check_case(case):
    name = case['name']
    definition = next(spec for spec in SPECS if spec['name'] == name)
    if any((case.get('input_geometry', case).get(key) if key in ('width','height') else case.get(key)) != value
           for key, value in definition.items()):
        raise ValueError('Completed case definition differs: '+name)
    if sorted(case['artifacts']) != case_artifact_names(case):
        raise ValueError('Case artifact set differs from its explicit outputs: '+name)
    for filename, digest in case['artifacts'].items():
        if bench.sha256(OUT/filename) != digest:
            raise ValueError('Saved artifact differs: '+filename)
    native = OUT/(name+'.reference.yuv')
    if native.stat().st_size != frame_bytes(case)*case['frames'] or reference_frames(native,frame_bytes(case)) != case['native_frame_crc32']:
        raise ValueError('Native frame mapping changed: '+name)
    if case['sequence_metadata'] != large.sequence_metadata((OUT/(name+'.trace.txt')).read_bytes()):
        raise ValueError('Encoded sequence metadata differs: '+name)
    if len(large.temporal_units((OUT/(name+'.obu')).read_bytes())) != case['frames']:
        raise ValueError('Temporal unit count differs: '+name)
    expected_modes = ['av1'] if case.get('long') else ['av1','chunks']
    if case['frames'] == 1:
        expected_modes.append('avif')
    if case['modes'] != expected_modes:
        raise ValueError('Consumer modes differ: '+name)
    if case['source'] == 'tos' and '-an' not in case['encoder_command']:
        raise ValueError('Film derivative does not explicitly remove audio')
    if case['source'] == 'browser':
        record = OUT/'sources/browser-ui/capture.json'
        if not record.exists():
            raise ValueError('Missing browser capture record')
        capture = json.loads(record.read_text(encoding='utf-8'))
        if capture != case['browser_capture'] or capture['frames'] != case['frames']:
            raise ValueError('Browser capture metadata differs')
        if capture['license'] != 'CC0 1.0, MoonAV1 test content':
            raise ValueError('Browser source license differs')
        for filename,digest in capture['artifacts'].items():
            if bench.sha256(record.parent/filename) != digest:
                raise ValueError('Browser capture artifact differs: '+filename)


def check_source_manifest(saved, sources):
    if saved['sources'] != sources or saved['source_licenses'] != SOURCE_LICENSES:
        raise ValueError('Source provenance or license records differ')
    if [case['name'] for case in saved['cases']] != [case['name'] for case in SPECS]:
        raise ValueError('Canonical corpus case list differs')
    for case in saved['cases']:
        retained = json.loads((OUT/(case['name']+'.case.json')).read_text(encoding='utf-8'))
        if retained != case:
            raise ValueError('Manifest case differs from retained generation record')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--redecode', action='store_true')
    parser.add_argument('--containers', action='store_true', help='Build/check container probes from completed cases')
    parser.add_argument('--case', action='append', default=[])
    args = parser.parse_args()
    if args.containers:
        if args.case or args.redecode:
            parser.error('--containers uses the complete saved manifest; do not combine with --case/--redecode')
        saved = json.loads((OUT/'manifest.json').read_text(encoding='utf-8'))
        check_source_manifest(saved,source_records())
        for case in saved['cases']:
            check_case(case)
        container_manifest(saved['cases'],check=args.check)
        return
    OUT.mkdir(parents=True, exist_ok=True) if not args.check else None
    selected = [case for case in SPECS if not args.case or case['name'] in args.case]
    if not selected or set(args.case)-{case['name'] for case in selected}:
        parser.error('Unknown case')
    if not args.check and not args.case and (OUT/'manifest.json').exists():
        parser.error('Completed manifest exists; use --check')
    sources = source_records()
    cases = []
    for definition in selected:
        cache = OUT/(definition['name']+'.case.json')
        if cache.exists():
            case = json.loads(cache.read_text(encoding='utf-8'))
        elif args.check:
            raise ValueError('Missing completed case: '+definition['name'])
        else:
            print('Encoding '+definition['name'], flush=True)
            case = make_case(definition)
            cache.write_text(json.dumps(case,indent=2)+'\n',encoding='utf-8')
        check_case(case)
        if args.redecode:
            with tempfile.TemporaryDirectory(prefix='moonav1-diverse-') as temporary:
                command = ['dav1d','-q','--threads=1','--framedelay=1','-i',str(OUT/(case['name']+'.obu')),
                           '--muxer=yuv','-o',str(Path(temporary)/'reference.yuv')]
                run(command)
                if bench.sha256(Path(temporary)/'reference.yuv') != case['artifacts'][case['name']+'.reference.yuv']:
                    raise ValueError('Fresh dav1d native pixels differ')
        cases.append(case)
        print('Checked '+case['name'], flush=True)
    if not args.check:
        version = run(['dav1d','--version'])
        manifest = dict(schema_version=1,created_utc=datetime.now(timezone.utc).isoformat(),sources=sources,
                        source_licenses=SOURCE_LICENSES,
                        ffmpeg_version=run(['ffmpeg','-version']).stdout.splitlines()[0],
                        dav1d_version=(version.stdout+version.stderr).strip(),cases=cases)
        target = OUT/('manifest.json' if not args.case else 'selected-manifest.json')
        if target.exists() and target.name == 'manifest.json':
            raise ValueError('Completed manifest exists; use --check')
        target.write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    elif (OUT/'manifest.json').exists():
        saved = json.loads((OUT/'manifest.json').read_text(encoding='utf-8'))
        check_source_manifest(saved,sources)
        saved_cases = [case for case in saved['cases'] if not args.case or case['name'] in args.case]
        if saved_cases != cases:
            raise ValueError('Manifest cases differ from retained case records')
    print(f'Diverse references checked: {len(cases)} cases')


if __name__ == '__main__':
    main()
