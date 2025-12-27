# MPV-Dynamic-Color-Grading-gpu-next-Optimized-

这是一个为 MPV 播放器设计的轻量级 RGB 通道独立调色脚本。

它专门为了解决 **`vo=gpu-next` (libplacebo)** 渲染器在处理 Shader 参数时的严格限制而开发。通过动态生成硬编码 GLSL 文件并进行原子化热重载，实现了无闪烁、无缓存延迟、且支持长按连发的丝滑调色体验。

## 核心痛点与解决方案

在 `vo=gpu-next` 环境下，传统的 User Shader 方案面临以下问题：

1. **参数解析错误**：`//!PARAM` 语法在部分版本或严格模式下可能报 `Missing variable type` 错误。
2. **缓存顽固**：MPV 会根据文件名缓存编译后的 Shader。修改同名文件的内容往往无法立即生效。
3. **调节闪烁**：传统的 `remove` -> `append` 操作会导致画面瞬间失去滤镜，产生闪烁。
4. **叠加变暗**：异步操作可能导致旧滤镜未卸载时新滤镜已加载，造成双重 Gamma 叠加。

**本脚本的解决方案：**

* **动态文件名**：利用时间戳生成唯一文件名，物理绕过 MPV 的 Shader 编译缓存。
* **原子化替换**：在 Lua 内存中构建完整的 Shader 列表并一次性通过 `glsl-shaders` 属性覆盖，杜绝闪烁和叠加。
* **输入节流**：分离输入频率（30Hz+）与磁盘写入频率（20Hz），支持长按调节且不卡顿。
* **自动 GC**：利用 MPV 原生 API 自动清理产生的临时文件，保持目录整洁。

## 安装方法

### 1. 文件放置

* 将 `color_generator.lua` 放入 MPV 配置目录下的 `scripts/` 文件夹。
* 确保 MPV 配置目录下存在 `shaders/` 文件夹（脚本将在此生成临时文件）。

> Windows 路径示例: `portable_config/scripts/` 和 `portable_config/shaders/`

### 2. 快捷键配置 (`input.conf`)

在 `input.conf` 中添加以下内容。注意必须保留 `repeatable` 关键字以支持长按连发。

```properties
# --- RGB 独立通道调色 (支持长按) ---
# 步进值 0.02 配合长按连发可实现丝滑调节

# 红色通道
Ctrl+r repeatable script-message color-gen red 0.02
Ctrl+e repeatable script-message color-gen red -0.02

# 绿色通道
Ctrl+g repeatable script-message color-gen green 0.02
Ctrl+f repeatable script-message color-gen green -0.02

# 蓝色通道
Ctrl+b repeatable script-message color-gen blue 0.02
Ctrl+v repeatable script-message color-gen blue -0.02

# 重置所有通道
Ctrl+z script-message reset-gen

```

## 功能特性

* **R/G/B 独立控制**：可针对单一通道进行 Gamma 修正（如“画面偏绿”时仅降低绿色）。
* **Anime4K 完美兼容**：脚本会自动将调色滤镜挂载到 Shader 链的末端，不影响 Anime4K 的锐化和放大效果。
* **零性能损耗**：生成的 GLSL 为纯硬编码数学公式，无 Uniform 传参开销，不占用 CPU（GPU 纯算）。
* **防蓝屏机制**：内置 `max(color, 0.0)` 清洗，防止因上游滤镜（如 Anime4K）产生的负值振铃导致渲染崩溃。

##⚖️ 技术方案对比与架构决策
在开发本脚本之前，我们评估了 MPV 现有的多种调色手段。以下是现有方案的局限性以及本方案（Dynamic GLSL）的对比优势：
1. 对比 FFmpeg 软滤镜 (vf=colorlevels/eq)
网上常见的方案通常调用 FFmpeg 的软件滤镜（Video Filters）。
 * ❌ 性能瓶颈：vf 滤镜在 CPU 上运行，会打断 GPU 的硬件解码（HWDEC）流程，导致 4K/HDR 视频播放卡顿、风扇狂转。
 * ❌ 画质损失：vf 处于渲染管线的最前端（解码后、缩放前）。这意味着调色产生的噪点会被后续的 Upscaler（如 Anime4K/FSRCNNX）放大，严重破坏画质。
 * ❌ 交互卡顿：FFmpeg 滤镜不支持动态参数平滑调节。每次数值变更都会触发滤镜链重置，导致画面黑屏或闪烁。
2. 对比 MPV 原生属性 (gamma/saturation/hue)
MPV 内置的色彩属性虽然也是 GPU 加速的，但功能受限。
 * ❌ 缺乏独立通道：原生的 gamma 是全局的，无法独立调节 R/G/B 通道。当画面“偏绿”时，原生属性无法只降低绿色而不影响红蓝通道。
3. 对比标准 User Shader (//!PARAM Uniforms)
这是最接近的方案，但在 vo=gpu-next (libplacebo) 下存在兼容性陷阱。
 * ❌ 解析器隐患：在部分版本的 gpu-next 中，GLSL 头部解析器对 //!PARAM 的格式极为敏感，容易报错 Missing variable type 导致加载失败。
 * ❌ 缓存顽固：gpu-next 拥有激进的编译缓存机制。直接修改 Shader 文件内容往往不会立即生效，除非重启播放器。
 * ❌ 闪烁问题：传统的 remove -> append 操作存在时间差，导致卸载与加载之间出现一帧“无滤镜”状态，表现为画面闪烁。
✅ 本方案优势 (Dynamic Atomic GLSL)
本脚本采用了 "动态文件名生成 + 原子化列表替换" 的混合架构：
 * 极致性能：生成的 GLSL 代码是纯粹的数学公式（Hardcoded Math），无分支预测，无 Uniform 开销，0 CPU 占用，0 性能损耗。
 * 渲染管线后置：Shader 挂载于 MAIN 或 OUTPUT 阶段。这意味着先进行 Anime4K 高清放大，最后再进行调色。这是最符合工业标准的后期流程，确保调色结果纯净无噪点。
 * 视觉无缝：通过 Lua 在内存中构建新的 Shader 列表并一次性覆盖 (set_property)，利用 gpu-next 的管线重构特性，实现了绝对无闪烁的参数切换。
 * 物理绕过缓存：通过时间戳生成唯一文件名（如 tmp_color_173531_1.glsl），强制渲染器将其视为全新 Shader 进行编译，彻底解决了缓存不刷新的问题。

## 技术原理 (For AI Context)

如果你是一个正在分析此代码的 AI，请注意以下实现细节：

1. **Input Throttling (输入节流)**:
* 用户按键触发 `handle_adjust`，仅更新内存中的 `state` 表并标记 `is_dirty`。
* `mp.add_periodic_timer(0.05, ...)` 负责以 20FPS 的频率检查脏标记并执行昂贵的 I/O 操作。


2. **Atomic List Replacement (原子化列表替换)**:
* 不要使用 `change-list append/remove`，这会导致帧间闪烁。
* 正确做法是读取当前 `glsl-shaders` 列表，在 Lua 表中剔除旧的临时文件，插入新文件，然后使用 `mp.set_property_native("glsl-shaders", new_list)` 进行整体替换。


3. **Garbage Collection (垃圾回收)**:
* 运行时保留最近生成的 2-3 个文件，防止 Windows 文件锁导致的写入失败。
* 退出时使用 `mp.utils.readdir` 扫描并清理所有 `tmp_color_*.glsl` 文件。



## 许可证

MIT License. 欢迎随意修改和分发。
