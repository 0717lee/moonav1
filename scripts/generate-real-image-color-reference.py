#!/usr/bin/env python3
"""Independent real-AVIF RGBA16 and ICC-to-sRGB pixels; --check is read-only."""
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import struct
import sys

sys.dont_write_bytecode = True
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'tests/fixtures/avif-real-images'
NAME = 'wide_gamut_adobe_600x400'


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--libavif', required=True, help='Pinned libavif 0.11.1 shared library')
    args = parser.parse_args()
    target = OUT/'icc-reference.json'
    outputs = [OUT/(NAME+suffix) for suffix in ('.icc-input.rgba16','.icc-output.rgba16')]
    if not args.check and any(path.exists() for path in [target,*outputs]):
        parser.error('Completed reference exists; use --check')
    directory = os.add_dll_directory(str(Path(args.libavif).resolve().parent)) if hasattr(os,'add_dll_directory') else None
    try:
        rgba = load('real_rgba_reference','generate-rgba16-reference.py')
        images = load('real_image_reference','generate-real-image-reference.py')
        icc = load('real_icc_reference','generate-color-display-reference.py')
        module = rgba.load('real_rgba_libavif','generate-avif-premultiplied-alpha-reference.py')
        lib, version = module.library(args.libavif)
        manifest = json.loads((OUT/'manifest.json').read_text(encoding='utf-8'))
        case = next(c for c in manifest['cases'] if c['name'] == NAME)
        for filename,digest in case['artifacts'].items():
            if images.sha((OUT/filename).read_bytes()) != digest:
                raise ValueError('Real-image fixture changed: '+filename)
        meta = case['sequence_metadata']
        record = dict(name=NAME,source='avif-real-images/'+NAME+'.avif',
                      width=case['width'],height=case['height'],depth=case['depth'],
                      sx=0,sy=0,mono=False,full=bool(meta['color_range']),prem=False,
                      primaries=meta['color_primaries'],transfer=meta['transfer_characteristics'],
                      matrix=meta['matrix_coefficients'],
                      frames=[dict(yuv='avif-real-images/'+NAME+'.reference.yuv',alpha=None)])
        status,samples = rgba.libavif_frames(module,lib,record)[0]
        module.checked(status,'real-image RGBA16')
        avif = (OUT/(NAME+'.avif')).read_bytes()
        _,_,_,profile = images.extract_native(lib,avif)
        if not profile:
            raise ValueError('Wide-gamut image has no embedded ICC')
        cms = icc.LittleCMS().lib
        cms.cmsGetEncodedCMMversion.restype = C.c_uint32
        profile_buffer = C.create_string_buffer(profile)
        source = cms.cmsOpenProfileFromMem(profile_buffer,len(profile))
        destination = cms.cmsCreate_sRGBProfile()
        transform = None
        try:
            if not source or not destination:
                raise RuntimeError('ICC profile allocation failed')
            flags = icc.LCMS_COPY_ALPHA | 0x100  # cmsFLAGS_NOOPTIMIZE
            transform = cms.cmsCreateTransform(source,icc.TYPE_RGBA16,destination,icc.TYPE_RGBA16,1,flags)
            if not transform:
                raise RuntimeError('LittleCMS transform creation failed')
            source_pixels = (C.c_uint16*len(samples))(*samples)
            result = (C.c_uint16*len(samples))()
            cms.cmsDoTransform(transform,source_pixels,result,len(samples)//4)
            data = [struct.pack(f'<{len(samples)}H',*samples),struct.pack(f'<{len(result)}H',*result)]
        finally:
            if transform:
                cms.cmsDeleteTransform(transform)
            if source:
                cms.cmsCloseProfile(source)
            if destination:
                cms.cmsCloseProfile(destination)
        record = dict(schema_version=1,case=NAME,width=case['width'],height=case['height'],
                      avif_sha256=images.sha(avif),icc_sha256=images.sha(profile),
                      libavif_version=version,libavif_options=dict(depth=16,avoidLibYUV=1,chromaUpsampling=3,alphaPremultiplied=0),
                      lcms_version_encoded=int(cms.cmsGetEncodedCMMversion()),
                      intent=1,flags=flags,output='Straight RGBA UNORM16 little endian, ICC destination sRGB',
                      tolerance=dict(rgba16_rgb=1,icc_rgb=8,alpha=0),
                      artifacts={path.name:images.sha(value) for path,value in zip(outputs,data)})
        for path,value in [*zip(outputs,data),(target,(json.dumps(record,indent=2)+'\n').encode())]:
            if args.check:
                if path.read_bytes() != value:
                    raise ValueError('Independent color reference differs: '+path.name)
            else:
                path.write_bytes(value)
        print(f'Real-image ICC: {len(samples)//4} pixels; independent libavif and LittleCMS outputs match')
    finally:
        if directory:
            directory.close()


if __name__ == '__main__':
    main()
