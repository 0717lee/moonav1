# MoonAV1 开发交接

更新日期：2026-10-01。本文供取得仓库的任意开发者使用，无需聊天记录或原作者临时目录。

## 首个公开 MVP

公开版本基于 2026-09-24 的 `6138973`，保留原始提取与验证历史，提供基础 AV1/AVIF 解码及 RGBA8 输出。`examples/decode` 演示公共 API 的成功解码和空输入拒绝；CI 在三个后端运行它。

后续本地扩展单独整理提交，原生像素公共接口、RGBA16、流式输入、ICC/HDR 和视频容器不在本次公开范围内。分批公开的时间不代表代码首次实现的时间。

当前 PixelForge `0.19.0` 已移除内置 AV1/AVIF 像素解码器，也没有 MoonAV1 依赖。MoonAV1 尚未发布到 Mooncakes，后续消费者接入使用正式包版本。下文 9 月 24 日迁移及撤回记录作为历史证据保留。

2026-10-01 在独立发布工作树复验：`moon info` 未改变根包公共接口，`moon fmt` 与 `git diff --check` 通过；JS、wasm-gc、Windows native 各通过 1306/1306 项测试，三个后端的 `examples/decode` 均输出 `64x64 AV1 -> RGBA8 OK`。编译器为 `0.10.11+6ff76a5f9`；类型检查保留基线的 72 条告警，0 错误。

## 最终目标

交付可独立安装、构建、测试和维护的纯 MoonBit AV1/AVIF 解码基础库。native、JavaScript、wasm-gc 共享解码核心，不通过浏览器原生解码或 FFI 调用宿主编解码器补足能力。MoonAV1 正式发布后，PixelForge 等图像应用再通过正式版本接入，最终使共享解码核心只维护一份。

本次迁移要求保持既有像素与错误处理契约，迁出对应参考样本、生成器、许可证和文档；不改变解码算法，不将迁移包装为新算法实现。

## 基线与状态

来源为 PixelForge `6f0c711c54f89d34f3e2ef97cde7a0a45458583d`，完整来源见 [PROVENANCE.md](PROVENANCE.md)。原项目中的 AV1/AVIF 主线验收已完成。初始独立包的检查及 native、JS、wasm-gc 各 1306 项测试已通过；本地 MoonAV1 的完整源码、测试、fixture 和生成器继续保留。

2026-09-24，维护者暂停 PixelForge 集成：以新增 revert 提交撤回迁移和固定快照接入，PixelForge 当时恢复来源版本的内置解码实现，保留历史与现有功能。此后的公开状态与 PixelForge 变更见本文开头。

