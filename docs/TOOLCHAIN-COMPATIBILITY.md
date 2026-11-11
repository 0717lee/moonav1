# 工具链兼容验证（2026-11-11）

按 MoonBit 开源大赛组委会统一维护提醒，使用官方当前发布工具链重新验证。

## 实际工具链（`moon version --all`）

```
moon     0.1.20261104 (940aa18 2026-11-04)
moonc    v0.10.20+65efd5b93 (2026-11-05)
moonrun  0.1.20261104 (940aa18 2026-11-04)
```

CI 固定版本：`0.10.20+65efd5b93`（`.github/workflows/ci.yml`）。

## 标准入口验证结果

| 项目 | 结果 |
|---|---|
| `moon check` | 0 errors（648 warnings） |
| `moon build` | 通过 |
| `moon test --target native` | 1645/1645 |
| `moon test --target js` | 1645/1645 |
| `moon test --target wasm-gc` | 1645/1645 |
| `moon run examples/decode --target js` | `64x64 AV1 -> RGBA8 OK` |
| `moon info`（native/js/wasm-gc） | 三目标生成结果一致 |

CI 对 wasm-gc / js / native 三个目标分别执行 `check`、`build`、`moon info` + 接口漂移检查、`test`，并运行 `examples/decode`、`native_pixels`、`extensions`、`containers`、`color_video` 五个公开 API 示例。

## 适配记录

- `pkg.generated.mbti` 已按 0.10.20 重新生成：新编译器把 `} derive(...)` 的接口输出规范化为 `#derive(...)` 前缀形式，三目标一致，CI 的接口漂移检查通过。
- 源码中仍有 13 处 `} derive(...)` 旧写法，当前工具链标记为 `deprecated_syntax` 但完全可用，0 error；按官方"已正常构建和测试即可保持现有验证流程"的说明暂不批量迁移。
- 其余警告为 `test_unqualified_package` 等提示，不影响构建与测试。

## 平台限制

`native` 目标需要平台 C 编译器；`tests/fixtures/` 的大型输入按版本保存在 Release 下载包中，普通测试无需下载。
