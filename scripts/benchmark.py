#!/usr/bin/env python3
"""Build and measure the public API benchmark sequentially on three backends.

--compare-with alternates fresh runs of preserved baseline/current artifacts.
Builds, process startup, fixture preparation and pixel checks are not timed.
No dependencies are downloaded and no result is uploaded.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TARGETS = ('native', 'js', 'wasm-gc')
SUITES = {
    'api': ('benchmarks', 'scripts/generate-benchmark-fixtures.py', 10),
    'large': ('benchmarks/large', 'scripts/generate-large-reference.py', 5),
    'stream': ('benchmarks/stream', 'scripts/generate-stream-reference.py', 5),
}


def run(command):
    result = subprocess.run(command, cwd=ROOT, capture_output=True,
                            text=True, encoding='utf-8')
    if result.returncode:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit(f'Command failed ({result.returncode}): {command[0]}')
    return result


def digest(paths):
    value = hashlib.sha256()
    for path in sorted(paths):
        value.update(path.relative_to(ROOT).as_posix().encode())
        value.update(b'\0')
        value.update(path.read_bytes())
        value.update(b'\0')
    return value.hexdigest()


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def command(target, path, args=()):
    if target == 'js':
        return ['node', str(path), *args]
    if target == 'wasm-gc':
        return ['moonrun', str(path), *(['--', *args] if args else [])]
    return [str(path), *args]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--target-dir', default='_build/benchmark')
    parser.add_argument('--targets', nargs='+', choices=TARGETS, default=list(TARGETS))
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--machine', default=platform.processor())
    parser.add_argument('--compare-with', type=Path)
    parser.add_argument('--suite', choices=SUITES, default='api')
    parser.add_argument('--case', action='append', default=[], help='select a named large/stream fixture (repeatable)')
    parser.add_argument('--build-only', action='store_true', help='save artifacts/identity without timing')
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error('--repetitions must be positive')
    if args.case:
        if args.suite not in ('large', 'stream'):
            parser.error('--case is available for the large and stream suites')
        corpus = 'av1-large-images' if args.suite == 'large' else 'av1-stream'
        known = {c['name'] for c in json.loads((ROOT / f'tests/fixtures/{corpus}/manifest.json').read_text())['cases']}
        if set(args.case) - known:
            parser.error('Unknown fixture name')
    package, generator, batches = SUITES[args.suite]
    run([sys.executable, generator, '--check'])
    harness_files = [p for p in (ROOT / package).glob('*.mbt')
                     if not p.stem.endswith(('_test', '_wbtest'))]
    harness = digest(harness_files + [ROOT / package / 'moon.pkg'])
    sources = [p for p in ROOT.glob('*.mbt') if not p.stem.endswith(('_test', '_wbtest'))]
    report = {
        'label': args.label,
        'suite': args.suite,
        'cases': args.case,
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'machine': args.machine,
        'platform': platform.platform(),
        'moon_version': run(['moon', 'version', '--all']).stdout.strip(),
        'node_version': run(['node', '--version']).stdout.strip() if 'js' in args.targets else None,
        'git_head': run(['git', 'rev-parse', 'HEAD']).stdout.strip(),
        'source_sha256': digest(sources + [ROOT / 'moon.mod', ROOT / 'moon.pkg']),
        'harness_sha256': harness,
        'unit': 'microseconds per operation',
        'sampling': f'core/bench: adaptive warmup >100ms, {batches} batches, 5% winsorization',
        'artifacts': {},
        'runs': [],
    }
    baseline = None
    if args.compare_with:
        baseline = json.loads(args.compare_with.read_text(encoding='utf-8'))
        if baseline['harness_sha256'] != harness:
            parser.error('Baseline used a different benchmark harness')
        report['baseline'] = {k: baseline[k] for k in (
            'label', 'source_sha256', 'harness_sha256', 'moon_version', 'artifacts')}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    log_dir = ROOT / args.target_dir
    log_dir.mkdir(parents=True, exist_ok=True)
    # Build first, then measure one process at a time. Parsing artifacts_path
    # keeps the runner independent of Moon's backend output directory layout.
    for target in args.targets:
        print(f'Building {target} (release)...', flush=True)
        built = run(['moon', 'run', package, '--frozen', '--release', '--target', target,
                     '--target-dir', args.target_dir, '--build-only', '--output-json'])
        (log_dir / f'build-{target}.log').write_text(
            built.stdout + built.stderr, encoding='utf-8')
        artifacts = [json.loads(line)['artifacts_path'] for line in built.stdout.splitlines()
                     if line.startswith('{') and '"artifacts_path"' in line]
        if len(artifacts) != 1 or len(artifacts[0]) != 1:
            raise SystemExit(f'Unexpected Moon artifact output for {target}')
        path = Path(artifacts[0][0]).resolve()
        report['artifacts'][target] = {
            'path': path.relative_to(ROOT).as_posix(), 'sha256': sha256(path)}
        if baseline:
            old = baseline['artifacts'][target]
            if sha256(ROOT / old['path']) != old['sha256']:
                raise SystemExit(f'Baseline artifact changed: {old["path"]}')
    if args.build_only:
        args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print(f'Saved build identity: {args.output}')
        return
    for target in args.targets:
        for repetition in range(args.repetitions):
            variants = [('current', report)]
            if baseline:
                variants.append(('baseline', baseline))
                if repetition % 2 == 0:
                    variants.reverse()
            for variant, source in variants:
                print(f'Measuring {target} {variant} {repetition + 1}/{args.repetitions}...', flush=True)
                path = ROOT / source['artifacts'][target]['path']
                result = json.loads(run(command(target, path, args.case)).stdout)
                if not result or any(s['median'] <= 0 or s['runs'] != batches for s in result):
                    raise SystemExit('Invalid benchmark summaries')
                report['runs'].append({'target': target, 'variant': variant,
                                       'repetition': repetition + 1, 'summaries': result})
                args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    for target in args.targets:
        current = [r for r in report['runs'] if r['target'] == target and r['variant'] == 'current']
        previous = [r for r in report['runs'] if r['target'] == target and r['variant'] == 'baseline']
        for index, summary in enumerate(current[0]['summaries']):
            value = statistics.median(r['summaries'][index]['median'] for r in current)
            delta = ''
            if previous:
                before = statistics.median(r['summaries'][index]['median'] for r in previous)
                delta = f', {100 * (value / before - 1):+.1f}% vs baseline'
            print(f'{target} {summary["name"]}: {value:.3f} us{delta}')
    print(f'Saved {args.output}')


if __name__ == '__main__':
    main()
