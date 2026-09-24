# MoonAV1

纯 MoonBit AV1/AVIF 解码基础库，面向 native、JavaScript 和 wasm-gc。核心解码不调用浏览器图片解码器，不通过 FFI 调用 libaom、dav1d 或 libavif；这些工具仅用于生成独立测试参考。

本库从 [PixelForge](https://github.com/0717lee/pixelforge) 提取，已有实现及其来源见 [PROVENANCE.md](PROVENANCE.md)。本次独立工程不改变原代码的完成时间或贡献归属。当前为本地迁移版本，尚未发布。

[English](README.en.md) · [开发交接与最终目标](HANDOFF.md) · [第三方声明](THIRD_PARTY_NOTICES.md)

## 能力与边界

- AV1：8/10/12-bit，单色及 4:2:0、4:2:2、4:4:4；帧内/帧间重建、参考与熵状态、多个 tile、量化、环路滤波和 film grain。
- AVIF：主图、辅助 alpha、grid、静态/动画的 `prem` 关联，以及带独立颜色/alpha 轨道的动画。
- RGBA 便捷接口输出 RGBA8、straight alpha；原生高位深样本用于解码和容器合成。
- 库仅负责解码，不包含 AV1/AVIF 编码、图像滤镜、浏览器 UI 或文件系统。

RGBA 使用源 primaries/transfer、最近邻色度上采样及最终裁剪/舍入；未指定矩阵采用 BT.601。XYZ 转为 BT.709/sRGB。这里不进行 HDR 色调映射或显示器色域适配。PQ 参考中的四个通道严格匹配独立高精度 H.273 金值，并限定与 zimg 的差值不超过 1；不能将这一特例描述成与 zimg 全部字节相同。见 [颜色参考](tests/fixtures/av1-color/README.md)。

## 主要接口

包名为 `0717lee/moonav1`。消费者在 `moon.pkg` 中导入该包后，使用别名 `@moonav1`：

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

解码接口通过 `None` 拒绝无效或不支持的输入。状态化接口的 `Some([])` 表示合法但无显示帧的单元；隐藏帧仍更新参考状态。完整接口以 [pkg.generated.mbti](pkg.generated.mbti) 为准。

## 本地构建与验证

使用与 CI 相同的 MoonBit 编译器 `0.10.11+6ff76a5f9`；native 目标需要 C 工具链。在本目录执行：

```sh
moon version --all
moon check
moon test --target js
moon test --target wasm-gc
moon test --target native
```

普通测试使用随库提交的独立参考，不需要外部解码器或 PixelForge 目录。`tests/fixtures/` 中的说明和 manifest 记录样本来源、工具版本和像素约定。生成器位于 `scripts/`，外部参考工具只在重新生成或复核参考时使用。

## 许可证

项目采用 [Apache-2.0](LICENSE)。移植的算法、表和参考工具保留各自声明，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。纯 MoonBit 描述的是实现语言，不表示所有算法原创。
