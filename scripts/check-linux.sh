#!/bin/sh
# Run on a local Linux host sharing this checkout. No upload or registry update.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_root"
task_target=_build/extensions-linux-verify
mkdir -p "$task_target"
moon version --all > _build/extensions-linux-version.log
grep -q 'moonc v0.10.14+7d59c7ec9' _build/extensions-linux-version.log
uname -sm > _build/extensions-linux-system.log
gcc --version >> _build/extensions-linux-system.log
if [ "${1:-}" != "--file-only" ]; then
for task_backend in native wasm-gc; do
  moon check --frozen --target "$task_backend" --target-dir "$task_target" > "_build/extensions-linux-check-$task_backend.log" 2>&1
  tail -1 "_build/extensions-linux-check-$task_backend.log"
  moon test --frozen --target "$task_backend" --target-dir "$task_target" > "_build/extensions-linux-test-$task_backend.log" 2>&1
  tail -1 "_build/extensions-linux-test-$task_backend.log"
  moon run examples/extensions --frozen --target "$task_backend" --target-dir "$task_target" > "_build/extensions-linux-example-$task_backend.log" 2>&1
  tail -6 "_build/extensions-linux-example-$task_backend.log"
done
fi

# The same file consumer performs exact comparisons; this is Linux native IO.
moon run tests/file_decode --frozen --release --target native --target-dir "$task_target" --build-only --output-json > _build/extensions-linux-file-build.json 2> _build/extensions-linux-file-build.log
task_executable=$(python3 -c 'import json; rows=[json.loads(line) for line in open("_build/extensions-linux-file-build.json") if line.startswith("{")]; paths=[r["artifacts_path"] for r in rows if "artifacts_path" in r]; assert len(paths)==1 and len(paths[0])==1; print(paths[0][0])')
for task_mode in 0 3 2; do
  MOONAV1_FIXTURE_PREFIX=tests/fixtures/av1-realvideo/bbb_8bit_512x288 \
  MOONAV1_FIXTURE_CONFIG=512,288,8,3,1,1,1,1,1,0,706,$task_mode,0,1,0,0 \
    "$task_executable" > "_build/extensions-linux-video-$task_mode.log" 2>&1
  cat "_build/extensions-linux-video-$task_mode.log"
done