撤回提交 [`edebb1f`](https://github.com/0717lee/pixelforge/commit/edebb1f0a597b8d1e11d6c90ebfad0b40e38299d) 已推送至 PixelForge `main`，[CI 35968739744](https://github.com/0717lee/pixelforge/actions/runs/35968739744) 全部通过。本地复验为 native、JS、wasm-gc 各 1546/1546，Web/Worker、WASM 和 native CLI 保持可用；这验证的是恢复后的 PixelForge 内置实现。本库源码及独立测试未被撤回。

包名 `0717lee/moonav1`，初始版本 `0.1.0`，配置见 `moon.mod` 和 `moon.pkg`。根目录 `av1_*.mbt` 负责 AV1 语法、熵解码、预测、重建、滤波和状态；`avif_*.mbt` 负责容器、网格及动画。像素基础定义与外部图像库、浏览器、文件系统解耦。

## 已撤回的 PixelForge 集成记录

以下是已执行、现已撤回的接入方式的历史证据，不表示当前 PixelForge 依赖 MoonAV1。

PixelForge 的迁移提交 `e366566e95b59173738bdb9bbbc5376550bd92cb` 与固定快照接入提交 `cb8169b2495bdaee9d829515e4811639d096165c` 曾正常推送到原仓库 `main`。当时快照来源为本库 `9f0f0c31a3ab35f169836223e6505b584882a15a`，包括 222 个 MoonBit 文件及配置、接口和许可等共 229 个登记文件。这两项接入变更通过新增 revert 提交撤回，原提交及其验收证据保留在历史中。

当时的 [GitHub CI 35965584975](https://github.com/0717lee/pixelforge/actions/runs/35965584975) 在干净 Ubuntu 检出中通过，覆盖依赖解析、快照校验、三后端测试、Web 产物复现、真实 Worker 独立像素、WASM 和 CLI。本地快照接入也通过 native、JS、wasm-gc 各 1548 项测试（本库 1306 + PixelForge 242），native AVIF→QOI 的 1024 字节 RGBA 与独立参考完全一致。这些结果不替代未来正式发布版本接入时的验证。

## 能力与公开契约

- 8/10/12-bit，单色与 4:2:0/4:2:2/4:4:4；帧内/帧间像素重建、多 tile、量化与环路滤波、film grain。
- AVIF 主图、辅助 alpha、grid，以及静态和动画 `prem` 关联；颜色和 alpha 轨道独立保留参考状态并按时间合成。
- `avif_decode_rgba` 返回合成后的 straight RGBA8；`avif_decode_animation` 返回时序与图像。
- `av1_video_decode_temporal_unit` 保留跨帧参考和隐藏帧更新；合法无呈现输入返回 `Some([])`，拒绝输入返回 `None`。
- RGBA 转换、HDR 与 PQ 舍入边界见 [README](README.md) 和 [颜色参考](tests/fixtures/av1-color/README.md)。不包含编码器，不声称通过额外的规范认证或达到未测量的性能指标。

## 验收标准

1. 新目录可单独取得并构建，不引用 PixelForge 源文件、个人目录或 `_refs`。
2. native、JS、wasm-gc 适用测试全部通过；迁移前的原始码流和独立像素保持不变。
3. 独立消费者能够调用静态与动画解码，结果、像素和时间与迁移前一致。
4. 文档、公开接口、版本配置和实际安装方式一致；第三方声明和样本来源可追溯。
5. MoonAV1 包正式发布后，PixelForge 通过正式版本接入时，须验证干净环境安装、其他图像处理能力与浏览器/CLI 集成。消费者迁移不在首个公开 MVP 范围内。

## 验证命令

固定编译器 `0.10.11+6ff76a5f9`，native 需 C 编译器。在仓库根目录运行：

```sh
moon version --all
moon info
moon fmt
moon check
moon test --target js
moon test --target wasm-gc
moon test --target native
git diff --check
```

普通测试使用内嵌参考，无需外部解码器。重新生成参考前阅读各目录 README 和脚本；部分历史脚本即使带 `--check` 也会写文件，须在隔离副本运行，不能覆盖真值来消除差异。

## 独立像素参考

`tests/fixtures/` 保留原始输入、独立原生 YUV/alpha/RGBA、manifest 和参考说明。`scripts/` 保留参考生成与核验工具。各 manifest 的工具版本和颜色约定优先于笼统的“参考解码器一致”描述。

原生 YUV/alpha 对照要求零差异；RGBA 按声明的颜色转换约定验证。保留 `inter_cdf_inherit_64x64` 的历史回归及零差异断言，但该流的宽容解码证据不能替代合法码流覆盖。合法组合样本见 `av1-mainline`、`av1-obu-assembly`、`avif-grid-sampling-color`、`avif-animation-alpha` 和 `avif-premultiplied-alpha`。

## 迁移验证记录

以下为 2026-09-24 初始独立包与 PixelForge 迁移候选的本地实测。PixelForge 接入现已撤回，这些历史结果不表示当前依赖关系或已发布版本。

| 检查 | 结果 |
| --- | --- |
| 提取范围 | 222 个 MoonBit 文件：80 个生产文件、142 个测试文件；221 个原文件保持相同内容，40 个仅按 moonfmt 统一格式，新增 1 个测试用 CRC helper |
| 独立依赖 | 仅 `moonbitlang/core/double`、`moonbitlang/core/math`；没有 PixelForge、mizchi/image 或文件系统依赖 |
| `moon info` / `moon fmt` / `moon check` | 成功；check 为 72 条原有告警、0 错误 |
| `moon test --target js` | 1306/1306 通过 |
| `moon test --target wasm-gc` | 1306/1306 通过 |
| `moon test --target native` | 1306/1306 通过 |
| 参考迁移 | 41 组、2344 文件逐个 SHA-256 与来源相同；1847 个可定位 manifest 文件/哈希对一致 |
| 脚本及说明 | 55 个 Python 文件通过 AST 解析，127 个 JSON 可解析，相对 Markdown 文件链接无缺失 |
| `moon package --list` | 成功生成本地 `0717lee-moonav1-0.1.0.zip`，未上传 |
| 干净源码归档 | 从初始提交导出的独立目录，JS 1306/1306；不使用原工作树构建缓存 |
| PixelForge 临时消费者 | 三目标各 242 项通过；包含本地 Image、网格适配、公开 reference slot 修改与复制隔离检查 |
| 临时消费者 Web | 产物生成/复现、数字规范化、8/10/12-bit grid、alpha/prem 动画、真实 Worker 独立像素与错误路径、线性内存 WASM 检查通过 |
| 临时消费者 native CLI | 10-bit YCgCo prem 图转 QOI 后，用 Pillow 独立解码得到的 1024 字节 RGBA 与 libavif 真值完全一致；彩色 12-bit grid 转 QOI 与迁移前输出逐字节相同 |

迁移验证时，PixelForge 原有的 1546 项总测试拆为 1306 项解码测试和 240 项图像处理测试，临时消费者另新增 2 项适配边界测试。该消费者拆分和固定快照接入已撤回；MoonAV1 独立测试继续保留。未来正式版本接入时，须重新验证干净环境安装、三后端及浏览器/CLI 集成。

注意 `tests/fixtures/avif-grid/manifest.json` 的 `color_rgba_contract`：彩色网格采用本库最近邻 4:2:0 约定，其 `scalar.rgba` 是保存的外部转换结果，并不声明完全相同。不能将该文件误用为 RGBA 零差异验收金值；原生 YUV、单色网格和具有明确 RGBA 约定的 prem 参考分别按各自契约检查。
