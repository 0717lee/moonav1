#!/usr/bin/env python3
"""Build a licensed 30-second film corpus; verify AV1 and AVIF independently.

The source clip is Big Buck Bunny, (c) copyright 2008 Blender Foundation /
www.bigbuckbunny.org, CC BY 3.0. Original license: https://peach.blender.org/about/
Mirror: https://raw.githubusercontent.com/chintan9/Big-Buck-Bunny/master/BigBuckBunny1080p30s.mp4
No MoonAV1 results are used to create reference pixels. --check only verifies
saved artifacts; --redecode runs dav1d/libavif again into temporary storage.
"""
import argparse
import ctypes as C
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'tests/fixtures/av1-realvideo'
spec=importlib.util.spec_from_file_location('real_large',Path(__file__).with_name('generate-large-reference.py'))
large=importlib.util.module_from_spec(spec);spec.loader.exec_module(large)


def avif_compare(lib, module, path, reference):
    data=path.read_bytes();buffer=C.create_string_buffer(data)
    decoder=lib.avifDecoderCreate()
    try:
        module.animation.checked(lib.avifDecoderSetSource(decoder,2),'select tracks')
        module.animation.checked(lib.avifDecoderSetIOMemory(decoder,buffer,len(data)),'AVIF input')
        module.animation.checked(lib.avifDecoderParse(decoder),'parse animation')
        state=module.animation.Decoder.from_address(decoder)
        with reference.open('rb') as expected:
            for index in range(state.count):
                module.animation.checked(lib.avifDecoderNextImage(decoder),'decode animation')
                info=module.color.FullImage.from_address(state.image)
                if (info.width,info.height,info.depth,info.format)!=(512,288,8,3):raise ValueError('AVIF geometry differs')
                for plane in range(3):
                    width,height=(512,288) if plane==0 else (256,144)
                    for y in range(height):
                        raw=C.string_at(info.planes[plane]+y*info.strides[plane],width)
                        if raw!=expected.read(width):raise ValueError(f'libavif/dav1d difference frame {index}')
            if expected.read(1):raise ValueError('AVIF presentation count differs')
        return state.count
    finally:lib.avifDecoderDestroy(decoder)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path)
    p.add_argument('--encoded',type=Path,help='Reuse output of the recorded encoder command')
    p.add_argument('--check',action='store_true')
    p.add_argument('--redecode',action='store_true')
    p.add_argument('--dav1d',default=r'D:\ProgramData\anaconda3\Library\bin\dav1d.exe')
    p.add_argument('--libavif',default=r'D:\ProgramData\anaconda3\Library\bin\avif.dll')
    args=p.parse_args()
    if args.redecode or not args.check:
        module=large.load('real_libavif','generate-avif-premultiplied-alpha-reference.py')
        lib,version=module.library(args.libavif)
    name='bbb_8bit_512x288'
    if not args.check:
        if args.source is None:p.error('Generation requires --source')
        if (OUT/'manifest.json').exists():p.error('Corpus exists; use --check --redecode')
        OUT.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(args.source,OUT/'BigBuckBunny1080p30s.mp4')
        command=['ffmpeg','-hide_banner','-y','-i','BigBuckBunny1080p30s.mp4','-map','0:v:0','-an',
                 '-vf','scale=512:288:flags=lanczos','-pix_fmt','yuv420p','-frames:v','720',
                 '-c:v','libaom-av1','-cpu-used','6','-crf','32','-b:v','0','-threads','1',
                 '-g','120','-lag-in-frames','16','-color_primaries','bt709','-color_trc','bt709',
                 '-colorspace','bt709','-color_range','tv','-f','obu',name+'.obu']
        if args.encoded:shutil.copyfile(args.encoded,OUT/(name+'.obu'))
        else:large.run(command,OUT)
        decoder=[args.dav1d,'-q','--threads=1','--framedelay=1','-i',name+'.obu','--muxer=yuv','-o',name+'.reference.yuv']
        large.run(decoder,OUT)
        size=(OUT/(name+'.reference.yuv')).stat().st_size
        if size%(512*288*3//2):raise ValueError('Incomplete reference frame')
        count=size//(512*288*3//2)
        if count<600:raise ValueError('Long corpus has too few presentations')
        container=['ffmpeg','-hide_banner','-y','-r','24','-i',name+'.obu','-c:v','copy','-f','avif',name+'.avif']
        large.run(container,OUT)
        if avif_compare(lib,module,OUT/(name+'.avif'),OUT/(name+'.reference.yuv'))!=count:raise ValueError('Container count differs')
        trace,headers=large.mainline.header_trace('ffmpeg',OUT/(name+'.obu'),OUT)
        (OUT/(name+'.trace.txt')).write_bytes(trace)
        unit_count=len(large.temporal_units((OUT/(name+'.obu')).read_bytes()))
        evidence=dict(temporal_units=unit_count,presentations=count,
                      hidden_frames=sum(h.get('show_frame')==0 and not h.get('show_existing_frame') for h in headers),
                      show_existing_frames=sum(h.get('show_existing_frame',0) for h in headers),
                      inter_frames=sum(h.get('frame_type')==1 for h in headers))
        if not evidence['hidden_frames'] or not evidence['show_existing_frames']:raise ValueError('Expected reordered inter pictures')
        case=dict(name=name,width=512,height=288,depth=8,sampling='420',frames=count,animation=True,
                  sequence_metadata=large.sequence_metadata(trace),evidence=evidence,
                  encoder_command=command,decoder_command=['dav1d']+decoder[1:],container_command=container,
                  artifacts={f.name:large.sha(f.read_bytes()) for f in sorted(OUT.glob(name+'.*'))})
        manifest=dict(source=dict(file='BigBuckBunny1080p30s.mp4',sha256=large.sha((OUT/'BigBuckBunny1080p30s.mp4').read_bytes()),
                      url='https://raw.githubusercontent.com/chintan9/Big-Buck-Bunny/master/BigBuckBunny1080p30s.mp4',
                      attribution='(c) copyright 2008, Blender Foundation / www.bigbuckbunny.org',
                      license='CC BY 3.0',license_url='https://peach.blender.org/about/',
                      changes='30-second excerpt from the mirrored clip, scaled to 512x288 and encoded as 8-bit AV1/AVIF; no audio'),
                      libavif=version,dav1d=large.run([args.dav1d,'--version'],ROOT).stderr.strip(),
                      ffmpeg=large.run(['ffmpeg','-version'],ROOT).stdout.splitlines()[0],cases=[case])
        (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    else:manifest=json.loads((OUT/'manifest.json').read_text())
    if large.sha((OUT/manifest['source']['file']).read_bytes())!=manifest['source']['sha256']:raise ValueError('Source differs')
    for case in manifest['cases']:
        for n,h in case['artifacts'].items():
            if large.sha((OUT/n).read_bytes())!=h:raise ValueError('Artifact differs: '+n)
        if args.redecode:
            with tempfile.TemporaryDirectory(prefix='moonav1-realvideo-') as tmp:
                large.run([args.dav1d,'-q','--threads=1','--framedelay=1','-i',str(OUT/(case['name']+'.obu')),'--muxer=yuv','-o','reference.yuv'],tmp)
                if large.sha((Path(tmp)/'reference.yuv').read_bytes())!=case['artifacts'][case['name']+'.reference.yuv']:raise ValueError('dav1d differs')
            avif_compare(lib,module,OUT/(case['name']+'.avif'),OUT/(case['name']+'.reference.yuv'))
    print('Real video:',[(c['name'],c['evidence']) for c in manifest['cases']])


if __name__=='__main__':main()
