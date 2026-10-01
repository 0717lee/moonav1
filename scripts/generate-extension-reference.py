#!/usr/bin/env python3
"""Real libavif metadata/transform/animation references and public API tests.

Native pixels and metadata come from libavif; the established Fraction oracle
retains MoonAV1's native-alpha-before-quantization RGBA16 contract. Actual
libavif RGBA16 is saved separately (its low-alpha rounding order differs).
Display uses NumPy crop/rot90/flip, independently of MoonAV1's coordinate map.
--verify reopens saved binaries without encoding or changing their references.
--check checks generated MoonBit text only (no native library needed).
"""
from __future__ import annotations
import argparse
import ctypes as C
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'tests/fixtures/extensions'
TEST = ROOT / 'extension_reference_test.mbt'


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


prem = load('extension_prem', 'generate-avif-premultiplied-alpha-reference.py')
embed = load('extension_embed', 'generate-native-api-tests.py')
rgba_reference = load('extension_rgba', 'generate-rgba16-reference.py')
anim = prem.animation


class FullImage(C.Structure):
    _fields_ = prem.color.FullImage._fields_ + [
        ('flags', C.c_uint32), ('aspect', C.c_uint32 * 2),
        ('crop', C.c_uint32 * 8), ('rotation', C.c_uint8), ('mirror', C.c_uint8),
        ('exif', anim.RWData), ('xmp', anim.RWData)]


class CropRect(C.Structure):
    _fields_ = [('x', C.c_uint32), ('y', C.c_uint32), ('w', C.c_uint32), ('h', C.c_uint32)]


def library(path):
    lib, version = prem.library(path)
    for name in ('avifImageSetProfileICC', 'avifImageSetMetadataExif', 'avifImageSetMetadataXMP'):
        getattr(lib, name).argtypes = [C.c_void_p, C.c_void_p, C.c_size_t]
    lib.avifCropRectConvertCleanApertureBox.argtypes = [C.POINTER(CropRect), C.c_void_p, C.c_uint32, C.c_uint32, C.c_int, C.c_void_p]
    lib.avifCropRectConvertCleanApertureBox.restype = C.c_int
    return lib, version


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encode(lib, depth, turns, mirror, animated):
    from PIL import ImageCms
    icc = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
    exif = b'Exif\0\0II\x2a\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00'
    xmp = b'<x:xmpmeta xmlns:x="adobe:ns:meta/"><test>MoonAV1 metadata reference</test></x:xmpmeta>'
    encoder = lib.avifEncoderCreate()
    options = anim.Encoder.from_address(encoder)
    options.codec, options.threads, options.speed = 1, 1, 6
    options.keyframe_interval, options.timescale = 2, 1000
    options.min_q = options.max_q = options.min_aq = options.max_aq = 0
    output = anim.RWData()
    try:
        for index in range(3 if animated else 1):
            image = lib.avifImageCreate(16, 16, depth, 1)
            try:
                info = FullImage.from_address(image)
                info.range, info.primaries, info.transfer, info.matrix = 1, 1, 13, 6
                info.premultiplied = 1
                rgb = anim.helpers.ScalarRGB0111()
                lib.avifRGBImageSetDefaults(C.byref(rgb), image)
                rgb.avoidLibYUV, rgb.alphaPremultiplied = 1, 1
                rgba = C.create_string_buffer(prem.pack_samples(prem.input_rgba(depth, index), depth))
                rgb.pixels, rgb.rowBytes = C.addressof(rgba), 16 * 4 * (1 if depth == 8 else 2)
                anim.checked(lib.avifImageRGBToYUV(image, C.byref(rgb)), 'input conversion')
                for name, payload in [('avifImageSetProfileICC', icc), ('avifImageSetMetadataExif', exif), ('avifImageSetMetadataXMP', xmp)]:
                    buffer = C.create_string_buffer(payload)
                    getattr(lib, name)(image, buffer, len(payload))
                info.flags = 15
                info.aspect[:] = [1, 1]
                info.crop[:] = [12, 1, 10, 1, (-1) & 0xffffffff, 1, 1, 1]
                info.rotation, info.mirror = turns, mirror
                if animated:
                    anim.checked(lib.avifEncoderAddImage(encoder, image, (100, 200, 300)[index], 0), 'encode track')
                else:
                    anim.checked(lib.avifEncoderWrite(encoder, image, C.byref(output)), 'encode item')
            finally:
                lib.avifImageDestroy(image)
        if animated:
            anim.checked(lib.avifEncoderFinish(encoder, C.byref(output)), 'finish tracks')
        return C.string_at(output.data, output.size)
    finally:
        lib.avifRWDataFree(C.byref(output))
        lib.avifEncoderDestroy(encoder)


