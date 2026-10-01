# Validation and optional media corpora

Use the pinned `moonc 0.10.14+7d59c7ec9` toolchain. The ordinary test suite
embeds independent references and needs no codec installation or media download:

```sh
moon check --target js
moon build --target js
moon test --target js
```

Repeat with `--target wasm-gc` and `--target native`; native needs a C compiler.
CI runs all three targets and the five public examples. The test suite includes
large-image and reordered-video public API regressions under `benchmarks/`.

## Restore optional files

Larger file-consumer tests retain unchanged encoded media and independent native
pixels in the `v0.2.0` release assets. Git tracks their manifests and licenses.
The Python standard-library downloader checks every archive part and restores
files beneath the chosen fixture root without replacing repository metadata.

```sh
python scripts/fetch-fixtures.py --list
python scripts/fetch-fixtures.py av1-large-images av1-stream
python scripts/fetch-fixtures.py avif-real-images
python scripts/fetch-fixtures.py all --cache /path/with/free/space
```

All groups require roughly 7.5 GiB unpacked plus download/assembly space. The
three-minute video has a native reference larger than 4 GiB. Individual groups
can be downloaded separately. `--archive-dir` uses existing release assets
offline; `--root` chooses a separate extraction directory.

## File consumers

The library itself performs no host I/O. `tests/file_decode` and
`tests/container_decode` provide native, JavaScript and wasm-gc file adapters
for exact comparison with saved independent pixels. The wrappers need Python
and Node.js for their JS/Wasm host adapters.

```sh
python scripts/check-file-fixtures.py --manifest tests/fixtures/avif-real-images/manifest.json --targets native js wasm-gc --output _build/real-images.json
python scripts/fetch-fixtures.py av1-realvideo av1-long-containers
python scripts/check-long-containers.py --targets native js wasm-gc --output _build/long-containers.json
python scripts/check-robustness.py --output _build/robustness.json
```

`check-long-containers.py --standalone --chunk-seed 20260927` exercises independent
consumers and varied chunk boundaries. `--case` and `--modes complete stream`
select subsets. The diverse-video manifest also covers SVT-AV1, rav1e, AMD AMF,
PQ/HLG, VFR and long video. Source credits and exact scope are in each manifest.

## Independent references

RGBA16 numeric references allow at most one UInt16 RGB step and exact alpha.
ICC references retain the existing eight-step RGB bound and exact alpha.
Native plane comparisons are exact. The saved expected output never comes
from MoonAV1 itself. Reference generators document their own external tool
requirements; the color checks use LittleCMS 2.19, and container-record checks
use ffprobe. Read each generator's help before regeneration: some older
`--check` modes also write generated test source.

Generated reports go under `_build/` or the ignored `benchmarks/results/`.
They are measurements for the recorded source, toolchain and inputs, rather
than permanent performance claims. See [benchmarking](PERFORMANCE.md).
