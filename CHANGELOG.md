# Changelog

## 0.2.1 — 2026-11-18

### Changed

- Upgrade CI and development to the current official MoonBit toolchain `0.10.20+65efd5b93`.
- Migrate `} derive(...)` to `#derive(...)` and regenerate the committed public interface.
- Add CI status and Mooncakes documentation links to the README.

### Validation

- Three-backend check/build/test: 1645/1645 on native, JavaScript and wasm-gc.
- `moon info` interface drift check passes on all three targets.
- Public API examples (`examples/decode`, `native_pixels`, `extensions`, `containers`, `color_video`) run in CI.