def decode(lib, data, animated):
    import numpy as np
    decoder = lib.avifDecoderCreate()
    buffer = C.create_string_buffer(data)
    try:
        anim.checked(lib.avifDecoderSetSource(decoder, 2 if animated else 1), 'select source')
        anim.checked(lib.avifDecoderSetIOMemory(decoder, buffer, len(data)), 'set input')
        anim.checked(lib.avifDecoderParse(decoder), 'parse metadata')
        state = anim.Decoder.from_address(decoder)
        frames = []
        metadata = None
        for index in range(state.count):
            anim.checked(lib.avifDecoderNextImage(decoder), 'decode reference')
            info = FullImage.from_address(state.image)
            if (info.width, info.height, info.flags, info.premultiplied) != (16, 16, 15, 1):
                raise RuntimeError('reference ABI/metadata mismatch')
            blobs = {name: C.string_at(getattr(info, name).data, getattr(info, name).size) for name in ('icc', 'exif', 'xmp')}
            crop = CropRect()
            diagnostics = C.create_string_buffer(256)
            if not lib.avifCropRectConvertCleanApertureBox(C.byref(crop), C.byref(info.crop), 16, 16, 1, diagnostics):
                raise RuntimeError('libavif rejected crop: '+repr(list(info.crop))+' '+repr(diagnostics.value))
            metadata = dict(blobs=blobs, crop=list(info.crop), rect=[crop.x, crop.y, crop.w, crop.h],
                            rotation=info.rotation, mirror=info.mirror, aspect=list(info.aspect))
            rgb = anim.helpers.ScalarRGB0111()
            lib.avifRGBImageSetDefaults(C.byref(rgb), state.image)
            rgb.depth, rgb.avoidLibYUV, rgb.chromaUpsampling, rgb.alphaPremultiplied = 16, 1, 3, 0
            lib.avifRGBImageAllocatePixels(C.byref(rgb))
            try:
                anim.checked(lib.avifImageYUVToRGB(state.image, C.byref(rgb)), 'reference RGBA16')
                raw = b''.join(C.string_at(rgb.pixels + y * rgb.rowBytes, 16 * 8) for y in range(16))
            finally:
                lib.avifRGBImageFreePixels(C.byref(rgb))
            yuv, alpha = prem.native_planes(info)
            dtype = 'u1' if info.depth == 8 else '<u2'
            record = dict(width=16, height=16, depth=info.depth, full=bool(info.range),
                          sx=0, sy=0, mono=False, matrix=info.matrix, primaries=info.primaries,
                          transfer=info.transfer, prem=bool(info.premultiplied), alpha_full=True)
            exact = rgba_reference.convert(record, np.frombuffer(yuv,dtype=dtype).tolist(),
                                           np.frombuffer(alpha,dtype=dtype).tolist())
            reference = struct.pack('<1024H', *exact)
            pixels = np.frombuffer(reference, dtype='<u2').reshape(16, 16, 4)
            display = pixels[crop.y:crop.y+crop.h, crop.x:crop.x+crop.w]
            display = np.rot90(display, info.rotation)
            display = np.flip(display, axis=0 if info.mirror == 0 else 1).copy()
            frames.append(dict(yuv=yuv, alpha=alpha, rgba16=reference, libavif_rgba16=raw, display=display.tobytes(),
                               libavif_max_difference=max(abs(a-b) for a,b in zip(exact,struct.unpack('<1024H',raw))),
                               display_size=[display.shape[1], display.shape[0]],
                               timing=[state.timing.pts_units, state.timing.duration_units, state.timing.timescale]))
        return metadata, frames
    finally:
        lib.avifDecoderDestroy(decoder)


