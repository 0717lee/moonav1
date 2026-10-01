# Color and container consumer

Run this separate-package example from the repository root with the pinned
MoonBit toolchain:

```sh
moon run examples/color_video --target native
moon run examples/color_video --target js
moon run examples/color_video --target wasm-gc
```

The example uses retained fixtures and performs no file or network I/O. It
demonstrates ICC relative conversion with explicit black-point compensation,
native HDR tone mapping, fractional AVIF resampling, complete and incremental
IVF/MP4/WebM decoding, timestamp seeking and explicit MP4 edit-list mapping.

Incremental input uses 37-byte chunks and an 8 KiB compressed-input budget.
`feed` copies pending input; each returned packet/frame owns its pixel or
payload arrays. Consume batches as they arrive. `finish` declares actual EOF,
which is distinct from an empty `feed`. A tail-moov MP4 first discovers its
index, returns `ReplayRequired`, then needs `replay()` and the identical source
resent from byte zero. The peak counter covers both passes since `reset`.
The host supplies any real file reader and rewind operation.

Seeking uses raw media ticks and returns a checked at-or-after result. The
presentation timeline is an explicit separate operation; an empty MP4 edit
maps to `Empty`, never a fabricated AV1 picture. The complete API contracts
are in [container streaming](../../docs/CONTAINER_STREAMING.md),
[timeline and seeking](../../docs/CONTAINER_TIMELINE.md) and
[ICC input profiles](../../docs/ICC.md).
