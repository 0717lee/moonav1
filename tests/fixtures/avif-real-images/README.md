# Real AVIF image corpus

This directory contains seven compact, single-frame AVIF files exported from
real image inputs or a browser-rendered page. `manifest.json` is the canonical
record of dimensions, native format, source SHA-256, attribution, license,
transform, export options, tool versions, and artifact hashes.

The real photographic inputs are:

- `portrait_astronaut_512`: NASA astronaut photograph, public domain, from the
  locally installed scikit-image data asset.
- `food_coffee_600x400`: Rachel Michetti / Pikolo Espresso Bar photograph,
  CC0, from the locally installed scikit-image data asset.
- `landscape_sunset_640x480`: Michae2109's Oslo sunset photograph, released
  worldwide into the public domain on Wikimedia Commons.
- `street_vendor_640x480`: Kumar Mangal Roy's Kolkata street-vendor
  photograph, CC0 on Wikimedia Commons.
- `wide_gamut_adobe_600x400`: the same NASA astronaut source as the portrait
  case, converted from its embedded sRGB profile to the retained CC0
  AdobeCompat-v2 RGB profile with LittleCMS before AVIF export. The original
  PNG, input sRGB ICC, converted PNG, and target ICC are all retained.

`transparent_window_icon_512` is an original CC0 SVG rendered to a transparent
PNG by Playwright; its alpha plane is independently retained. The webpage case
is an original static HTML/CSS page rendered at 768x512 by Playwright. Its
manifest entry explicitly marks the pixels as synthetic page content rather
than a photograph. The AdobeCompat-v2 profile is from the CC0
[Compact-ICC-Profiles repository](https://github.com/saucecontrol/Compact-ICC-Profiles).

The fixture contract is file-consumer compatible: every case has
`modes: ["avif"]`, `frames: 1`, and a tight row-major native Y/U/V reference in
`<name>.reference.yuv`; the transparent case also has
`<name>.alpha.yuv`. Eight-bit samples are one byte each; higher-depth samples,
if added, must be little-endian unshifted uint16 samples. The reference is
decoded from the saved AVIF with actual libavif 0.11.1 and is not produced by
MoonAV1.

The generator is intentionally bounded and local:

```powershell
python scripts/generate-real-image-reference.py --check
python scripts/generate-real-image-reference.py --redecode --libavif D:\ProgramData\anaconda3\Library\bin\avif.dll
```

`--check` only reads the manifest and artifacts. `--redecode` adds an actual
libavif native-plane, alpha, metadata, and embedded-ICC comparison. Generation
refuses to replace a completed corpus. The three-backend consumer check is
run by the parent harness, for example:

```powershell
python scripts/check-file-fixtures.py --manifest tests/fixtures/avif-real-images/manifest.json --targets native
```

The wide-gamut case also retains `icc-reference.json`, independently decoded
libavif RGBA16 pixels and LittleCMS 2.19 relative-colorimetric sRGB output.
The consumer checks conversion from the actual AVIF and ICC application to the
exact independent input separately. RGB16 allows at most 1 UNORM16 code unit,
ICC RGB at most 8, and alpha is exact; the earlier precision contracts remain.

```powershell
python scripts/generate-real-image-color-reference.py --check --libavif D:\ProgramData\anaconda3\Library\bin\avif.dll
python scripts/check-file-fixtures.py --manifest tests/fixtures/avif-real-images/manifest.json --icc-reference tests/fixtures/avif-real-images/icc-reference.json --target-dir _build/slop-verify
```
