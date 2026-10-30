# Reference test suites

This package contains generated black-box reference tests whose expected
values come from independent implementations such as libaom, dav1d, libavif,
FFmpeg and LittleCMS. Fixture provenance, source hashes, tool versions and
license notices remain under [`tests/fixtures`](../fixtures).

## Why the suite is split

MoonBit treats one directory as one package:

- `*_test.mbt` files are black-box tests. They can live in this package and use
  the public API through [`facade.mbt`](facade.mbt).
- `*_wbtest.mbt` files are white-box tests. They must remain next to the root
  package implementation because they access private declarations. Moving them
  here would require making decoder internals public, so those files stay at the
  repository root by design.

Do not move a root `*_wbtest.mbt` into this directory. If a new independent
reference only uses public API, put its `*_test.mbt` here and add its generator
default path to this directory.

## Run

```sh
moon test --package 0717lee/moonav1/tests/reference --target js
moon test --package 0717lee/moonav1/tests/reference --target wasm-gc
moon test --package 0717lee/moonav1/tests/reference --target native
```

The full module test command still runs these tests together with the root
white-box suites:

```sh
moon test --target js
```

## Suites

| Test | Independent reference | Generator |
| --- | --- | --- |
| `av1_cdef_reference_test.mbt` | libaom CDEF kernels | `scripts/generate-av1-cdef-reference.py` |
| `av1_highbd_reference_test.mbt` | dav1d high-bit-depth planes | retained fixture history |
| `av1_multitile_reference_test.mbt` | libaom streams, dav1d planes | `scripts/generate-av1-multitile-reference.py` |
| `av1_reference_test.mbt` | libaom streams, dav1d planes | retained fixture history |
| `av1_transform_reference_test.mbt` | libaom inverse transforms | `scripts/generate-av1-transform-reference.py` |
| `avif_metadata_test.mbt` | libavif metadata fixture | `scripts/generate-extension-reference.py` |
| `container_reference_test.mbt` | FFprobe, dav1d native CRCs | `scripts/generate-container-reference.py` |
| `extension_reference_test.mbt` | libavif, NumPy display transforms | `scripts/generate-extension-reference.py` |
| `rgba16_reference_test.mbt` | Fraction/Decimal RGBA16 oracle | `scripts/generate-rgba16-reference.py` |

The facade is generated from the committed public interface. Refresh it after
an intentional public API change:

```sh
python scripts/generate-reference-facade.py
python scripts/generate-reference-facade.py --check
```
