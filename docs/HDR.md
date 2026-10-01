# Explicit HDR to SDR conversion

`Av1NativeFrame::to_sdr_rgba16` and `AvifNativeImage::to_sdr_rgba16` convert
native-depth decoded samples directly to straight RGBA16. Existing
`to_rgba16` and RGBA8 conversions keep their previous behavior and do not tone
map HDR content.

The independent [color-display corpus](../tests/fixtures/color-display/README.md)
contains 44 native vectors covering 10-bit and 12-bit PQ (CICP transfer 16) and
HLG (CICP transfer 18) inputs. The generator computes the expected values with
100-digit `Decimal` arithmetic; the generated tests call the public
`to_sdr_rgba16` API, require every RGB channel to be within one UInt16 unit and
require alpha to match exactly.

```moonbit
let options : HdrToneMapOptions = {
  peak_luminance_nits: 1000.0,
  reference_white_nits: 100.0,
  exposure_stops: 0.0,
}
let sdr : Result[Image16, DecodeError] = frame.to_sdr_rgba16(options~)
```

`peak_luminance_nits` and `reference_white_nits` are absolute luminances in
cd/m² (nits). The peak is limited to 1–10,000 nits and the reference white is
limited to 1–peak nits. `exposure_stops` is a finite base-2 gain in the range
−16…+16 stops. The default is a 1000-nit HLG reference-display peak and
tone-map shoulder, a 100-nit reference white, and zero exposure. The output is
normalized SDR; the peak is not an output buffer luminance claim. Invalid
options return `DecodeErrorKind::InvalidData`.
For HLG, a peak yielding a nonpositive system gamma is also rejected; it
would make increasing scene luminance produce decreasing display luminance.

PQ (CICP transfer 16) is decoded with H.273's inverse transfer and then
scaled by its absolute 10,000-nit range. HLG (CICP transfer 18) first uses
the inverse HLG OETF to recover scene-linear RGB, then applies the BT.2100
reference display OOTF:

```
Y_S = k_R R_S + k_G G_S + k_B B_S
gamma = 1.2 + 0.42 log10(peak_luminance_nits / 1000)
F_D = peak_luminance_nits * E * Y_S^(gamma - 1)
```

For BT.2020 (CICP primaries 9), `(k_R, k_G, k_B)` is exactly
`(0.2627, 0.6780, 0.0593)` as specified by BT.2100. Other RGB primary sets
use their declared RGB-to-XYZ Y row; CICP XYZ (10) uses its Y channel, and a
monochrome frame uses its scalar channel. This keeps HLG scene luminance tied
to the declared source gamut.

Other supported CICP transfers use `reference_white_nits` as their absolute
linear-light anchor. Source RGB primaries are converted through CIE XYZ to
BT.709 with Bradford adaptation to D65; this includes BT.709, BT.2020,
Display-P3, DCI-P3, BT.601 and the other RGB primary sets already recognized
by the decoder. CICP value 10 is handled as CIE XYZ when paired with matrix
11. Unsupported or unspecified transfer/primary metadata returns
`DecodeErrorKind::Unsupported`.

The tone mapper uses the Extended Reinhard operator. For luminance `L` in
nits, it applies exposure, normalizes by the reference white, and uses the
configured peak as its white point:

```
x = L * 2^exposure_stops / reference_white_nits
w = peak_luminance_nits / reference_white_nits
mapped = x * (1 + x / w^2) / (1 + x)
```

The result is clipped to the normalized SDR range only after preserving the
BT.709 luminance ratio between channels. It is then encoded with the sRGB
(CICP 13) transfer and quantized to RGBA16. Alpha is expanded at its native
depth, and premultiplied color is unpremultiplied before inverse transfer and
tone mapping. Each call allocates a fresh output buffer.

Normative references:

- [ITU-R BT.2100-2 (HDR PQ and HLG parameters)](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2100-2-201807-S%21%21PDF-E.pdf)
- [ITU-T H.273 V4 (CICP primaries and transfers)](https://www.itu.int/rec/dologin_pub.asp?id=T-REC-H.273-202407-I%21%21PDF-E&lang=e&type=items)
- [ITU-R BT.2020-2 (wide-gamut RGB chromaticities)](https://www.itu.int/dms_pubrec/itu-r/rec/bt/r-rec-bt.2020-2-201510-i%21%21pdf-e.pdf)
