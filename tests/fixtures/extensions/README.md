# Caller extension references

Nine locally generated libavif 0.11.1 containers cover 8/12-bit static images
with all four rotations and both mirror modes, and a 10-bit three-frame
color/alpha animation with a second independent key sample. Every input carries
an ICC profile, Exif, XMP, square pixel aspect ratio and crop/rotation/mirror
properties. The crops include a negative horizontal center offset.

`scripts/generate-extension-reference.py` owns generation and test/example
embedding. The content is original synthetic data; ICC is generated locally by
LittleCMS through Pillow, and Exif/XMP are constructed explicitly in the script.
No external photograph or MoonAV1 output supplies expected pixels.

The version-checked libavif ABI independently extracts metadata and decodes
all native color/alpha samples. The established Fraction color oracle computes
RGBA16 with native alpha before final quantization. Actual libavif RGBA16 bytes
are also retained, with their maximum difference in the manifest: its low-alpha
quantization order can differ. RGB acceptance remains at most one UNORM16 step
against the independent numerical oracle; alpha and native samples are exact.

libavif independently resolves the `clap` rectangle. NumPy slicing, `rot90` and
`flip` construct display references in crop/rotation/mirror order. This does not
reuse MoonAV1's composed coordinate map. The complete sample set exercises 11
decoded pictures, including all color/alpha planes and displayed RGBA16 channels.

```sh
python scripts/generate-extension-reference.py --check
python scripts/generate-extension-reference.py --verify --libavif <libavif-0.11.1-library>
moon test extension_reference_test.mbt --target js
moon run examples/extensions --target js
```

`--check` checks saved test/example embedding without loading a codec.
`--verify` reopens the existing containers and compares every saved artifact;
it does not re-encode inputs or rewrite references. `--embed-only` refreshes
only generated MoonBit sources. Default generation and `--rebuild-references`
are explicit write operations for fixture maintenance.

Metadata and display conventions follow the
[libavif public header](https://github.com/AOMediaCodec/libavif/blob/v0.11.1/include/avif/avif.h)
and [metadata reader](https://github.com/AOMediaCodec/libavif/blob/v0.11.1/src/read.c).
