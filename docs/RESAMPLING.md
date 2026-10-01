# AVIF fractional display resampling

`AvifMetadata::resample_rgba8(image, width, height)` and
`AvifMetadata::resample_rgba16(image, width, height)` apply the ordered AVIF
display transform properties and return a new, caller-sized raster. They are
explicit display operations; decoding, ICC/Exif/XMP interpretation, pixel
aspect-ratio correction, and HDR tone mapping remain outside this API.

The [color-display fixture corpus](../tests/fixtures/color-display/README.md)
uses exact `Fraction` arithmetic for its line and 2×2-grid vectors. The public
API checks preserve the input channel-number domain (0–255 or 0–65535),
premultiply RGB by alpha for every tap, interpolate alpha separately, and
unpremultiply once before the final integer output.

## Geometry

Coordinates are pixel-center coordinates. A source pixel at `(x, y)` has its
center at integer coordinates and the raster boundary is
`[-0.5, width - 0.5] × [-0.5, height - 0.5]`. A `clap` rectangle has

```text
crop_width  = width_n  / width_d
crop_height = height_n / height_d
left = (current_width  - crop_width)  / 2 + horizontal_n / horizontal_d
top  = (current_height - crop_height) / 2 + vertical_n   / vertical_d
```

`left` and `top` are the centers of the first crop samples. The rectangle
therefore occupies the boundary intervals `[left - 0.5, left + crop_width -
0.5]` and `[top - 0.5, top + crop_height - 0.5]`. It must be wholly inside
the current raster. Size and denominator fields are positive uint32 values;
offset numerators are signed int32 values. The ordered transform list is
composed in one affine map. `Rotate(n)` is `n` anticlockwise quarter turns;
`Mirror(0)` flips top-to-bottom and `Mirror(1)` flips left-to-right.

Containment is checked with exact rational cross products, using the MoonBit
standard library's `bigint` module for the at-most-96-bit products. This avoids
rejecting a legal edge such as width `4/5` with offset `1/10` inside a one-pixel
raster, while still rejecting genuinely out-of-bounds fractions smaller than
floating-point resolution. Geometry is converted to Double only for sampling;
integer arithmetic is not performed per output pixel.

For output pixel `(x, y)`, the logical transformed coordinates are

```text
u = (x + 0.5) * transformed_width  / output_width  - 0.5
v = (y + 0.5) * transformed_height / output_height - 0.5
```

The affine map sends `(u, v)` to the source center coordinate. This keeps an
integer crop at its native size exact, while a fractional crop or a caller
chosen resize samples the intended continuous geometry. Source coordinates
outside the center interval are clamped to the nearest edge center before
bilinear lookup; this is the edge-extension rule.

## Interpolation and ownership

The input `Image` and `Image16` values are straight RGBA. Each of the four
bilinear taps is converted to premultiplied alpha, weighted, and then
unpremultiplied once. Alpha zero produces transparent black, which prevents a
transparent red/blue fringe from leaking into a visible edge. The result is
straight RGBA with one independent owned buffer.

RGB interpolation uses the input channel-number domain (0–255 or 0–65535)
and makes no implicit sRGB or transfer-function assumption. Callers that need
linear-light or ICC-managed color should convert before or after this raster
operation according to their color contract.

Malformed source dimensions or buffers return `InvalidData` or
`InvalidBuffer`; invalid rational values and out-of-raster geometry return
`InvalidData`; output dimensions over `MAX_IMAGE_PIXELS` return
`LimitExceeded`. Positive dimensions and valid buffers are required for both
the source and the caller-selected output.

When the chain is representable by the existing integer display map and the
requested dimensions equal its exact result, the resampling entry point uses
the existing exact permutation/crop path. This preserves byte-for-byte
identity and integer rotation/mirror behavior. All other chains compose the
full transform before performing their single interpolation pass.
