# ICC input profiles

`IccProfile::parse(bytes)` checks the structure and supported transforms of an
ICC v2 or v4 profile. It is not a full ICC profile conformance validator. A
parsed profile can be applied to straight RGBA images with
`profile.apply_rgba8(image)` or `profile.apply_rgba16(image)`. Both methods
retain their historical relative-colorimetric, no-BPC policy. The explicit
`apply_rgba8_with_options` and `apply_rgba16_with_options` entry points accept
an `IccTransformOptions` value and return a newly allocated image. All entry
points copy alpha byte-for-byte/sample-for-sample. The conversion is pure
MoonBit and has no host or runtime fallback.

The supported profile classes are scanner (`scnr`) and display (`mntr`) RGB
and Gray profiles. Matrix/TRC profiles require XYZ PCS; Lab PCS requires a
supported A2B LUT. The following transform forms are supported:

- RGB matrix profiles with `rXYZ`, `gXYZ`, `bXYZ`, and their `rTRC`, `gTRC`,
  `bTRC` tags.
- Gray matrix profiles with `wtpt` and `kTRC`.
- Input LUTs using `mft1`, `mft2`, or `mAB` tag data, with one or three input
  channels and three output channels. `mAB` CLUTs retain the independently
  declared grid count for every input dimension (2–65 points per dimension,
  with at most 274,625 expanded cells) and use the ICC channel order during
  interpolation.
- Supported LUT forms include `mft1` with Lab PCS, `mft2` with XYZ and Lab
  PCS, and ICC v4 `mAB`.
- The default policy is relative colorimetric without black-point compensation.
  `A2B1` is selected when present; only its absence permits fallback to `A2B0`.
  A selected malformed/unsupported table is an error. The header's preferred
  intent is not used. The options entry points select the actual ICC intent
  table: perceptual uses `A2B0`, relative uses `A2B1` with the historical
  `A2B0` fallback, saturation uses `A2B2` with the ICC perceptual fallback,
  and absolute colorimetric uses the same relative input table followed by
  fully adapted media-white scaling. Fixed-point ICC input profiles map
  absolute intent to the relative `A2B1` table; an `A2B3` tag is not used by
  this input path. Missing tables use the stated A2B0 fallback and then an
  available matrix/TRC transform. If neither exists, the requested intent
  returns `DecodeErrorKind::Unsupported`; malformed selected data returns its checked
  `InvalidData`/`Unsupported` parse error. The implementation does not relabel
  one intent as another. Matrix/TRC profiles expose their validated matrix
  pipeline for all four meaningful intent choices because no profile LUT is
  available to replace it.
- Black-point compensation uses the actual input black transform: RGB/Gray
  zero samples are converted to Lab, a*/b* are preserved, and L* is clipped
  to the LittleCMS range before conversion back to PCS XYZ. A v4 LUT's
  perceptual/saturation black uses the ICC constants; v4 matrix/Gray uses its
  actual black. Relative BPC is available without a `bkpt` tag. The affine
  PCS mapping preserves D50 white, does not clamp intermediate XYZ values, and
  rejects a zero/invalid denominator. Absolute BPC is unsupported; v4
  perceptual/saturation normalization is applied even when the option is
  false. The fixed sRGB destination is v4, so this normalization also applies
  to v2 sources, matching LittleCMS's public transform policy. Absolute
  conversion uses the fully adapted white ratio; v2 display media white is
  D50. Gray is normalized to D50 before absolute scaling or compensation.
- `mft1` with XYZ PCS is rejected because ICC defines its 8-bit PCS XYZ
  interpretation as implementation-specific. `mft1` Lab and `mft2` XYZ/Lab
  remain supported. The fixed matrix in supported mft LUTs must be identity;
  non-identity matrices are returned as unsupported.
- LUT stages follow the ICC order: input curves, CLUT, optional M curves and
  matrix, then output B curves. CLUT dimensions use the ICC order where the
  first input dimension varies least rapidly; a nonuniform mAB grid uses the
  corresponding dimension's spacing for each interpolation coordinate.
  RGB CLUTs use tetrahedral interpolation; Gray CLUTs use linear interpolation.
- Sampled `curv` curves and ICC parametric curves of function types 0 through
  4. Matrix/TRC and LUT curves are evaluated in normalized ICC domains.
- XYZ PCS output, or Lab PCS output decoded using the ICC D50 Lab encoding.
  PCS XYZ is Bradford-adapted from D50 (or a Gray profile's declared media
  white) to D65 and encoded as display sRGB.
- PCS XYZ LUT values use ICC's `u1.15` encoding (`1.0` is `0x8000`), while
  the LUT table storage itself is 8- or 16-bit. The implementation expands
  this encoding before adaptation.
- `mft2`/`lut16Type` Lab PCS output uses the legacy `0xFF00` nominal 16-bit
  maximum in both v2 and v4 ICC profiles, as required by ICC.1:2010 Tables 39
  and 40. The parser converts this legacy Lab domain before Lab-to-XYZ
  conversion, retaining `0x8000` as the exact neutral a*/b* value.
