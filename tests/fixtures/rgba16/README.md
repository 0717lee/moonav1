# RGBA16 independent references

These references add a 16-bit output contract to the existing AV1/AVIF corpus.
Inputs are existing files in `av1-color`, `avif-premultiplied-alpha`,
`av1-monochrome`, `avif-grid-sampling-color` and `avif-grid`; no stream or native reference
in those directories is changed or re-encoded.

The 37 cases contain 55 images: the 14 CICP/nclx cases, all 17 static/animated
prem cases, monochrome at 8/10/12 bits, and odd-crop 10-bit 4:2:2 / 12-bit 4:4:4
grids, plus a 12-bit 4:2:0 color/alpha grid. The original fixture directories
retain their provenance and manifests.

## Primary numeric oracle

`generate-rgba16-reference.py` reads the saved independent native planes. It
uses Python Fraction arithmetic to solve forward color matrices and preserve
native alpha. Nonlinear transfer curves use 80-digit Decimal arithmetic;
ICtCp uses a solve of the normative integer forward matrices, and XYZ uses a
solve from the BT.709 xy primaries and D65 white point. MoonAV1's output,
inverse constants and conversion functions are not used to create expectations.

Each `.rgba16le` holds row-major R/G/B/A unsigned 16-bit little-endian samples,
normalized to 0..65535, with straight alpha. Chroma uses nearest replication.
Source primaries/transfer are retained, except XYZ is converted to BT.709/sRGB.
Limited alpha expands and rounds at source depth before UNORM16 scaling.
Premultiplication is undone with native alpha before final RGB quantization.

Tests permit at most one UNORM16 unit of RGB difference between the Double
implementation and the independent numeric reference. Alpha must be exact.
This does not loosen the native YUV/alpha zero-difference requirement.

## Independent libavif comparison

Generation also uses libavif 0.11.1, built without libyuv. Each complete
container is redecoded, geometry/range/prem/color metadata is checked, and every
native color/alpha sample must equal its existing saved reference. RGBA output
is separately requested at depth 16, avoidLibYUV=1, chromaUpsampling=3,
alphaPremultiplied=0, using the version-checked public ABI.

`.libavif.rgba16le` files preserve the actual independent converter output.
`manifest.json` records its status and maximum difference from the primary
oracle for each frame. The six unsupported color conversions have no such
file; their mathematical references remain available.

libavif's matrix-6 prem path quantizes RGB16 and alpha16 before unpremultiplying.
That ordering differs from this API's native-alpha contract, with differences
up to 721 units in these deliberately low-alpha samples. The other supported
libavif comparisons differ by at most one unit. These are separately recorded
comparisons, not substituted expectations or relaxed limits for MoonAV1.

Definitions and independent implementation references:

- [H.273 (07/2024), Tables 2–4 and color/range equations](https://www.itu.int/rec/T-REC-H.273-202407-I/en)
- [zimg forward matrices and xy-derived coefficients](https://github.com/sekrit-twc/zimg/blob/master/src/zimg/colorspace/colorspace_param.cpp)
- [libavif 0.11.1 conversion dispatch and quantization](https://github.com/AOMediaCodec/libavif/blob/v0.11.1/src/reformat.c)

## Reproduction

From the repository root, the first command checks the numeric references and
embedded tests without an external codec. The second also redecodes containers
and verifies saved libavif output. Both check modes are read-only:

```sh
python scripts/generate-rgba16-reference.py --check
python scripts/generate-rgba16-reference.py --check --libavif /path/to/avif.dll
```

To generate only this new reference directory and `rgba16_reference_test.mbt`,
omit `--check` and provide the recorded libavif version. Python's standard
library and `moonfmt` are required for generation/checking; ordinary MoonBit
tests require neither Python nor an external codec.
