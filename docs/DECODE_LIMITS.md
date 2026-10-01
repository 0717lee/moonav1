# Optional decode work limits

The public facade is in [decode_entrypoints.mbt](../decode_entrypoints.mbt);
budget validation and accounting are in [decode_limits.mbt](../decode_limits.mbt).

`DecodeLimits` provides methods with the same names as the high-level AV1/AVIF
entry points, such as `policy.avif_decode_native(bytes)`. Ordinary free functions
retain their original signatures and behavior, including use as unary callbacks
in `inputs.map(avif_decode_rgba)`. `DecodeLimits::default()` is an opt-in starting
policy; applications can construct smaller limits for their workloads.

```moonbit
let policy = @moonav1.DecodeLimits::{
  max_input_bytes: 8 * 1024 * 1024,
  max_frame_pixels: 3840 * 2160,
  max_total_pixels: 4 * 3840 * 2160,
  max_frames: 8,
}
let image = policy.avif_decode_native(bytes)
```

| Field | What it limits | Opt-in default |
| --- | --- | --- |
| `max_input_bytes` | Supplied buffer, or sum of supplied samples; also each assembled item/sample payload including repeated extents | 64 MiB |
| `max_frame_pixels` | Area of one reconstructed/displayed picture, including AV1 MI padding and the larger super-resolution extent; also each grid canvas | 16 Mi pixels |
| `max_total_pixels` | Sum of those areas during one call; color, alpha and grid canvases share the budget | 128 Mi pixels |
| `max_frames` | Reconstructed pictures and show-existing operations, including hidden pictures, lower decoded spatial layers, grid cells and alpha tracks | 256 |

All fields must be positive. `max_frame_pixels` cannot exceed the existing
100,000,000-pixel hard limit. Geometry and remaining budgets are checked before
the allocation of frame reconstruction state or grid canvases; multiplication
uses division guards. Repeated extents are checked before payload concatenation.
A grid canvas consumes pixels but does not itself count as a coded picture.

These are input/work limits, not exact heap-byte limits or execution deadlines.
Pixels count luma-grid positions, not color channels. Bit depth, subsampling,
working filter buffers, caller-owned output copies and runtime allocation
strategy affect actual memory. Eight video reference slots can outlive a call.
For tighter applications, choose a smaller per-picture limit and feed one
complete temporal unit per call.

## Failure and state contract

An invalid policy or exceeded limit returns `None`, using the existing rejection
contract. It does not return a partial image/animation. The API does not yet
distinguish a limit rejection from malformed or unsupported syntax in its
return type. `Some([])` still means valid video input with no presentation.

Video work budgets restart for each call. Reusing a decoder keeps its reference
state, so a long stream can be processed without increasing a single call's
budget. After **any** `None`, discard that decoder: earlier units in the same
call may already have updated references. The limits do not provide rollback.
One image call may process more than its first presentation and those additional
pictures still count. A show-existing operation counts even though it does not
perform entropy reconstruction.

The policy methods cover raw AV1, AVIF primary/alpha/native/RGBA8/RGBA16,
video temporal-unit, grid and animation decode APIs. The sample-array animation
and grid functions share one budget across their samples. Metadata extraction
that assembles primary or alpha payloads also has policy methods for the byte limit. Existing
low-level prediction/transform helpers and conversion of an already constructed
native frame are outside this work-budget interface.

Create video state with `av1_video_decoder()` and keep its internal reference
arrays intact. Legacy exposed state fields support inspection; replacing or
resizing those arrays is not a supported high-level decode input. Returned
native picture buffers, in contrast, belong to the caller and may be edited.

## Parser and regression evidence

AVIF's primary, alpha and animation box walkers independently enforce a maximum
of 64 recursive container levels, including when no optional policy is supplied.
The previous JS decoder crashed with `RangeError: Maximum call stack size
exceeded` on a 160,000-byte, 20,000-level input. The corrected parsers reject it
normally. Tests accept the exact 64-level traversal boundary and reject level 65.

[Limit regressions](https://github.com/0717lee/moonav1/blob/main/decode_limits_test.mbt) exercise exact byte/pixel/frame
boundaries, shared alpha/grid/animation budgets, hidden pictures, show-existing,
super-resolution padding and per-call reset. A separate regression prevents
repeated grid extents from amplifying a payload beyond the selected byte budget.

The checked-in regressions cover byte, pixel and frame limits as well as AVIF
nesting boundaries. They run on JavaScript, wasm-gc and native in CI.

```sh
python scripts/generate-limits-fixtures.py --check
moon test decode_limits_test.mbt avif_depth_wbtest.mbt --target js
```
