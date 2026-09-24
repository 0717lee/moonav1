# AV1/AVIF reference generators

These 54 generators and their shared helpers were extracted from PixelForge
commit `6f0c711c54f89d34f3e2ef97cde7a0a45458583d`. The 41 directories under
[`tests/fixtures`](../tests/fixtures) retain all 2,344 tracked evidence files,
including original manifests, encoder inputs, bitstreams, native planes, RGBA
references, syntax traces, oracle C sources, and license notices. See
[`PROVENANCE.md`](../PROVENANCE.md) for the extraction boundary and attribution.

The MoonBit tests embed their expected values, so normal `moon test` and CI do
not require Python, external codecs, or a reference-source cache. Regeneration
is a separate operation. Run generators from the repository root and consult
the corresponding fixture README and manifest for exact tool versions and
commands; different encoder builds need not produce the same bitstream.

## External reference sources

The source caches and exploratory outputs under `_refs/` are not distributed.
Generators that read go-av1 tables expect this checkout:

```sh
git clone https://github.com/mgvs/go-av1 _refs/go-av1
git -C _refs/go-av1 checkout cf2eb172dac31e754243a1c6b756991e229dc1ff
```

The original libaom C kernel oracles use this revision. Keep a Git checkout:
some generators use `git show` to extract unchanged function bodies.

```sh
git clone https://aomedia.googlesource.com/aom _refs/aom
git -C _refs/aom checkout 8e7b6a567df174d795479b92b4ac766d271add73
```

The adapted `--aom-source` and `--source-dir` defaults use `_refs/aom` where
the original generators referenced one developer's temporary checkout.
Generators with a required `--source-dir` still require that argument.
The dav1d C oracles use version `1.2.1`; supply its source checkout with the
generator's `--source-dir` option. Individual source hashes remain pinned in
the generators and manifests.

Encoding and pixel regeneration also require the recorded builds of `aomenc`,
FFmpeg with libdav1d, dav1d CLI, and (for AVIF conversion) libavif. Inter-frame
and restoration-frame generators now discover tools through `PATH` and accept
`--aomenc`, `--ffmpeg`, and/or `--dav1d` overrides. C oracles need a C compiler;
test emitters may need the standalone `moonfmt` executable.

## Historical evidence and relocated paths

Manifests are preserved byte-for-byte. Absolute command paths and PixelForge
names document the original run. [`fixture_paths.py`](fixture_paths.py) maps
manifest paths used as inputs to the same relative location inside MoonAV1;
it does not read the old PixelForge worktree. Historical `_refs/*.mbt` paths
remain prospective outputs under `_refs/`. Generate those outputs when needed
or use a supported `--test` override; no unpublished files are silently copied
into the package.

Source and generated-test hashes record the original generation, including
the original helper scripts. Portability edits can therefore make a historical
source-hash check fail until a deliberate regeneration is reviewed. The
migration preserved fixture bytes; it did not rerun or replace the independent
oracles. A generator's `--check` is not a universal read-only option:
`generate-av1-restoration-frame-reference.py --check` explicitly rewrites its
generated test. Review each command before using it.

Some generated tests use a private `crc32` helper originally located in
PixelForge's `png.mbt`; MoonAV1 retains that helper with its AV1 test support.
The scalar libavif RGBA files and the project's nearest-neighbor color
conversion contracts retain their separate meanings in the manifests.
