# 原生像素输出契约

`native` 指源图像的样本精度；以下接口在 native、JavaScript、wasm-gc 上具有相同语义。它们返回 8/10/12-bit 平面数据，适用于调用者自行做颜色转换、HDR 处理或像素分析。

## 入口与返回值

| 接口 | 返回值 | 行为 |
| --- | --- | --- |
| `av1_decode_native(bytes)` | `Av1NativeFrame?` | 使用新参考状态解码低开销 AV1 OBU 流，返回首个选中呈现；接受单色输入 |
| `av1_video_decode_temporal_unit_native(decoder, bytes, allow_monochrome=false)` | `Array[Av1NativeFrame]?` | 保留跨调用的参考状态；每个 temporal unit 返回 OP0 中实际出现的最高空间层呈现 |
| `avif_decode_native(bytes)` | `AvifNativeImage?` | 解码 AVIF 主图及其辅助 alpha，包含 grid 拼接、容器层选择与 nclx 元数据处理 |
| `avif_decode_animation_native(bytes)` | `AvifNativeAnimation?` | 完整解码 AVIF 动画，返回主轨时间轴及每帧原生颜色/alpha |
| `animation.frame_at(timestamp)` | `AvifNativeAnimationFrame?` | 在已解码动画上按主轨时间单位选帧，按总时长循环 |

输入均为 `Array[Byte]`。裸 AV1 入口读取 OBU 流；AVIF 入口读取完整容器。`None` 表示解码拒绝，单图 AV1 入口也用它表示没有呈现。状态化入口的 `Some([])` 表示输入合法但没有呈现，隐藏帧仍更新参考。一个输入可包含多个以 temporal delimiter 分隔的单元；输入末尾也会结束当前单元。

状态化解码失败时不回滚已经发生的参考更新。收到 `None` 后，应丢弃该 decoder 并从合适的序列/关键帧重新建立状态。原生和 RGBA 视频入口可按码流顺序交替使用同一个 decoder；同一单元只送入一次。视频入口的单色支持需显式传入 `allow_monochrome=true`。

这些入口不执行 RGB 转换，因此原生解码成功不代表相应颜色标识一定能由现有 RGBA8 转换器处理。公开签名见 [pkg.generated.mbti](../pkg.generated.mbti)，实现见 [native_pixels.mbt](../native_pixels.mbt) 和 [native_animation.mbt](../native_animation.mbt)。

## 平面与精度

`Av1NativeFrame` 提供 `width`、`height`、`bit_depth`、`subsampling_x`、`subsampling_y`、`full_range`、`matrix_coefficients`、`color_primaries`、`transfer_characteristics` 和 `planes`。

- `planes` 是 `FixedArray[Av1PixelPlane]`：单色为一个 Y 平面，彩色为 Y、U、V 三个平面。矩阵为 0 时，这三个位置的含义为 G、B、R，不能直接当作 RGB 顺序。
- 每个 `Av1PixelPlane` 提供自身的 `width`、`height` 和 `data : FixedArray[Int]`。行连续存放，`data[y * width + x]` 是一个样本，行步长就是该平面的 `width`，单位为样本。
- 彩色色度平面在 subsampling 为 true 的轴上取 `ceil(luma_size / 2)`；否则与亮度同尺寸。单色没有色度平面，调用者可忽略 subsampling 标记。
- 返回时 `data.length() == width * height`。所有编码 padding 已裁去，尺寸是重建、super-resolution 后的可见像素尺寸。
- 样本按原位深存为未移位整数：8-bit 为 0–255，10-bit 为 0–1023，12-bit 为 0–4095。这里没有转成 RGBA8、左移到 16-bit 高位或序列化为字节；文件端序由调用者在写出时决定。
- 输出已经过帧滤波和码流指定的 film grain。参考帧内部仍按原解码器规则保存；返回值不是参考槽的视图。

每次解码返回的所有平面数据均为独立副本，与输入、decoder 参考槽和其他解码图像隔离，动画中的不同帧也各自拥有像素。调用者可以修改 `data`，后续解码不会改变已经返回的像素。普通变量赋值和下面的 `frame_at` 选帧会共享已返回对象，不会自动深拷贝。

## 颜色、alpha 与 prem

原生颜色平面保留 full/limited range，不扩展亮度范围，不做色度上采样、矩阵转换、transfer 转换或 HDR 色调映射。颜色标识使用原 CICP 数值，2 表示未指定。AVIF 延续已有规则：码流未指定的颜色字段由 nclx 补充，已有明确字段保留；nclx 的范围标记按原容器路径应用。

`AvifNativeImage.color` 是主图或当前动画帧的颜色；`alpha` 为 `None` 时表示不带关联的辅助 alpha、按不透明解释。有 alpha 时，它是一个只有单平面的 `Av1NativeFrame`，尺寸与位深均与 color 一致；静态主图和 alpha 可以各自来自 grid。

alpha 保留解码后的原始样本以及它自己的 `full_range` 标记。limited-range alpha 尚未扩展到 full range；不能直接把其码值除以最大样本值作为覆盖率。`premultiplied` 表示已验证的 color→alpha `prem` 关联；原生输出不撤销预乘，也不把 alpha 写进颜色平面。损坏的辅助 alpha 会使整个调用返回 `None`。

