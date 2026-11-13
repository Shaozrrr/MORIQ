# 多说话人实时分离：竞品研究与隔离验证

## 候选和范围

[FluidAudio](https://github.com/FluidInference/FluidAudio) 是 Apache-2.0 Swift SDK，支持本机流式说话人分离；其 [LS-EEND CoreML 模型](https://huggingface.co/FluidInference/ls-eend-coreml)模型卡标 MIT，上游模型声明 MIT；[Sortformer 原始 v2.1 权重](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1)声明 NVIDIA Open Model License，转换后的 [CoreML 页面](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml)标 CC-BY-4.0。两者标注不同，发布时须核实完整权利链及模型具体版本，不能按转换页直接视为已满足授权。LS-EEND 的说话人槽位并不是可直接识别真实姓名；匹配姓名需经过声纹注册或用户命名及纠错。FluidAudio 官方指标说明不同音频类型、噪声和重叠情况下均有识别错误。

[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 项目代码 Apache-2.0，支持 macOS Intel 和 Apple Silicon；其公开示例的 speaker diarization 为离线，不能仅凭平台支持宣称实时。FluidAudio 以 Apple 平台及神经引擎为主，Intel 性能与兼容性尚未在 Intel Mac 评估。

## 测试一：公开四人中文样本

2026-11-13 在 arm64 Mac、macOS 27.0，用 FluidAudio 仓库提交 `d653a34a620c013febd7530427b4963ae18064b2`，原项目构建 `swift build -c release --product fluidaudiocli`。音频来自 [sherpa-onnx 官方示例](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/csrc/sherpa-onnx-offline-speaker-diarization.cc) 链接的 `0-four-speakers-zh.wav`，SHA-256 `bedf036caed208386c67b4ef4b11f83d74dd0d420b102163a1c33cd09cde7010`。两条官方命令：

```sh
.build/release/fluidaudiocli lseend sample.wav --variant dihard3 --output lseend.json
.build/release/fluidaudiocli sortformer sample.wav --output sortformer.json
```

LS-EEND 输出 3 个非空人声标签，14 段；57.1 秒音频一次完整处理耗时 0.19 秒、首次模型加载 6.05 秒。Sortformer 默认流式配置输出 4 个非空人声标签，16 段；56.9 秒音频一次完整处理耗时 3.49 秒、首次模型加载 37.73 秒。CLI 未指定 compute units 时使用 CPU；首次加载时间包含下载或缓存。快速向模型输入完整文件的耗时不是实时端到端延迟。Sortformer 的第 4 标签仅约 2.08 秒，且紧接另一标签，是否误拆无法据此判断。

音频文件名及来源声称为四人，但没有逐时说话人真值；不能计算 DER、证明输出标签全对，或由 4 标签断言准确。两模型均未集成 MORIQ，也未测试真实 Intel 机器。

## 测试二：两位公开朗读者交替拼接

`Tests/SpeakerDiarizationResearch/public_two_speaker.py` 下载公开 LibriSpeech dummy validation 前 4 段说话人 1272 和 openslr/librispeech_asr clean test offset 1000 前 4 段说话人 8455，交替排列，相邻片段间插入 0.4 秒静音。无私有音频。总时长 67.59 秒，片段边界已知但片段内的语音/静音边界未人工标注。模型用其标准 CLI、同一拼接文件，CPU 完整文件处理。

| 模型 | 按片段范围统计、有标签的输出时长归属正确 | 模型输出非空标签数 |
| --- | --- | --- |
| LS-EEND dihard3 | 49.7 / 49.7 秒 | 2 |
| Sortformer 默认流式配置 | 54.7 / 54.7 秒 | 2 |

指标只统计有预测标签并落在原始片段范围内的重叠时长，经最佳一对一标签映射；**不是准确率或 DER**。片段内含静音，无法据此评估漏检、误检或整体错误；也不覆盖多人同时讲话、混响、背景噪声、相似声线、跨语言、真实姓名或实时端到端延迟。结果仅说明此干净双人轮流样本未见已输出区间的跨人混淆。

可复现（需要可访问公开数据集、模型下载、Swift 构建和 ffmpeg；不包含模型或音频）：

```sh
git clone https://github.com/FluidInference/FluidAudio.git /tmp/fluidaudio
git -C /tmp/fluidaudio checkout d653a34a620c013febd7530427b4963ae18064b2
(cd /tmp/fluidaudio && swift build -c release --product fluidaudiocli)
python3 Tests/SpeakerDiarizationResearch/public_two_speaker.py \
  --fluidaudio-cli /tmp/fluidaudio/.build/release/fluidaudiocli \
  --ffmpeg /path/to/ffmpeg
```

首次运行 FluidAudio 模型默认下载到 `~/Library/Application Support/FluidAudio/Models`；本次研究留下约 720 MiB 模型缓存。上游公开数据集及访问接口可能变化。须使用带帧级说话人真值的多人会议，测 DER/JER、分人混淆、说话人切换延迟、噪声、重叠和设备压力，再与字幕文字时间戳真实对齐验证。

## 测试三：独立 Swift 流式分块输入

使用官方 `SortformerDiarizer.process(samples:sourceSampleRate:)`，读取同一个公开中文样本，每次提供 100ms、1600 个 Float32 单声道样本，结束调用 `finalizeSession()`。独立 Swift 程序在 macOS 27 arm64 CPU 成功产生 117 次处理更新，16 个最终时间段与上述 Sortformer CLI 的 16 段起止时间逐段一致（至约 0.01 秒）。模型已缓存时，向模型尽快喂完 56.9 秒音频的总处理约 3.45 秒。该实验未按真实时间等待、未含采集、字幕对齐或 UI，无法视作实时延迟或准确率，也未接入 MORIQ。

研究程序位于 `Tests/SpeakerDiarizationResearch/StreamCheck`。准备上述固定版本 FluidAudio 和公开四人中文样本后：

```sh
cd Tests/SpeakerDiarizationResearch/StreamCheck
MORIQ_FLUIDAUDIO_SOURCE=/tmp/fluidaudio swift run -c release StreamCheck /path/to/0-four-speakers-zh.wav
```

实际集成时不能在 ScreenCaptureKit 的音频回调锁内直接运行推理，应有界缓冲并在独立串行任务处理，重置会话和音源时清理模型状态；还需与识别文本词级/句级时间戳对齐，保留暂定与最终分段并处理重叠和不确定状态。当前尚未完成这些工作，不能展示为已能可靠辨认姓名。

Intel 兼容试探：同一独立 Swift 示例以 `swift build -c release --arch x86_64` 在 macOS 27.2 SDK 交叉编译成功，工具链提示该部署目标的 x86_64 架构已弃用；在这台 Apple Silicon Mac 通过 Rosetta 运行时，推理抛出 `SortformerError.inferenceFailed("Missing chunk_pre_encoder_embs_out")`。这不是 Intel 实机测量，也不能断言所有 Intel 均失败；但当前这条 Sortformer/CPU 路径不可据此标为双架构可用，需排查模型 Core ML 输出与兼容性，并在正式应用提供明确降级或禁用。

## 测试四：有界队列与会话切换（研究原型）

`Tests/SpeakerDiarizationResearch/QueueCheck` 把音频块放进最多 32 块的有界队列；一个后台串行工作者持有 Sortformer，不在提交调用中运行推理。满队列时 `submit` 返回 false；测试驱动为离线完整比较会等待重试，但实时音频回调**不应等待重试**，产品必须设计明确的溢出、失帧、背压和时间轴处理。音源切换递增 generation、丢弃队列里的旧块并重置推理器，旧 generation 后续提交被拒绝；结束按顺序排空并 finalize；取消丢弃待处理数据并退出。原型会在推理失败时关闭队列，避免测试生产者永久重试。

公开中文样本回归：先送入旧 generation 的最多 25 块，再切换并送入完整样本，得到 16 个最终段；自动对照官方完整文件 CLI 的 JSON，每段说话人编号、起止时间相同（误差阈值 0.01 秒）。取消后输出为空且拒绝继续提交。可用固定上游版本、公开样本和先前生成的 `sortformer.json` 运行：

```sh
cd Tests/SpeakerDiarizationResearch/QueueCheck
MORIQ_FLUIDAUDIO_SOURCE=/tmp/fluidaudio swift run -c release --scratch-path /tmp/moriq-queue-build QueueCheck /path/to/0-four-speakers-zh.wav /path/to/sortformer.json
```

本程序只在结束时返回片段，**未接字幕 UI、不提供实时回调、不处理说话人时间戳与识别文字对齐**；PCM 是从公开文件快速读取，测试中重试保持无丢块，不能证明真实负载、长时间录音、UI 更新、设备切换、错误恢复或实际准确率。生产化还需异步错误报告、取消推理边界、信号丢失及溢出状态通知、时间戳和可重入生命周期等完整设计。
