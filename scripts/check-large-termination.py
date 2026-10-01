#!/usr/bin/env python3
"""Check preserved/current large-video artifacts with a process deadline.

This records termination and exact-pixel verification, not benchmark speedups.
Only the child launched by this check is terminated when its deadline expires.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('large_bench', Path(__file__).with_name('benchmark.py'))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path)
    parser.add_argument('--after', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=20)
    args = parser.parse_args()
    if (not args.before and not args.after) or args.timeout <= 0:
        parser.error('Provide at least one artifact report and a positive timeout')
    results = {'fixture': 'video_10bit_640x360', 'deadline_seconds': args.timeout, 'runs': []}
    failed = False
    for role, source in [('before', args.before), ('after', args.after)]:
        if source is None:
            continue
        record = json.loads(source.read_text(encoding='utf-8'))
        for target, artifact in record['artifacts'].items():
            path = ROOT / artifact['path']
            if bench.sha256(path) != artifact['sha256']:
                raise SystemExit(f'Artifact changed: {path}')
            started = time.monotonic()
            try:
                proc = subprocess.run(bench.command(target, path,
                    ['--verify-only', results['fixture']]), cwd=ROOT, capture_output=True,
                    text=True, encoding='utf-8', timeout=args.timeout)
                verified = 'Verified video_10bit_640x360: 4 frame(s), exact native pixels' in proc.stdout
                status = 'passed' if proc.returncode == 0 and verified else 'failed'
                output = proc.stdout + proc.stderr
            except subprocess.TimeoutExpired:
                status, output = 'timeout', ''
            elapsed = time.monotonic() - started
            results['runs'].append({'role': role, 'target': target, 'status': status,
                'elapsed_seconds': elapsed, 'source_sha256': record['source_sha256'],
                'artifact_sha256': artifact['sha256'], 'output': output})
            print(f'{role} {target}: {status} ({elapsed:.3f} seconds)', flush=True)
            if role == 'after' and status != 'passed':
                failed = True
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2) + '\n', encoding='utf-8')
    if failed:
        raise SystemExit('Current large-video verification did not pass within the deadline')


if __name__ == '__main__':
    main()
