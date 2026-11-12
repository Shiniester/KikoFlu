# 双耳定位算法研究

资料核对日期：2026-11-09。

目标是保留已有音声的走位，并让前后左右定位更清楚。
建议先用已有双耳录音比较原声、现有效果和可选的耳机补偿。
耳机补偿可能改变音色，尚无证据保证能增强该类音声的前后定位。
单声道定向和立体声虚拟扬声器可作为另一个试听方向。
这两种处理会重新放置声像，不能视为保留原有走位。

## 当前效果与定位目标

当前立体声扩宽保留中间分量，放大左右差异分量。
当前单声道扩宽使用 Schroeder 全通滤波器生成短时去相关信号，并保留原有差异分量。
两种处理均没有为方向加载头相关传递函数。
扩宽可以改变声像宽度，但不能据此认定前后方位更准确。
首次使用或没有已保存设置时，现有效果默认关闭。
设置保存在本机；处理细节见[播放音效规格](audio-playback-effects.md)。

## 定位原理与素材限制

头相关传递函数（HRTF）描述声波从指定方向传到双耳时的变化。
头相关脉冲响应（HRIR）是对应的时域表示。
渲染时，声源分别与左右耳的 HRIR 卷积，生成双声道耳机信号。
[前后辨别实验](https://pmc.ncbi.nlm.nih.gov/articles/PMC2814998/)说明了方向相关的频谱线索和卷积方法。

左右定位依赖双耳到达时间差和响度差。
前后及上下辨别还依赖耳廓、头部和躯干造成的方向频谱变化。
只放大左右声道差异，不能补足对应方向的完整频谱线索。
在一项使用非个人 HRTF 的实验中，虚拟声源的前后和上下混淆增多。
实验使用宽带噪声，结果不能直接当作音声作品的效果保证。
见 [Wenzel 等人的实验](https://pubmed.ncbi.nlm.nih.gov/8354753/)。

| 输入素材 | 可以尝试 | 限制与听感风险 |
|---|---|---|
| 单声道 | 把整段音频作为一个声源，指定前、后、左或右。 | 所有已混合的声音一起移动。算法不能知道每个人声或动作原来的位置。 |
| 普通立体声 | 把左右声道视为两个虚拟声源，设置各自的位置。 | 两个声道不等于两个独立声源。重放置可能改变原有移动轨迹、空间宽度和音色。 |
| 已有双耳录音 | 用原声作为首选对照，按需试听处理。 | 双耳录音已经包含录制时的双耳线索。再次卷积可能改变这些线索，导致走位、贴耳感或音色变差。 |

上表中再次卷积的风险是根据信号处理链推断的，实际程度需要试听。
单声道和普通立体声都可能包含多个已混合的声源。
仅靠指定虚拟方向，不能自动分离这些声源或恢复录制时的真实位置。
声源分离需要额外模型或先验信息，结果也不能视为原场景的可靠复原。
单声道分离问题的限制见[声学分离研究](https://www.ee.columbia.edu/~dpwe/papers/Cauwen99-monsep.pdf)。
声道数也不能可靠区分普通立体声与双耳录音。

## 保留双耳录音走位的可行方向

耳机补偿尝试修正耳机和佩戴方式带来的频率响应变化。
[耳机补偿实验](https://aes.org/publications/elibrary/elibrary-page/?id=14917)测量了耳机响应，并比较不同补偿方法。
实验使用粉红噪声和拨弦乐器声，不能推导出 ASMR 音声的定位收益。
另一项[定位实验](https://www.frontiersin.org/journals/neuroscience/articles/10.3389/fnins.2014.00370/full)发现，替换耳机校正项没有改变其定位结果。
该实验使用 DT990 耳机与宽带噪声，不能代表所有耳机和素材。
因此，补偿对音色、前后定位和贴耳感的影响，需要针对作品与耳机试听。

对左右声道应用相同的线性均衡，理论上保留两声道的相对传递关系。
均衡仍会改变音色，也不能保证听感中的走位不变。
可以先用播放器现有均衡器做可旁路的对照，不必预设某条曲线能增强定位。
如果为左右耳分别补偿，还需检查两声道的相对时间、响度和频谱变化。
通用耳机曲线可能不匹配个人耳道、耳机和佩戴状态。

个人 HRTF 适合为已知方向的独立声源重新渲染。
已混合的双耳音频通常没有逐声源的方向和原始信号。
因此，不能假定简单叠加或替换一个 HRTF，就能把录音无损适配到个人耳廓。
动态头部追踪同样需要方向信息和随头部运动更新的渲染。
已有双耳录音的个性化和动态重渲染应单独研究与验证。

神经网络可以尝试从混合音频估计空间信息。
[NBU 论文](https://www.dafx.de/paper-archive/2024/papers/DAFx24_paper_36.pdf)研究了普通立体声音乐的双耳上混，[作者页面](https://www.audiolabs-erlangen.de/resources/2024-DAFx-Neural-Binaural-Upmix)提供试听样本。
论文的定位测试限于前半球。
专家听音测试中，NBU S 的空间感评分高于对照。
普通听者的测试没有复现该结果。
作者将实时处理列为后续研究。
这些结果不能证明已有双耳音声能保留前后走位，也不能证明移动端可实时运行。

## 可选方案

| 方案 | 能力 | 在 KikoFlu 中的接入判断 |
|---|---|---|
| 现有均衡器 | 对左右声道应用均衡，可用于试听音色变化。 | 可以先与原声对照；尚未证明适合增强双耳录音定位。 |
| FFmpeg `sofalizer` + libmysofa + SOFA | 用 SOFA 数据和虚拟扬声器位置生成耳机双声道。 | 可沿现有 mpv/FFmpeg 滤镜链做原型。需要调整原生构建、提供数据文件并验证各平台。 |
| FFmpeg `headphone` + HRIR 音频流 | 使用额外音频流中的 HRIR 合成虚拟扬声器。 | 不直接要求加载 SOFA；需准备 HRIR、接入额外滤镜图输入并启用滤镜。 |
| Steam Audio 4.8.1 | C API 支持对声源应用 HRTF，也能加载符合限制的 SOFA。 | 官方列出 5 个目标平台。仍需把解码后的音频接入 C API，并验证 Flutter、mpv 和平台打包。 |
| Spatial Audio Framework | 提供 HRIR 处理和 SOFA 读取等 C/C++ 模块。 | 适合需要自行控制处理链时评估。需要自行接入播放链，并核对启用模块及依赖的许可证。 |
| OpenAL Soft | 提供包含 HRTF 的空间音频播放能力。 | 提供独立音频 API。接入现有播放链的方式及目标平台构建均需验证。 |

表中的 HRTF 渲染方案用于重新放置声源，不能作为保留已有双耳走位的已证实方案。

### FFmpeg `sofalizer`

[`sofalizer` 上游文档](https://ffmpeg.org/ffmpeg-filters.html#sofalizer)说明了 SOFA 文件和虚拟扬声器参数。
编译滤镜需要启用 `--enable-libmysofa`。
[mpv 手册](https://mpv.io/manual/master/#audio-filters-lavfi=graph)说明 `lavfi` 可调用 FFmpeg 音频滤镜。

当前 [滤镜清单](../../scripts/native_audio/filters.txt)没有 `sofalizer`。
Windows 构建在[锁定文件](../../scripts/native_audio/windows.lock)中固定了 libmysofa 源码版本。
这不能证明发布库已经启用该滤镜。
Android 和 Apple 构建是否能启用 libmysofa 仍需验证。
Linux 也需检查实际发行库和滤镜构建。
各平台还需验证 SOFA 文件路径、资源打包和滤镜加载。

上游文档列出时域和频域处理。
上游当前频域模式的默认帧长为 1024 个样本。
帧长不等于整个播放器的实测延迟。
项目的 Android 构建锁定 FFmpeg 6.0，其他构建也可能使用不同版本。
参数、运行时调整能力和切换行为均应按实际构建验证。
当前上游源码在初始化时读取方向参数并装载响应，不能据此承诺播放中平滑热切换。
见 [FFmpeg 6.0 滤镜文档源码](https://github.com/FFmpeg/FFmpeg/blob/n6.0/doc/filters.texi)和[当前滤镜源码](https://github.com/FFmpeg/FFmpeg/blob/master/libavfilter/af_sofalizer.c)。

### FFmpeg `headphone`

[`headphone` 文档](https://ffmpeg.org/ffmpeg-filters.html#headphone)说明了额外 HRIR 输入和声道映射。
默认格式使用每个输入声道对应的一条双声道 HRIR 流。
滤镜也接受一条多声道 HRIR 流。
这种方案可能免去运行时读取 SOFA 所需的 libmysofa。
仍需准备和分发兼容的 HRIR 数据，并验证额外滤镜图输入。
当前滤镜清单没有 `headphone`，各平台是否可启用尚未验证。
该滤镜同样会重放置声像，不能保证保留双耳录音的走位。

### Steam Audio

[Steam Audio 4.8.1 源码](https://github.com/ValveSoftware/steam-audio/tree/v4.8.1)采用 Apache-2.0 许可证。
[C API 入门文档](https://valvesoftware.github.io/steam-audio/doc/capi/getting-started.html)列出 Windows、Linux、macOS、Android 和 iOS。
该页面列出的 macOS 架构是 Intel，不能单凭此页面确认 Apple Silicon 包装。
文档中的平台支持也不等于 KikoFlu 的构建和发布已经验证。

Steam Audio 内置 HRTF，也可加载自定义 SOFA。
自定义文件须符合 `SimpleFreeFieldHRIR` 等约束。
具体限制见 [4.8.1 使用指南](https://github.com/ValveSoftware/steam-audio/blob/v4.8.1/core/doc/guide.rst)。
引擎支持在调用中指定声源方向，但接入现有播放器需要额外原生音频处理。
不应据此假定能直接替换现有滤镜，或保证低延迟切换。

### 其他开源库和许可证

[Spatial Audio Framework](https://github.com/leomccormack/Spatial_Audio_Framework)的核心模块采用 ISC 许可证。
SOFA 读取是可选模块；启用某些其他模块会引入 GPLv2 条款。
上游列有 Windows、Linux 和 macOS 构建示例。
Android、iOS 和项目内集成仍需单独验证。

[OpenAL Soft 上游 master 的说明](https://github.com/kcat/openal-soft/blob/master/README.md)称软件采用 LGPL 2 或后续版本。
该说明称默认 HRTF 数据来自 SADIE II，数据采用 Apache-2.0。
目标平台、音频输入路径和再分发方式需按选定版本核对。

[libmysofa](https://github.com/hoene/libmysofa)的主要源码采用 BSD-3-Clause。
仓库还列出了其他作者的代码与数据，应核对实际分发内容。
[FFmpeg](https://www.ffmpeg.org/legal.html)通常使用 LGPL 2.1 或后续版本。
启用 GPL 组件后，构建受 GPL 条款约束。
发行时需要按实际链接方式、构建配置和数据文件核对许可义务。

## HRTF 数据与个人差异

SOFA 是存放空间声学数据的格式，不是统一的数据许可证。
候选数据需要分别核对许可证、测量方向、采样率和渲染器兼容性。

- [SADIE II 2-2](https://zenodo.org/records/12092466)提供 SOFA 格式的人体和人工头测量数据。数据集附带 [Apache-2.0 许可证文件](https://zenodo.org/records/12092466/preview/LICENSE.txt?include_deleted=0)。
- [HUTUBS](https://depositonce.tu-berlin.de/items/dc2a3076-a291-417e-97f0-7697e332c960/full)包含 96 组测量对象的数据，登记许可为 CC BY 4.0。
- 分发前应核对所选文件的元数据及归属要求。不能把数据集页面的许可自动套用到其他 SOFA 文件。

耳廓形状、耳机响应、佩戴方式和素材频谱都会影响听感。
同一 HRTF 不保证适合每个人。
[SADIE II 的听感研究](https://www.mdpi.com/2076-3417/8/11/2029)发现，受试者对音色和整体偏好的排序不总与个人测量一致。
该研究考察的偏好不能代替前后定位准确率。
选择数据时应分别比较方位、音色和整体偏好。

动态线索可能帮助辨别前后。
[Wightman 和 Kistler 的实验](https://pubmed.ncbi.nlm.nih.gov/10335634/)中，鼓励受试者转头时前后混淆减少。
要在耳机播放中复现这类线索，需要获得头部方向并随之更新渲染。
静态滤镜本身没有提供头部追踪，实验结果也不能保证项目中的效果。

## 建议的验证

1. 使用已有双耳音声和已知走位的双耳录音，比较原声、现有扩宽和可选补偿。
   调整播放响度至一致，记录前后左右辨别、移动轨迹、音色和贴耳感。
2. 使用普通立体声和单声道素材，单独试听虚拟声源处理。
   对有已知方向的素材，统计左右错误和前后混淆。
3. 检查不同耳机与听者的结果。
   检查起音、削波，以及处理是否改变原有音量。
4. 在目标构建中检查滤镜和 SOFA 或 HRIR 数据加载。
   测量不同设备上的延迟、CPU、内存和电量影响。
5. 检查播放中调整、暂停、跳转、切歌和采样率变化。
   验证音效切换的连续性及字幕、章节同步。

这些检查尚未执行。
无论选择哪种方案，都应保留关闭效果后的原声对照。
