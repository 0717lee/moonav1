# 工具链兼容验证（2026-11-26）

按 MoonBit 开源大赛组委会统一维护提醒，使用官方当前发布工具链重新验证。

## 实际工具链（`moon version --all`）

```
moon     0.1.20261126 (ccd306a 2026-11-26)
moonc    v1.0.0-rc1+3c0520448 (2026-11-26)
moonrun  0.1.20261126 (ccd306a 2026-11-26)
```

CI 固定版本：`1.0.0-rc1+3c0520448`（`.github/workflows/ci.yml`）。

## 标准入口验证结果

| 项目 | 结果 |
|---|---|
| `moon check` | 0 errors（611 warnings） |
| `moon build` | 通过 |
| `moon test --target native` | 1645/1645 |
| `moon test --target js` | 1645/1645 |
| `moon test --target wasm-gc` | 1645/1645 |
| `moon run examples/decode --target js` | `64x64 AV1 -> RGBA8 OK` |
| `moon info`（native/js/wasm-gc） | 三目标生成结果一致 |

CI 对 wasm-gc / js / native 三个目标分别执行 `check`、`build`、`moon info` + 接口漂移检查、`test`，并运行 `examples/decode`、`native_pixels`、`extensions`、`containers`、`color_video` 五个公开 API 示例。

## 适配记录

- `pkg.generated.mbti` 已按 0.10.20 重新生成：新编译器把 `} derive(...)` 的接口输出规范化为 `#derive(...)` 前缀形式，三目标一致，CI 的接口漂移检查通过。
- 13 处 `} derive(...)` 旧语法已迁移为 `#derive(...)` 前缀形式，`moon check` 警告从 648 降到 637，0 error；三目标测试与公开 API 示例结果不变。
- 其余警告为 `test_unqualified_package` 等提示，不影响构建与测试。

## 平台限制

`native` 目标需要平台 C 编译器；`tests/fixtures/` 的大型输入按版本保存在 Release 下载包中，普通测试无需下载。

## 0.10.21 升级（2026-11-18）

- 官方发布 `moonc 0.10.21+06da1ed44`，CI、README 与本文档同步固定；源码无需改动。
- 三目标 `moon info` 接口零漂移，测试 1645/1645（native / js / wasm-gc）。

## 1.0 升级（2026-11-26）

- 官方发布 `moonc 1.0.0-rc1+3c0520448`（`moon` / `moonrun 0.1.20261126`），CI、README、`docs/VALIDATION.md` 与 `scripts/check-linux.sh` 同步固定；源码无需改动。
- 三目标 `moon check` / `moon build` / `moon test` 全部通过，测试仍为 1645/1645；`moon info` 三目标接口零漂移，`pkg.generated.mbti` 无变化。
- 默认 `moon check` 警告由 637 降至 611，剩余为 `test_unqualified_package` 等提示，0 error。
- 五个公开 API 示例（`decode`、`native_pixels`、`extensions`、`containers`、`color_video`）在 wasm-gc 下运行通过。
