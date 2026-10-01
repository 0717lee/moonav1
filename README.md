# MoonAV1

纯 MoonBit AV1/AVIF 解码基础库，面向 native、JavaScript 和 wasm-gc。核心解码不调用浏览器图片解码器，不通过 FFI 调用 libaom、dav1d 或 libavif；这些工具仅用于生成独立测试参考。

[English](README.en.md) · [第三方声明](THIRD_PARTY_NOTICES.md)

## 能力与边界

- AV1：8/10/12-bit，单色及 4:2:0、4:2:2、4:4:4；帧内/帧间重建、参考与熵状态、多个 tile、量化、环路滤波和 film grain。
- AVIF：主图、辅助 alpha、grid、静态/动画的 `prem` 关联，以及带独立颜色/alpha 轨道的动画。
- 输出原生 8/10/12-bit 像素平面、straight RGBA8 或 RGBA16，包含静态图和动画的高位深 alpha。
- 提供分块 AV1 输入、惰性 AVIF 动画、错误诊断、解码限额、显示变换和可复用输出缓冲区。
- 支持 IVF、MP4/fMP4、WebM/Matroska 的 AV1 轨道读取、分块容器输入和时间定位。
- 库仅负责解码，不包含 AV1/AVIF 编码、图像滤镜、浏览器 UI 或文件系统。

RGBA 使用源 primaries/transfer、最近邻色度上采样及最终裁剪/舍入；未指定矩阵采用 BT.601。XYZ 转为 BT.709/sRGB。这里不进行 HDR 色调映射或显示器色域适配。PQ 参考中的四个通道严格匹配独立高精度 H.273 金值，并限定与 zimg 的差值不超过 1；不能将这一特例描述成与 zimg 全部字节相同。见 [颜色参考](https://github.com/0717lee/moonav1/blob/main/tests/fixtures/av1-color/README.md)。

## 安装

在 MoonBit 项目中添加依赖：

```sh
moon add 0717lee/moonav1@0.1.0
```

在调用方的 `moon.pkg` 中导入：

```moonbit
import {
  "0717lee/moonav1",
}
```

随后可通过 `@moonav1` 调用下方接口。native、JavaScript 和 wasm-gc 共用同一个包。

## 快速运行

安装 MoonBit 后克隆源码，在仓库根目录运行：

```sh
git clone https://github.com/0717lee/moonav1.git
cd moonav1
moon run examples/decode --target js
```

预期输出 `64x64 AV1 -> RGBA8 OK`。示例解码内嵌的 10-bit AV1 样本，核对输出尺寸和像素，并检查空输入被拒绝；不需要下载图片或安装外部解码器。也可使用 `--target wasm-gc` 或 `--target native`。

`moon run examples/native_pixels --target js` 演示高位深平面、RGBA16 和动画选帧；`moon run examples/extensions --target js` 演示流式输入、元数据和缓冲区复用。两个示例同样支持 native 和 wasm-gc。

`moon run examples/containers --target js` 演示 IVF 整文件及分块解码，并按时间戳取帧；同样支持 native 和 wasm-gc。

## 库接口

消费端导入后可通过 `@moonav1` 调用：

```moonbit
fn decode_image(bytes : Array[Byte]) -> @moonav1.Image? {
  @moonav1.avif_decode_rgba(bytes)
}
```

| 用途 | 接口 |
| --- | --- |
| AVIF 主图与 alpha/grid | `avif_decode_rgba` |
| AVIF 主图，不合成辅助 alpha | `avif_decode` |
| AVIF 动画与时间选择 | `avif_decode_animation`、`avif_animation_frame_at` |
| 原始 AV1 首个呈现 | `av1_decode` |
| 跨 temporal unit 的解码状态 | `av1_video_decoder`、`av1_video_decode_temporal_unit` |
| 容器/序列信息 | `avif_container_parse`、`av1_sequence_info` |
| 原生像素与动画 | `av1_decode_native`、`avif_decode_native`、`avif_decode_animation_native` |
| RGBA16 输出 | `av1_decode_rgba16`、`avif_decode_rgba16`、`Av1NativeFrame::to_rgba16` |
| 流式与惰性解码 | `Av1StreamDecoder`、`AvifAnimationDecoder` |
| 诊断与资源限额 | `av1_decode_native_result`、`avif_decode_native_result`、`DecodeLimits` |
| 容器解码与定位 | `Av1ContainerDecoder`、`Av1ContainerStreamDecoder`、`Av1PresentationTimeline` |

解码接口通过 `None` 拒绝无效或不支持的输入。状态化接口的 `Some([])` 表示合法但无显示帧的单元；隐藏帧仍更新参考状态。完整接口以 [pkg.generated.mbti](pkg.generated.mbti) 为准。

新增 `Result` 接口返回错误类别、上下文和可定位的字节偏移。像素布局、精度、所有权、流式边界和限额计数分别见 [原生像素](docs/NATIVE_PIXELS.md)、[RGBA16](docs/RGBA16.md)、[调用者接口](docs/EXTENSIONS.md)和[解码限额](docs/DECODE_LIMITS.md)。

容器支持范围见 [IVF/MP4/WebM](docs/VIDEO_CONTAINERS.md)，分块状态与 MP4 索引回放见[容器流式接口](docs/CONTAINER_STREAMING.md)，时间单位与 edit-list 映射见[时间定位](docs/CONTAINER_TIMELINE.md)。

## 本地构建与验证

使用与 CI 相同的 MoonBit 编译器 `0.10.14+7d59c7ec9`；native 目标需要 C 工具链。从 GitHub 克隆源码后，在仓库根目录执行：

```sh
moon version --all
moon check
moon build
moon test --target js
moon test --target wasm-gc
moon test --target native
```

普通测试使用随库提交的独立参考，不需要外部解码器。`tests/fixtures/` 中的说明和 manifest 记录样本来源、工具版本和像素约定。生成器位于 `scripts/`，外部参考工具只在重新生成或复核参考时使用。

## 许可证

项目采用 [Apache-2.0](LICENSE)。算法、表和参考工具的声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
