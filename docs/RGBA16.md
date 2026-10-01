# RGBA16 输出契约

RGBA16 提供完整的 16 位整数通道，供需要保留高位深颜色和低 alpha 覆盖率的调用者使用。它直接从原生像素转换，颜色计算不经过 RGBA8。

## 接口与布局

| 接口 | 输入与行为 |
| --- | --- |
| `av1_decode_rgba16(bytes)` | 解码低开销 AV1 OBU，返回首个选中呈现的 RGBA16 |
| `avif_decode_rgba16(bytes)` | 解码 AVIF 主图/grid 与辅助 alpha，返回 straight RGBA16 |
| `frame.to_rgba16()` | 将 `Av1NativeFrame` 转为不透明 RGBA16，不再次解码 |
| `image.to_rgba16()` | 将 `AvifNativeImage` 转为 straight RGBA16；也适用于原生动画帧的 `image` |

四个接口均返回 `Image16?`。`Image16` 包含只读的 `width`、`height` 和可修改的 `data : FixedArray[UInt16]`。返回时 `data.length() == width * height * 4`，按行存放 R/G/B/A：

```text
data[(y * width + x) * 4 + channel]    channel: R=0, G=1, B=2, A=3
```

每个通道覆盖 0–65535，alpha=65535 表示完全不透明。它是 UNORM16 整数数组，不是半精度浮点，也不是按端序打包的字节数组。写入文件时由调用者选择字节序。每次转换分配独立输出，修改它不会改变输入原生平面或其他转换结果。

无效码流、辅助 alpha 错误、调用者改坏的原生平面尺寸/样本范围，或当前颜色内核不支持的彩色元数据，均返回 `None`。转换方法不修改传入的原生图像。原生平面自身的布局见 [原生像素契约](NATIVE_PIXELS.md)。

## 颜色和量化

颜色处理延续原有内核：最近邻色度复制，保留源 primaries/transfer，未指定矩阵使用 BT.601；XYZ 转为 BT.709/sRGB，单色沿用灰度范围扩展。没有 HDR 色调映射或显示器色域适配。

RGB 使用 Double 完成范围扩展、矩阵/曲线和 alpha 运算，最后裁剪到 0–1 并以 `floor(value * 65535 + 0.5)` 量化一次。没有 RGBA8 或 RGB16 中间量化。

alpha 保持独立于颜色的范围处理。full-range alpha 按原位深最大值缩放至 65535；limited-range alpha 先沿用已有规则，在原生位深扩展、舍入并裁剪，再缩放到 16 位。比如 limited 12-bit 的 263/264 先得到 8/9，最后得到 alpha16 的 128/144。

有 `prem` 关联时，用原生 alpha 覆盖率撤销预乘，然后量化 RGB16。alpha 为 0 时输出透明黑；straight 输入的零 alpha 不清除颜色。XYZ 的预乘在既有 XYZ→sRGB 转换之前撤销。

RGBA8 保留已有兼容舍入路径；RGBA16 使用上述高精度顺序，因此将 RGBA16 再缩成 8 位不一定等于直接调用 RGBA8。libavif 0.11.1 的部分 prem 路径也先量化 RGB16 再撤销预乘；这些低 alpha 情况与本接口使用不同的量化顺序，参考中分别记录实际结果。

## 独立精度证据

[RGBA16 参考集](../tests/fixtures/rgba16/README.md) 从既有独立原生像素建立有理数/80 位 Decimal 参考，覆盖 37 组、55 幅图像，包括 14 组颜色矩阵/曲线、8/10/12-bit、单色、三种色度采样、grid、alpha/prem 和动画。

参考验收要求 RGB16 与独立数值结果最多相差 1 个 UNORM16 单位，alpha16 完全一致。原生 YUV/alpha 仍要求零差异。生成时还使用实际 libavif 0.11.1 重解码完整容器，逐样本核对原生颜色/alpha，并另存它的 RGBA16 输出及差异记录。来源与每幅图的比较结果见 manifest；期望值不来自 MoonAV1 输出。

## 使用示例

独立消费者 [examples/native_pixels/main.mbt](../examples/native_pixels/main.mbt) 同时演示静态和动画的 RGBA16。以下用法不会重新解码所选动画帧：

```moonbit
fn rgba16_at(bytes : Array[Byte], timestamp : Int) -> @moonav1.Image16? {
  let animation = match @moonav1.avif_decode_animation_native(bytes) {
    Some(value) => value
    None => return None
  }
  match animation.frame_at(timestamp) {
    Some(frame) => frame.image.to_rgba16()
    None => None
  }
}
```

需要连续播放或多次取帧时，保存一次解码得到的 animation，重复调用 `frame_at` 与 `to_rgba16`。时间单位和选帧共享规则见 [原生动画契约](NATIVE_PIXELS.md#原生动画与时间选择)。