def source(manifest):
    text = '''/// Generated by scripts/generate-extension-reference.py.
/// Actual libavif metadata/native; Fraction RGBA16; NumPy display permutations.

///|
fn extension_pixels(image : @moonav1.AvifNativeImage,
  color : Array[Int], alpha : Array[Int], rgba : Array[Int]) -> Unit raise {
  let mut at = 0
  for plane in image.color.planes {
    for value in plane.data { assert_eq(value, color[at]); at += 1 }
  }
  assert_eq(at, color.length())
  assert_eq(image.alpha.unwrap().planes[0].data, FixedArray::from_array(alpha))
  let converted = image.to_rgba16().unwrap()
  for i in 0..<rgba.length() {
    assert_true((converted.data[i].to_int() - rgba[i]).abs() <= (if i % 4 == 3 { 0 } else { 1 }),
      msg="RGBA16 channel \{i}: actual=\{converted.data[i]} expected=\{rgba[i]}")
  }
}
'''
    for case in manifest['cases']:
        name = case['name']
        text += f'\n///|\nfn extension_{name}() -> Array[Byte] {{\n  {embed.input_expr(OUT/(name+".avif"))}\n}}\n'
        text += f'\n///|\ntest "extension reference {name}" {{\n  let data = extension_{name}()\n'
        if case['animated']:
            text += '  let decoder = @moonav1.AvifAnimationDecoder::new(data).unwrap()\n  let metadata = decoder.metadata()\n'
        else:
            text += '  let metadata = @moonav1.avif_metadata(data).unwrap()\n'
        for blob in ('icc','exif','xmp'):
            text += f'  assert_eq(metadata.{blob}.unwrap(), FixedArray::from_array({embed.input_expr(OUT/(name+"."+blob))}))\n'
        text += '  assert_eq(metadata.pixel_aspect_ratio, Some((1L, 1L)))\n  assert_eq(metadata.transforms.length(), 3)\n'
        if not case['animated']:
            text += '  assert_eq(metadata.exif_tiff_offset, Some(6))\n'
        for index, frame in enumerate(case['frames']):
            prefix=f'{name}_{index}'
            if case['animated']:
                text += '  let frame = decoder.next_frame().unwrap().unwrap()\n  let image = frame.image\n'
            else:
                text += '  let image = @moonav1.avif_decode_native(data).unwrap()\n'
            args=[embed.reference_expr(embed.samples(OUT/(prefix+'.'+kind), case['depth'] if kind!='rgba16' else 16)) for kind in ('yuv','alpha','rgba16')]
            text += '  extension_pixels(image, '+', '.join(args)+')\n'
            w,h=frame['display_size']
            text += f'  assert_eq(metadata.display_size(16, 16).unwrap(), ({w}, {h}))\n'
            text += '  let displayed = metadata.apply_rgba16(image.to_rgba16().unwrap()).unwrap()\n'
            text += '  let expected = '+embed.reference_expr(embed.samples(OUT/(prefix+'.display'),16))+'\n'
            text += '  for i in 0..<expected.length() { assert_true((displayed.data[i].to_int() - expected[i]).abs() <= (if i % 4 == 3 { 0 } else { 1 })) }\n'
        if case['animated']:
            text += '  assert_true(decoder.next_frame().unwrap() is None)\n  assert_true(decoder.is_keyframe(2).unwrap())\n  assert_eq(decoder.nearest_keyframe(2).unwrap(), Some(2))\n  decoder.reset()\n'
            text += '  let sought = decoder.seek_frame(2).unwrap()\n  assert_eq(sought.index, 2)\n  stream_same_frame(sought.image.color, image.color)\n  stream_same_frame(sought.image.alpha.unwrap(), image.alpha.unwrap())\n'
            text += '  let saved = decoder.metadata().icc.unwrap()[0]\n  metadata.icc.unwrap()[0] = (saved.to_int() ^ 255).to_byte()\n  assert_eq(decoder.metadata().icc.unwrap()[0], saved)\n'
        text += '}\n'
    return text


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libavif',default=r'D:\ProgramData\anaconda3\Library\bin\avif.dll')
    parser.add_argument('--check',action='store_true')
    parser.add_argument('--embed-only',action='store_true')
    parser.add_argument('--verify',action='store_true')
    parser.add_argument('--rebuild-references',action='store_true',help='Re-decode saved inputs and regenerate references/tests without encoding')
    args=parser.parse_args()
    if args.check or args.embed_only:
        manifest=json.loads((OUT/'manifest.json').read_text())
    else:
        lib,version=library(args.libavif)
        OUT.mkdir(parents=True,exist_ok=True)
        manifest=dict(libavif=version,provenance='Locally generated libavif fixtures; Fraction native-alpha RGBA16; NumPy crop/rot90/flip. Actual libavif RGBA16 retained separately. No MoonAV1 output used as oracle.',cases=[])
        existing=json.loads((OUT/'manifest.json').read_text()) if args.verify else None
        for depth,turns,mirror,animated in [(8 if t%2==0 else 12,t,m,False) for t in range(4) for m in range(2)]+[(10,3,1,True)]:
            name=f'metadata_{depth}_r{turns}_m{mirror}'+('_animation' if animated else '')
            data=(OUT/(name+'.avif')).read_bytes() if args.verify or args.rebuild_references else encode(lib,depth,turns,mirror,animated)
            meta,frames=decode(lib,data,animated)
            artifacts={name+'.avif':data,**{name+'.'+k:v for k,v in meta.pop('blobs').items()}}
            for i,frame in enumerate(frames):
                for k in ('yuv','alpha','rgba16','libavif_rgba16','display'): artifacts[f'{name}_{i}.{k}']=frame.pop(k)
            case=dict(name=name,depth=depth,animated=animated,metadata=meta,frames=frames,artifacts={n:sha(b) for n,b in artifacts.items()})
            if args.verify:
                expected=next(c for c in existing['cases'] if c['name']==name)
                if case!=expected: raise SystemExit('Independent reference changed: '+name)
                for n,b in artifacts.items():
                    if (OUT/n).read_bytes()!=b: raise SystemExit('Saved bytes changed: '+n)
            else:
                for n,b in artifacts.items():(OUT/n).write_bytes(b)
            manifest['cases'].append(case)
        if not args.verify:(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    helpers=embed.HELPERS[embed.HELPERS.index('///|'):embed.HELPERS.index('///|\nfn native_test_expand')]
    example='/// Generated from unchanged tests/fixtures/extensions inputs.\n'+helpers
    for fn,name in [('metadata_fixture','metadata_12_r1_m0'),('animation_fixture','metadata_10_r3_m1_animation')]:
        example+=f'\n///|\nfn {fn}() -> Array[Byte] {{\n{embed.input_expr(OUT/(name+".avif"))}\n}}\n'
    for path,raw in [(TEST,source(manifest)),(ROOT/'examples/extensions/fixtures.mbt',example)]:
        formatted=subprocess.run(['moonfmt','-'],input=raw,capture_output=True,text=True,encoding='utf-8',check=True).stdout
        if args.check or args.verify:
            if path.read_text(encoding='utf-8')!=formatted:raise SystemExit('Generated source differs: '+str(path))
        else:
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_text(formatted,encoding='utf-8')
    print(f'Checked {len(manifest["cases"])} independent metadata/animation cases')


if __name__=='__main__':main()
