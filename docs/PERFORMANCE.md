# Reproducible benchmarks

`scripts/benchmark.py` builds the public consumer and measures steady-state
decode or RGBA16 conversion. Build time, process startup, fixture preparation
and correctness checks are outside the timed section. Each report records
the toolchain, inputs, source, executable and timing samples.

```sh
python scripts/benchmark.py --suite api --targets native js wasm-gc --label current --repetitions 3 --output _build/api-benchmark.json
python scripts/fetch-fixtures.py av1-large-images av1-stream
python scripts/benchmark.py --suite large --label large --output _build/large-benchmark.json
python scripts/benchmark.py --suite stream --label stream --output _build/stream-benchmark.json
```

The `api` suite covers public decoding and native-to-RGBA16 conversion; `large`
covers 512x384 still images and 640x360 video; `stream` covers a 12-bit HD still
and 32 reordered 10-bit video presentations. Their verification-only modes are:

```sh
moon run benchmarks/large --release --target js -- --verify-only
moon run benchmarks/stream --release --target js -- --verify-only
```

Use `--case` to select a fixture and `--build-only` to preserve artifacts without
timing. `--compare-with` alternates the recorded baseline and current artifacts
on the same selected inputs. Preserve baseline artifacts from an isolated
checkout of the revision being compared.

File-backed pixel verification also measures I/O and reference comparison, so
its elapsed times are not decoder-only benchmarks. `check-stream-memory.py`
consumes an explicit file-verification report via `--artifacts` and records
process memory separately. Stream pending-byte counters describe compressed
input retention and are not process heap limits.