- v4 `mAB` Lab output follows the current normalized PCS Lab domain (`0xFFFF`
  storage scale); v2 `mAB` is rejected.

Profiles with printer (`prtr`), device-link (`link`), abstract, color-space,
named-color, n-component, or other unsupported classes are rejected with
`DecodeErrorKind::Unsupported`. Missing tags, bad offsets, invalid lengths,
truncated tables, and malformed curve/LUT data return a checked decode error;
the parser never indexes outside the declared profile size.

The parser accepts at most 64 MiB of profile data and 4096 tags. Additional
caps are 65 grid points per dimension, 274,625 CLUT cells, one or three input
channels, three output channels, and 65536 entries per sampled curve. A
transform has at most nine curves plus one CLUT, bounding expanded numeric
tables to 1,413,699 `Double` values even when stage offsets alias the same
stored data. These are structural limits, not a guarantee of a particular
runtime heap size. mAB relative offsets must be four-byte aligned and remain
inside the tag.

Only the default relative pipeline is expanded while parsing. The profile
retains an owned copy of its bounded input bytes. An alternate intent is
expanded only for the call that requests it; the same table reuses the default
pipeline. A call can therefore retain at most two expanded pipelines
(2,827,398 numeric table values), rather than expanding every intent at parse
time. Allocator overhead, output images and small evaluation arrays are
additional. Malformed unselected tables are diagnosed when selected.

The independent [color-display corpus](../tests/fixtures/color-display/README.md)
records the LittleCMS relative-colorimetric output and a separate perceptual
comparison for each profile. Accepted RGB channels are checked with tolerance
8 in the generated public-API reference tests; alpha is copied exactly. The
corpus uses synthetic/project-owned profiles and LittleCMS's public ABI for
the independent transform outputs; it contains no installed HP, Agfa or
printer profile.

The API converts straight pixels. It does not undo premultiplication, apply
HDR tone mapping, or infer a profile from nclx/CICP. Perceptual and saturation
mapping are performed only when the profile supplies the corresponding actual
LUT; the library does not synthesize a gamut map from a relative table. For
v4 LUT profiles, the ICC perceptual/saturation black normalization is applied
as part of those actual transforms even when the BPC option is false.
For a Gray profile, the red component is the encoded gray sample and the
source green/blue components are ignored. Relative matrix/TRC output is
neutral gray; an absolute media-white transform can produce a color cast.
HDR, printer, device-link, nCLR, named-color, and output-only workflows remain
outside this contract and must be rejected or handled by a caller that has the
appropriate color-management policy.

The implementation follows the public ICC profile/tag definitions in the
International Color Consortium specifications:

- ICC.1:2010 (Profile version 4.3.0.0), sections 6.3.4.2 and tables 39–40
  for PCS Lab encoding, plus sections 7.2–10 for the header, tag table,
  XYZ/curve/parametric types, and LUT tag types.
- ICC.1:2004-10 (Profile version 4.2.0.0), sections 7.2, 8.2, 10.7, and
  10.15 for v4 header fields, PCS XYZ/Lab encoding, and `mAB`/`mft1`/`mft2`.
- ICC.1:1998-09 (Profile version 2.4.0), sections 5 and 6 for v2 matrix/TRC
  profiles and the v2 curve encoding.

The primary ICC references are published by the International Color
Consortium at [ICC.1:2010](https://www.color.org/specification/ICC1v43_2010-12.pdf),
[ICC.1:2004-10](https://www.color.org/specification/ICC1v42_2006-05.pdf), and
[the current specification index](https://www.color.org/specifications/).

The independent policy corpus uses the LittleCMS 2.19 public ABI documented in
[`lcms2.h`](https://github.com/mm2/Little-CMS/blob/master/include/lcms2.h):
`cmsCreateTransform`, `cmsDoTransform`, intent constants 0–3,
`cmsFLAGS_COPY_ALPHA`, `cmsFLAGS_NOOPTIMIZE`, and
`cmsFLAGS_BLACKPOINTCOMPENSATION`. The new policy corpus evaluates profile
stages directly; LittleCMS's optimized composite-LUT outputs are retained
separately as diagnostics. The older color-display corpus is unchanged.
RGB tolerance remains 8 UInt16 codes and alpha is exact. LittleCMS's
public transform path and the `transicc` reference utility are retained as
the independent oracle; private CMM symbols are not called by the generator.
The policy math follows the public-source behavior in
[`cmsio1.c`](https://raw.githubusercontent.com/mm2/Little-CMS/lcms2.19/src/cmsio1.c),
[`cmscnvrt.c`](https://raw.githubusercontent.com/mm2/Little-CMS/lcms2.19/src/cmscnvrt.c),
and [`cmssamp.c`](https://raw.githubusercontent.com/mm2/Little-CMS/lcms2.19/src/cmssamp.c)
(LittleCMS 2.19), including fixed-point intent fallback, fully adapted
absolute scaling, and black-point detection.

The profile is deliberately kept immutable after parsing. Application output
is independent for each call, so modifying one returned image does not modify
the source image, the profile, or another result.
