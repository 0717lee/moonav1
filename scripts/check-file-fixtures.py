#!/usr/bin/env python3
"""Verify file-backed independent pixels through the same three decode cores.

Host adapters perform buffered file IO only; they never decode media. Process
elapsed time includes IO and comparisons and is not a codec benchmark.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('file_bench', Path(__file__).with_name('benchmark.py'))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def config(case, mode, repetitions):
    sampling = case.get('sampling', '420')
    metadata = case['sequence_metadata']
    return [case['width'],case['height'],case['depth'],1 if sampling=='400' else 3,
            int(sampling in ('420','422')),int(sampling=='420'),
            metadata['color_primaries'],metadata['transfer_characteristics'],metadata['matrix_coefficients'],metadata['color_range'],
            case['frames'],{'av1':0,'avif':1,'animation':2,'chunks':3}[mode],int(case.get('alpha',False)),repetitions,
            int(case.get('alpha_full_range',False)),int(case.get('premultiplied',False)),int(case.get('icc_reference',False))]


def sample_count(case):
    w,h=case['width'],case['height']
    sampling=case.get('sampling','420')
    sx,sy=sampling in ('420','422'),sampling=='420'
    count=w*h
    if sampling!='400': count+=2*((w+sx)>>sx)*((h+sy)>>sy)
    if case.get('alpha'): count+=w*h
    return count


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest',type=Path,default=ROOT/'tests/fixtures/av1-maturity/manifest.json')
    parser.add_argument('--case',action='append',default=[])
    parser.add_argument('--targets',nargs='+',choices=bench.TARGETS,default=list(bench.TARGETS))
    parser.add_argument('--target-dir',default='_build/file-verify')
    parser.add_argument('--output',type=Path,default=ROOT/'benchmarks/results/maturity-pixels.json')
    parser.add_argument('--video-repetitions',type=int,default=1)
    parser.add_argument('--timeout',type=float,default=600)
    parser.add_argument('--extensions',action='store_true',help='Also verify arbitrary input chunks and lazy AVIF animation/seek')
    parser.add_argument('--icc-reference',type=Path,help='Optional independent real-image ICC reference manifest')
    args=parser.parse_args()
    if args.video_repetitions<1 or args.timeout<=0: parser.error('Positive repetition count and timeout required')
    manifest=json.loads(args.manifest.read_text(encoding='utf-8'))
    cases=[case for case in manifest['cases'] if not args.case or case['name'] in args.case]
    if not cases or set(args.case)-{c['name'] for c in cases}: parser.error('Unknown or empty selection')
    # Validate selected binaries before any decoder sees them.
    folder=args.manifest.resolve().parent
    for case in cases:
        modes = case.get('modes')
        if modes is not None and (not modes or any(mode not in ('av1', 'avif', 'animation', 'chunks') for mode in modes)
                                  or len(set(modes)) != len(modes)):
            parser.error('Invalid explicit fixture modes: ' + case['name'])
        for filename,digest in case['artifacts'].items():
            if bench.sha256(folder/filename)!=digest: raise SystemExit(f'Fixture changed: {filename}')
    if args.icc_reference:
        reference=json.loads(args.icc_reference.read_text(encoding='utf-8'))
        selected=next((case for case in cases if case['name']==reference['case']),None)
        if selected is None or selected['artifacts'][selected['name']+'.avif']!=reference['avif_sha256']:
            parser.error('ICC reference source is not a selected AVIF case')
        if args.icc_reference.resolve().parent!=folder or reference['tolerance']!=dict(rgba16_rgb=1,icc_rgb=8,alpha=0):
            parser.error('ICC reference location or precision contract differs')
        expected_files={selected['name']+suffix for suffix in ('.icc-input.rgba16','.icc-output.rgba16')}
        if (set(reference['artifacts'])!=expected_files or
                reference['icc_sha256']!=selected.get('icc',{}).get('sha256') or
                (reference['width'],reference['height'])!=(selected['width'],selected['height']) or
                'avif' not in selected.get('modes',[])):
            parser.error('ICC oracle files, profile, dimensions or AVIF mode differ')
        for filename,digest in reference['artifacts'].items():
            if bench.sha256(folder/filename)!=digest: raise SystemExit(f'ICC reference changed: {filename}')
            if (folder/filename).stat().st_size!=selected['width']*selected['height']*8:
                parser.error('ICC reference extent differs')
        selected['icc_reference']=True
    sources=[p for p in ROOT.glob('*.mbt') if not p.stem.endswith(('_test','_wbtest'))]
    harness=[p for p in (ROOT/'tests/file_decode').iterdir() if p.suffix in ('.mbt','.c','.cjs') or p.name=='moon.pkg']
    report=dict(created_utc=datetime.now(timezone.utc).isoformat(),
                source_sha256=bench.digest(sources+[ROOT/'moon.mod',ROOT/'moon.pkg']),
                harness_sha256=bench.digest(harness+[Path(__file__).resolve()]),
                manifest_sha256=bench.sha256(args.manifest),
                moon_version=bench.run(['moon','version','--all']).stdout.strip(),
                node_version=bench.run(['node','--version']).stdout.strip(),
                git_head=bench.run(['git','rev-parse','HEAD']).stdout.strip(),
                deadline_seconds=args.timeout,video_repetitions=args.video_repetitions,artifacts={},runs=[])
    if args.icc_reference:
        report['icc_reference_sha256']=bench.sha256(args.icc_reference)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    for target in args.targets:
        print(f'Building file consumer: {target}',flush=True)
        built=bench.run(['moon','run','tests/file_decode','--frozen','--release','--target',target,
                         '--target-dir',args.target_dir,'--build-only','--output-json'])
        paths=[json.loads(line)['artifacts_path'] for line in built.stdout.splitlines() if line.startswith('{') and '"artifacts_path"' in line]
        if len(paths)!=1 or len(paths[0])!=1: raise SystemExit('Unexpected artifact result')
        path=Path(paths[0][0]).resolve()
        report['artifacts'][target]=dict(path=path.relative_to(ROOT).as_posix(),sha256=bench.sha256(path))
    for target in args.targets:
        path=ROOT/report['artifacts'][target]['path']
        for case in cases:
            modes=list(case['modes']) if 'modes' in case else (['avif'] if case.get('grid') else (['av1','avif'] if case['frames']==1 else ['av1']))
            if args.extensions and not case.get('grid'):
                if 'av1' in modes and 'chunks' not in modes: modes.append('chunks')
                if case.get('animation') and 'animation' not in modes: modes.append('animation')
            for mode in modes:
                repeats=args.video_repetitions if case['frames']>1 else 1
                environment=os.environ.copy()
                environment['MOONAV1_FIXTURE_PREFIX']=(folder/case['name']).relative_to(ROOT).as_posix()
                environment['MOONAV1_FIXTURE_CONFIG']=','.join(map(str,config(case,mode,repeats)))
                command=[str(path)] if target=='native' else (['node','--require',str(ROOT/'tests/file_decode/io-node.cjs'),str(path)] if target=='js' else ['node',str(ROOT/'tests/file_decode/run-wasm.cjs'),str(path)])
                started=time.monotonic()
                print(f'Verifying {target} {case["name"]} {mode} x{repeats}',flush=True)
                try:
                    process=subprocess.run(command,cwd=ROOT,env=environment,capture_output=True,text=True,encoding='utf-8',timeout=args.timeout)
                    expected=f'Verified frames={case["frames"]*repeats} samples={sample_count(case)*case["frames"]*repeats} '
                    passed=process.returncode==0 and process.stdout.startswith(expected)
                    if case.get('icc_reference') and mode=='avif':
                        passed=passed and f"icc_pixels={case['width']*case['height']} " in process.stdout
                    output=process.stdout+process.stderr
                except subprocess.TimeoutExpired:
                    passed,output=False,'timeout'
                report['runs'].append(dict(target=target,case=case['name'],mode=mode,repetitions=repeats,
                                           passed=passed,elapsed_seconds=time.monotonic()-started,output=output[-6000:]))
                args.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
                print(output.strip(),flush=True)
                if not passed: raise SystemExit('File-backed pixel verification failed; see saved report')
    print(f'Passed {len(report["runs"])} file-backed checks',flush=True)


if __name__=='__main__': main()
