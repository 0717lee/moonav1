#!/usr/bin/env python3
"""Build a separate local consumer module with no registry or remote operations.

The pinned Moon toolchain supports a local path dependency in moon.mod.json.
Generated consumer files stay below _build/standalone-*-consumer (or the
original _build/standalone-consumer); --target-dir can reuse a build cache.
The public example and its saved inputs are copied; the decoder itself is a dependency.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode=True

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('consumer_bench',Path(__file__).with_name('benchmark.py'))
bench=importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'_build/standalone-consumer-results.json')
    parser.add_argument('--example',choices=('native_pixels','extensions','color_video'),default='native_pixels')
    parser.add_argument('--target-dir',type=Path,help='Reuse a local build cache instead of creating another large cache')
    args=parser.parse_args()
    consumer_name={
        'native_pixels':'_build/standalone-consumer',
        'extensions':'_build/standalone-extensions-consumer',
        'color_video':'_build/standalone-color-video-consumer',
    }[args.example]
    consumer=ROOT/consumer_name
    consumer.mkdir(parents=True,exist_ok=True)
    (consumer/'moon.mod.json').write_text(json.dumps({'name':'local/moonav1_consumer','deps':{'0717lee/moonav1':{'path':'../..'}}},indent=2)+'\n',encoding='utf-8')
    (consumer/'moon.pkg').write_text('import { "0717lee/moonav1" }\npkgtype(kind: "executable")\n',encoding='utf-8')
    for name in ('main.mbt','fixtures.mbt'):
        (consumer/name).write_bytes((ROOT/'examples'/args.example/name).read_bytes())
    (consumer/'callback_test.mbt').write_text('''///|
test "original unary decoder function values" {
  let decode : (Array[Byte]) -> @moonav1.Av1NativeFrame? = @moonav1.av1_decode_native
  assert_true(decode([]) is None)
  let images = [[]].map(@moonav1.avif_decode_rgba)
  assert_true(images[0] is None)
}
''',encoding='utf-8')
    results={}
    build_args=[] if args.target_dir is None else ['--target-dir',str(args.target_dir.resolve())]
    for target in ('native','js','wasm-gc'):
        print(f'Building separate consumer: {target}',flush=True)
        result=subprocess.run(['moon','run','.','--frozen','--release','--target',target,*build_args],cwd=consumer,
                              capture_output=True,text=True,encoding='utf-8')
        (consumer/f'{target}.log').write_text(result.stdout+result.stderr,encoding='utf-8')
        if result.returncode:
            raise SystemExit(result.stdout+result.stderr)
        lines=result.stdout.strip().splitlines()
        expected={
            'native_pixels':(11,'Animation RGBA16: low native alpha 1 -> 16'),
            'extensions':(6,'Diagnostic: TruncatedInput'),
            'color_video':(12,'Timeline: edits=2, movie tick 0=empty edit'),
        }[args.example]
        if len(lines)!=expected[0] or lines[-1]!=expected[1]:
            raise SystemExit('Unexpected public consumer output')
        if args.example == 'color_video':
            if lines[:7] != [
                'ICC: RGBA16 16x16, profile=588 bytes, alpha=0',
                'HDR: explicit PQ tone map, SDR16 red=65535',
                'Crop: 23/2 x 19/2 clap, transforms=3, RGBA16 7x6, red=52927',
                'Container IVF: packets=8, presentations=8',
                'Container MP4: packets=8, presentations=8',
                'Container WebM: packets=8, presentations=8',
                'ICC policy: relative+BPC, red=0, alpha=0',
            ] or lines[10] != 'Seek: requested=0, outcome=exact, packet=0':
                raise SystemExit('Color/video consumer observations differ')
            for label, line in zip(('IVF','MP4','WebM'), lines[7:10]):
                observed = re.fullmatch(rf'Stream {label}: presentations=8, peak=(\d+), replay=false', line)
                if observed is None or not 0 < int(observed[1]) <= 8192:
                    raise SystemExit('Incremental public consumer output or buffer bound differs')
        results[target]=lines
        tested=subprocess.run(['moon','test','--frozen','--release','--target',target,*build_args],cwd=consumer,
                              capture_output=True,text=True,encoding='utf-8')
        (consumer/f'{target}-callback-test.log').write_text(tested.stdout+tested.stderr,encoding='utf-8')
        if tested.returncode or 'Total tests: 1, passed: 1, failed: 0.' not in tested.stdout:
            raise SystemExit(tested.stdout+tested.stderr)
    if results['native']!=results['js'] or results['js']!=results['wasm-gc']:
        raise SystemExit('Public consumer backends differ')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    sources=[p for p in ROOT.glob('*.mbt') if not p.stem.endswith(('_test','_wbtest'))]
    args.output.write_text(json.dumps({'consumer':'local/moonav1_consumer','dependency':'../..','example':args.example,
                                      'source_sha256':bench.digest(sources+[ROOT/'moon.mod',ROOT/'moon.pkg']),
                                      'example_sha256':hashlib.sha256((consumer/'main.mbt').read_bytes()).hexdigest(),
                                      'callback_tests':{target:'1/1 passed' for target in results},
                                      'outputs':results},indent=2)+'\n',encoding='utf-8')
    print('Separate local module: all three backends passed with identical output')


if __name__=='__main__': main()
