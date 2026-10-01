#!/usr/bin/env python3
"""Process-isolated deterministic malformed-input campaign on local artifacts.

Mutations may still be legal streams: accepted/rejected are both permitted,
but crash, timeout, or a broken output invariant fails the campaign. This is
a bounded regression campaign, not a fuzzing completeness or conformance claim.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import random
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('robust_bench', Path(__file__).with_name('benchmark.py'))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
SEEDS = [
    ('av1', 'av1-palette/color_64x64_10bit_3colors.obu'),
    ('video', 'av1-obu-assembly/hidden_inter_show_existing.obu'),
    ('av1', 'av1-superres/stock_color_10bit_d16_97x65_1tile.obu'),
    ('avif', 'avif-grid/alpha_grid_grid_12bit.avif'),
    ('animation', 'avif-premultiplied-alpha/animation_matrix6_12bit.avif'),
    ('chunks', 'av1-obu-assembly/hidden_inter_show_existing.obu'),
    ('metadata', 'extensions/metadata_12_r1_m0.avif'),
    ('lazy-animation', 'extensions/metadata_10_r3_m1_animation.avif'),
    ('container', 'av1-containers/reorder_prefix8_10bit_320x180.ivf'),
    ('container', 'av1-containers/reorder_prefix8_10bit_320x180.mp4'),
    ('container', 'av1-containers/reorder_prefix8_10bit_320x180.fragmented.mp4'),
    ('container', 'av1-containers/reorder_prefix8_10bit_320x180.webm'),
    ('icc', 'color-display/matrix_rgb_v4.icc'),
    ('icc', 'color-display/mft1_rgb_v4.icc'),
    ('container-stream', 'av1-containers/reorder_prefix8_10bit_320x180.ivf'),
    ('container-stream', 'av1-containers/reorder_prefix8_10bit_320x180.mp4'),
    ('container-stream', 'av1-containers/reorder_prefix8_10bit_320x180.fragmented.mp4'),
    ('container-stream', 'av1-containers/reorder_prefix8_10bit_320x180.webm'),
    ('icc-policy', 'icc-policy/all_intents_mab_nonuniform.icc'),
    ('icc-policy', 'icc-policy/gray_v4_d65_all_intents.icc'),
    ('icc-policy', 'icc-policy/lut_v2_all_intents.icc'),
]


def cases():
    for name in ('deep-primary', 'deep-alpha', 'deep-animation', 'deep-metadata', 'deep-lazy-animation'):
        yield name, [name], 'rejected'
    rng = random.Random(0x4D415631)
    for mode, name in SEEDS:
        data = (ROOT / 'tests/fixtures' / name).read_bytes()
        if mode in ('chunks','metadata','lazy-animation','container-stream','icc-policy'):name=mode+'/'+name
        yield name, [mode, data.hex()], 'accepted'
        cuts = sorted({0, 1, 2, 3, 4, 7, 8, len(data) - 1, len(data) // 2,
                       *[rng.randrange(len(data)) for _ in range(24)]})
        for end in cuts:
            yield f'{name}/truncate/{end}', [mode, data[:end].hex()], None
        for index in range(64):
            position = rng.randrange(len(data))
            changed = bytearray(data)
            mask = 1 << rng.randrange(8)
            changed[position] ^= mask
            yield f'{name}/flip/{position}/{mask}', [mode, changed.hex()], None
        for value in (0, 255):
            for position in sorted({0, 1, 2, 3, 4, 7, 8, len(data) // 2, len(data) - 1}):
                changed = bytearray(data)
                changed[position] = value
                yield f'{name}/replace/{position}/{value}', [mode, changed.hex()], None
    for index in range(32):
        data = bytes(rng.randrange(256) for _ in range(index * 7))
        for mode in ('av1', 'avif', 'animation', 'chunks', 'metadata', 'lazy-animation', 'container', 'icc', 'container-stream', 'icc-policy'):
            yield f'random/{index}/{mode}', [mode, data.hex()], None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--targets', nargs='+', choices=bench.TARGETS, default=list(bench.TARGETS))
    parser.add_argument('--target-dir', default='_build/robustness')
    parser.add_argument('--output', type=Path, default=ROOT / 'benchmarks/results/robustness.json')
    parser.add_argument('--timeout', type=float, default=10)
    parser.add_argument('--only', help='case-name substring for reproducing a failure')
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    selected = [case for case in cases() if args.only is None or args.only in case[0]]
    if not selected:
        parser.error('No selected cases')
    source = [p for p in ROOT.glob('*.mbt') if not p.stem.endswith(('_test', '_wbtest'))]
    report = dict(created_utc=datetime.now(timezone.utc).isoformat(),
                  source_sha256=bench.digest(source + [ROOT / 'moon.mod', ROOT / 'moon.pkg']),
                  moon_version=bench.run(['moon', 'version', '--all']).stdout.strip(),
                  git_head=bench.run(['git', 'rev-parse', 'HEAD']).stdout.strip(),
                  harness_sha256=bench.digest(list((ROOT / 'tests/robustness').glob('*.mbt')) + [ROOT / 'tests/robustness/moon.pkg', Path(__file__).resolve()]),
                  seed_sha256={name: bench.sha256(ROOT / 'tests/fixtures' / name) for _, name in SEEDS},
                  cases=len(selected), timeout_seconds=args.timeout, artifacts={}, targets={})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for target in args.targets:
        print(f'Building {target}...', flush=True)
        built = bench.run(['moon', 'run', 'tests/robustness', '--frozen', '--release', '--target', target,
                          '--target-dir', args.target_dir, '--build-only', '--output-json'])
        artifacts = [json.loads(line)['artifacts_path'] for line in built.stdout.splitlines()
                     if line.startswith('{') and '"artifacts_path"' in line]
        if len(artifacts) != 1 or len(artifacts[0]) != 1:
            raise SystemExit('Unexpected artifact result')
        path = Path(artifacts[0][0]).resolve()
        report['artifacts'][target] = dict(path=path.relative_to(ROOT).as_posix(), sha256=bench.sha256(path))
    failed = False
    for target in args.targets:
        path = ROOT / report['artifacts'][target]['path']
        counts = dict(accepted=0, rejected=0, failed=0)
        details = []
        started = time.monotonic()
        for index, (name, arguments, expected) in enumerate(selected):
            try:
                run = subprocess.run(bench.command(target, path, arguments), cwd=ROOT, capture_output=True,
                                     text=True, encoding='utf-8', timeout=args.timeout)
                status = run.stdout.strip()
                if run.returncode or status not in ('accepted', 'rejected') or (expected and status != expected):
                    details.append(dict(case=name, exit_code=run.returncode, stdout=run.stdout[-2000:], stderr=run.stderr[-4000:]))
                    status = 'failed'
            except subprocess.TimeoutExpired:
                details.append(dict(case=name, status='timeout'))
                status = 'failed'
            counts[status] += 1
            if status == 'failed':
                break
            if (index + 1) % 100 == 0:
                print(f'{target}: {index + 1}/{len(selected)}, failures={counts["failed"]}', flush=True)
        report['targets'][target] = dict(counts=counts, failures=details,
                                        executed=sum(counts.values()),
                                        elapsed_seconds=time.monotonic() - started)
        args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print(f'{target}: {counts}', flush=True)
        failed |= counts['failed'] != 0
        if failed:
            break
    if failed:
        raise SystemExit('Robustness campaign found failures; see the saved report')


if __name__ == '__main__':
    main()
