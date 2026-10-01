#!/usr/bin/env python3
"""Measure process memory while verifying short and sustained native output.

Windows uses the OS process counters, including runtime/JIT and buffered file
IO. This compares 300 versus 3,000 presentations; it does not measure a decoder
allocation ledger or establish a portable byte ceiling.
"""
import argparse
import ctypes as C
from ctypes import wintypes as W
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('file_check', Path(__file__).with_name('check-file-fixtures.py'))
files = importlib.util.module_from_spec(spec)
spec.loader.exec_module(files)


class Counters(C.Structure):
    _fields_ = [('cb', W.DWORD), ('faults', W.DWORD),
                ('peak_working_set', C.c_size_t), ('working_set', C.c_size_t),
                ('peak_paged_pool', C.c_size_t), ('paged_pool', C.c_size_t),
                ('peak_nonpaged_pool', C.c_size_t), ('nonpaged_pool', C.c_size_t),
                ('pagefile', C.c_size_t), ('peak_pagefile', C.c_size_t), ('private', C.c_size_t)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path, default=ROOT/'benchmarks/results/maturity-pixels.json')
    parser.add_argument('--output', type=Path, default=ROOT/'benchmarks/results/stream-memory.json')
    parser.add_argument('--timeout', type=float, default=600)
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('This recorded process-counter implementation requires Windows')
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    kernel = C.WinDLL('kernel32', use_last_error=True)
    psapi = C.WinDLL('psapi', use_last_error=True)
    kernel.OpenProcess.argtypes, kernel.OpenProcess.restype = [W.DWORD, W.BOOL, W.DWORD], W.HANDLE
    kernel.CloseHandle.argtypes, kernel.CloseHandle.restype = [W.HANDLE], W.BOOL
    psapi.GetProcessMemoryInfo.argtypes, psapi.GetProcessMemoryInfo.restype = [W.HANDLE, C.POINTER(Counters), W.DWORD], W.BOOL
    artifact_report = json.loads(args.artifacts.read_text(encoding='utf-8'))
    manifest = json.loads((ROOT/'tests/fixtures/av1-maturity/manifest.json').read_text(encoding='utf-8'))
    case = next(c for c in manifest['cases'] if c['name']=='video_10bit_320x180_300')
    sources = [p for p in ROOT.glob('*.mbt') if not p.stem.endswith(('_test','_wbtest'))]
    if files.bench.digest(sources+[ROOT/'moon.mod',ROOT/'moon.pkg']) != artifact_report['source_sha256']:
        parser.error('Artifacts do not match current decoder source')
    for filename,digest in case['artifacts'].items():
        if files.bench.sha256(ROOT/'tests/fixtures/av1-maturity'/filename)!=digest:
            parser.error(f'Fixture changed: {filename}')
    report = dict(source_sha256=artifact_report['source_sha256'],
                  artifact_report_sha256=files.bench.sha256(args.artifacts),
                  counter='Windows GetProcessMemoryInfo / PROCESS_MEMORY_COUNTERS_EX',
                  sampling_seconds=0.2,case=case['name'],runs=[])
    args.output.parent.mkdir(parents=True,exist_ok=True)
    for target,artifact in artifact_report['artifacts'].items():
        path=ROOT/artifact['path']
        if files.bench.sha256(path)!=artifact['sha256']:
            parser.error(f'Artifact changed: {path}')
        for repetitions in (1,10):
            environment=os.environ.copy()
            environment['MOONAV1_FIXTURE_PREFIX']='tests/fixtures/av1-maturity/'+case['name']
            environment['MOONAV1_FIXTURE_CONFIG']=','.join(map(str,files.config(case,'av1',repetitions)))
            command=[str(path)] if target=='native' else (['node','--require',str(ROOT/'tests/file_decode/io-node.cjs'),str(path)] if target=='js' else ['node',str(ROOT/'tests/file_decode/run-wasm.cjs'),str(path)])
            print(f'Measuring memory: {target}, {300*repetitions} presentations',flush=True)
            started=time.monotonic()
            proc=subprocess.Popen(command,cwd=ROOT,env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8')
            handle=kernel.OpenProcess(0x0410,False,proc.pid)
            if not handle:
                proc.kill();proc.communicate()
                raise OSError(C.get_last_error(),'OpenProcess')
            samples=[]
            peak_working_set=peak_private=0
            try:
                while True:
                    counters=Counters();counters.cb=C.sizeof(counters)
                    if psapi.GetProcessMemoryInfo(handle,C.byref(counters),counters.cb):
                        peak_working_set=max(peak_working_set,counters.peak_working_set)
                        peak_private=max(peak_private,counters.private)
                        samples.append(dict(seconds=round(time.monotonic()-started,3),working_set_bytes=counters.working_set,private_bytes=counters.private))
                    try:
                        stdout,stderr=proc.communicate(timeout=0.2)
                        break
                    except subprocess.TimeoutExpired:
                        if time.monotonic()-started>args.timeout:
                            proc.kill();stdout,stderr=proc.communicate()
                            raise TimeoutError('Sustained pixel verification timed out')
            finally:
                kernel.CloseHandle(handle)
            expected=f'Verified frames={300*repetitions} samples={files.sample_count(case)*300*repetitions} '
            if proc.returncode or not stdout.startswith(expected) or not samples:
                raise RuntimeError(f'Memory run failed: {stdout}\n{stderr}')
            report['runs'].append(dict(target=target,repetitions=repetitions,artifact_sha256=artifact['sha256'],
                                       peak_working_set_bytes=peak_working_set,peak_sampled_private_bytes=peak_private,
                                       elapsed_seconds=time.monotonic()-started,output=stdout,samples=samples))
            args.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
            print(f'{target}: peak working set {peak_working_set/1048576:.1f} MiB, sampled private {peak_private/1048576:.1f} MiB',flush=True)


if __name__=='__main__': main()
