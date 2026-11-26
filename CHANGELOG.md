# Changelog

## 0.2.2 — 2026-11-26

### Changed

- Upgrade CI and development to the official MoonBit `1.0.0-rc1+3c0520448` toolchain (`moon` / `moonrun 0.1.20261126`).
- No source changes required: 1645/1645 tests pass on native, JavaScript and wasm-gc, and `moon info` reports no interface drift on all three targets.

## 0.2.1 — 2026-11-18

### Changed

- Upgrade CI and development to the current official MoonBit toolchain `0.10.20+65efd5b93`.
- Migrate `} derive(...)` to `#derive(...)` and regenerate the committed public interface.
- Add CI status and Mooncakes documentation links to the README.

### Validation

- Three-backend check/build/test: 1645/1645 on native, JavaScript and wasm-gc.
- `moon info` interface drift check passes on all three targets.
- Public API examples (`examples/decode`, `native_pixels`, `extensions`, `containers`, `color_video`) run in CI.