需要现有 straight RGBA8、范围扩展和预乘处理时，调用 `avif_decode_rgba`，动画调用 `avif_decode_animation`。其最近邻色度、矩阵与舍入约定保持原样，见 [颜色参考](../tests/fixtures/av1-color/README.md) 和 [prem 参考](../tests/fixtures/avif-premultiplied-alpha/README.md)。需要 16 位整数通道时，原生帧和图像都提供 `to_rgba16()`，完整布局与高精度舍入顺序见 [RGBA16 契约](RGBA16.md)。

## 原生动画与时间选择

`avif_decode_animation_native` 与 RGBA8 动画入口共用容器轨道选择、解码状态和颜色/alpha 校验。颜色与辅助 alpha 各自保留 AV1 参考状态；轨道的物理先后次序不决定它们的关联。两个轨道使用不同 timescale 时，时间戳和时长以精确整数比例比较，匹配后统一按主颜色轨道的时间单位返回。颜色 nclx 和 `prem` 关联也沿用现有动画路径。

`AvifNativeAnimation` 提供 `timescale : Int` 和 `frames : FixedArray[AvifNativeAnimationFrame]`。返回成功时：

- `frames` 非空，按呈现次序排列，每帧的 `index` 等于数组位置。
- 每帧提供 `timestamp`、`duration`、`timescale` 和 `image : AvifNativeImage`；时间戳从 0 连续累加，duration 为正，所有帧使用动画的 timescale。
- 一秒对应 timescale 个时间单位，总时长不超过 `2147483647` 个单位。参数不是固定的毫秒数。
- 整段轨道与所有样本通过校验后才返回。后续帧损坏、颜色/alpha 时序不匹配或辅助样本不能解码时，整个调用返回 `None`。

`animation.frame_at(timestamp)` 在已解码帧上查询，不再次解码。每帧覆盖 `[timestamp, timestamp + duration)`，查询时间按总时长取模循环；负值返回 `None`。例如 timescale 为 1000、三个时长为 100/200/300 时，查询 99 返回第 0 帧，100 返回第 1 帧，300 返回第 2 帧，600 回到第 0 帧。这是查询方法的循环规则，不表示从容器读取了循环次数。

选帧返回动画数组中已存储的帧，像素缓冲区共享：修改所选帧也会修改同一个 `frames[index]`，但不会改变其他帧。由于调用者可以替换 FixedArray 中的条目，选帧会先验证整段时间轴；重新排列、重复条目或混入不连续时间的帧会返回 `None`。需要逐帧处理时可直接遍历 `animation.frames`。

## 可运行的独立消费者

仓库中的 [examples/native_pixels](../examples/native_pixels/main.mbt) 是一个单独的 MoonBit 包，通过 `@moonav1` 导入公共接口。它演示 12-bit AV1 平面读取、状态化视频、10-bit AVIF alpha/prem、RGBA8/RGBA16 输出，以及 12-bit AVIF 动画解码和循环选帧。示例内嵌原有参考码流，运行无需文件系统库或外部解码器。

在仓库根目录运行：

```sh
moon run examples/native_pixels --target js
moon run examples/native_pixels --target wasm-gc
moon run examples/native_pixels --target native
```

常见的平面读取方式如下，`bytes` 由调用者提供：

```moonbit
fn first_luma(bytes : Array[Byte]) -> Int? {
  match @moonav1.avif_decode_native(bytes) {
    Some(image) => Some(image.color.planes[0].data[0])
    None => None
  }
}
```

## 像素验证

`DecodeLimits` 的同名方法（如 `policy.avif_decode_native(bytes)`）逐次调用限制压缩输入、单帧/累计像素与帧数；具体计数和 `None` 后丢弃 decoder 的约定见 [解码限制](DECODE_LIMITS.md)。原有独立函数及其函数值类型保持不变。

原生视频接口接收完整 temporal unit。任意切分的字节块可使用 [Av1StreamDecoder](EXTENSIONS.md#arbitrary-av1-byte-chunks)，由流式接口保留定界和解码状态。

[native_pixels_test.mbt](../native_pixels_test.mbt) 仅使用公共接口，逐样本核对既有 dav1d/libavif 参考，覆盖三个深度、单色、4:2:0/4:2:2/4:4:4、奇数尺寸、帧间状态、film grain、grid、alpha/prem 和 nclx。另检查隐藏帧、show-existing、修改返回值后的参考隔离、原生/RGBA 视频交替调用，以及损坏输入拒绝。

[native_animation_test.mbt](../native_animation_test.mbt) 覆盖 29 个动画用例。`avif-premultiplied-alpha` 保存的每帧原生颜色和 alpha 均逐样本核对；`avif-animation-alpha` 保存的是原生 alpha 和 RGBA，因此新测试对这一组核对原生 alpha、时序、元数据及拒绝行为。另覆盖选帧区间端点、大时间戳、循环、所选帧共享与不同帧隔离，以及后续样本损坏时整段拒绝。原 RGBA8 独立参考测试继续保留。

测试常量与示例码流由 [generate-native-api-tests.py](../scripts/generate-native-api-tests.py) 从现有 fixture 序列化。正常 `moon test` 不需要 Python。以下命令只读取已保存参考并检查嵌入内容，不运行外部解码器、不重生成参考：

```sh
python scripts/generate-native-api-tests.py --check
```

原始码流、参考像素和 manifest 仍以各 fixture 目录为准；本阶段新增的是公共输出边界及其对照测试。
