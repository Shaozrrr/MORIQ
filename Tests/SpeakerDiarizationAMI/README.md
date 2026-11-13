# 真实会议说话人分离基准（研究）

测试样本为 [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/) 的 ES2002a Mix-Headset 会议音频 60–120 秒；AMI 音频和人工标注采用 CC BY 4.0。音频来自 [rh-aiservices-bu/speaker-diarization 的 180 秒摘录](https://github.com/rh-aiservices-bu/speaker-diarization/blob/efe65d42d92bfb6dc3f37c4059067e60733a5990/ami_sample.wav)，SHA-256 `bd705284d4d2b1f945874361e6d9ecca8c484d10f203d25287bef62987f5f493`；参考标注来自 [pyannote AMI setup](https://github.com/pyannote/AMI-diarization-setup) 提交 `67c2d539286e89f68952d5dcf83912bd9f01dfae` 的 `only_words/rttms/train/ES2002a.rttm`，SHA-256 `3153efc675b16b7c47c6e49a3b48602613b3dfcf0ca16f590fb7541176c0f0b2`。该 RTTM 依据人工标注生成，只包含言语词、不包含所有非言语发声。

使用 [dscore](https://github.com/nryant/dscore) 固定提交 `e02f949ac6592279300a2c33d03daf9e0c12fd27` 的 NIST `md-eval-22.pl`（文件 SHA-256 `872aa955cbc3d57e6d4fd6fe2e699791739c1cb716cc89105bb4717415b9400d`）打分：整个 60 秒 UEM、零宽容区、计入重叠讲话；评分按整段参考与预测的最优编号映射，不是在线过程中真实姓名判断。该摘录位于 AMI 训练划分，[NVIDIA 模型卡](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1)也列 AMI 为训练数据，不能作为严格独立测试或推广到所有会议。

2026-11-13 Apple Silicon 本机 CPU，使用 FluidAudio 固定提交 `d653a34a620c013febd7530427b4963ae18064b2`：

| 测试 | 漏检 | 误报 | 说话人混淆 | DER |
| --- | ---: | ---: | ---: | ---: |
| Sortformer v2.1，现有 helper，按真实时间每 100 ms 输入 | 13.64 s | 0.52 s | 0.38 s | 27.71% |
| LS-EEND dihard3，官方 CLI，离线快速输入 | 11.91 s | 0.53 s | 0.57 s | 24.79% |

参考说话人总时长 52.48 秒（重叠期间可重复计时）。Sortformer 测试再次以真实速度回放，输出 29 个最终片段，**模型自身预测片段结束到最终事件输出**中位数 0.919 秒、最大 1.211 秒；音频写入调度最大落后约 0.011 秒。该时间不含模型加载，不是人工标注的说话人切换延迟，也不含 ASR、翻译、UI 和实际系统音频采集延迟。LS-EEND 以离线快速输入，未测实时延迟，不能与 Sortformer 延迟比较。

两者仍有明显漏检；LS-EEND 在此单样本漏检稍低、混淆稍高，但输入方式不同，不能据此判断整体哪个更好。两者都未达到“保证很准确”的证据标准。此结果支持保守处理：未知和重叠时不猜姓名、允许纠正；不能设未经多场景校准的实名阈值。

## 复现

需要自行取得上述公开音频、RTTM、dscore 脚本，以及本地构建的 `MORIQSpeakerEngine` 和单独取得的 Sortformer Core ML 模型；本目录不包含音频、标注、模型或外部评分器。设置变量后，在项目根目录执行：

```sh
python3 Tests/SpeakerDiarizationAMI/capture.py \
  --helper "$MORIQ_SPEAKER_HELPER" --model "$MORIQ_SPEAKER_MODEL" \
  --wav "$AMI_WAV" --output "$EVENTS_JSON" --start 60 --duration 60
python3 Tests/SpeakerDiarizationAMI/score.py \
  --events "$EVENTS_JSON" --reference-rttm "$AMI_RTTM" --md-eval "$MD_EVAL"
```

LS-EEND 可先用 `ffmpeg` 截取同一 60–120 秒音频，然后按 [FluidAudio CLI](https://github.com/FluidInference/FluidAudio) 的 `lseend excerpt.wav --variant dihard3 --output result.json` 生成 JSON，使用 `convert_cli.py --input result.json --output events.json --start 60 --duration 60` 转换，再运行同一个 `score.py`。`convert_cli.py` 明确不生成或估计延迟。

## 模型与设置的补充对比

检查 FluidAudio 官方 CLI，LS-EEND 默认 `--variant ami`、`--step-size 500ms`，默认 onset/offset 阈值都是 0.5；它支持通过 `--onset` 和 `--offset` 调节。这里的 0.35 只是受控敏感度实验，并非官方推荐值或生产阈值。所有结果按同一 dscore 命令、零 collar、包含重叠评分；CLI 使用同一公开文件离线快速输入，不是实时延迟测试。

第二个会议为 AMI **ES2004a** Mix-Headset，来自 [AMI 官方下载](https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Mix-Headset.wav)，完整 WAV SHA-256 `3e2560b19bee6952c7c7ce041b0f1ea8a7ea9468044c4eea79d2a2c67e24ab0f`；参考来自同一 AMI setup 提交的 `only_words/rttms/test/ES2004a.rttm`，SHA-256 `9869c6146c2fd9595403edb36c2caeda65c12ffa2c0af4ce48d6814b673fd5a9`。第二场会议的 60–120 秒参考中两位说话人分别约 36.72 秒和 4.60 秒；尽管该片段在 setup 的 test 划分，模型训练细节和独立性仍需谨慎核实。

| 会议与片段 | 模型 / onset、offset | 漏检 | 误报 | 混淆 | DER |
| --- | --- | ---: | ---: | ---: | ---: |
| ES2002a 60–120 s | LS-EEND DIHARD3 / 0.5 | 11.91 s | 0.53 s | 0.57 s | 24.79% |
| ES2002a 60–120 s | LS-EEND DIHARD3 / 0.35 | 10.91 s | 0.73 s | 0.77 s | 23.65% |
| ES2002a 60–120 s | LS-EEND AMI / 0.5 | 3.77 s | 0.59 s | 0.28 s | 8.84% |
| ES2002a 60–120 s | LS-EEND AMI / 0.35 | 3.01 s | 0.83 s | 0.48 s | 8.23% |
| ES2004a 60–120 s | LS-EEND DIHARD3 / 0.5 | 14.18 s | 0.86 s | 0.92 s | 38.63% |
| ES2004a 60–120 s | LS-EEND DIHARD3 / 0.35 | 10.20 s | 3.68 s | 1.12 s | 36.30% |
| ES2004a 60–120 s | LS-EEND AMI / 0.5 | 4.32 s | 1.20 s | 0.59 s | 14.79% |
| ES2004a 60–120 s | LS-EEND AMI / 0.35 | 3.62 s | 1.60 s | 0.79 s | 14.55% |
| ES2004a 60–120 s | Sortformer v2.1 / 默认 | 14.04 s | 0.48 s | 0.59 s | 36.57% |
| ES2004a 0–60 s | LS-EEND AMI / 0.5 | 9.29 s | 0.91 s | 0.00 s | 50.30% |
| ES2004a 0–60 s | LS-EEND DIHARD3 / 0.5 | 10.22 s | 1.04 s | 1.94 s | 65.09% |
| ES2004a 0–60 s | Sortformer v2.1 / 默认 | 7.04 s | 0.44 s | 4.15 s | 57.35% |

ES2004a 的 0–60 秒有三位参考说话人（约 1.7、9.4、9.2 秒），两个 LS-EEND 变体均只输出两个非空槽位；整体错误率明显高于同一会议的后一片段。中文四人公开样本没有逐帧人工真值，AMI 模型仅输出 1 槽 / 11.5 秒，不能据此计算 DER，但不支持将 AMI 专用变体作为通用默认。

对 ES2004a 60–120 秒另用 `StreamingLSEEND` 的官方 `process(samples:)` 每 100 ms 实时输入、结束调用 `finalizeSession()`，使用本地 AMI 500ms Core ML 模型及默认阈值：DER 14.52%、漏检 4.91 秒、误报 1.09 秒、混淆 0 秒。它只输出一个槽位；两位参考说话人中较少发言者约 4.60 秒几乎全部漏掉，低混淆不能当作准确区分多人。六个最终片段输出相对模型自身片段末尾的延迟中位 1.357 秒、最大 1.515 秒，最大输入调度落后 0.0124 秒；不含模型加载、ASR、翻译或 UI。不同输入方式使该结果与离线 CLI 仅供方向性对照。

```sh
cd Tests/SpeakerDiarizationAMI/StreamingLSEEND
MORIQ_FLUIDAUDIO_SOURCE=/path/to/pinned/FluidAudio swift build -c release
cd ../../..
python3 Tests/SpeakerDiarizationAMI/capture.py --helper /path/to/LSEENDStream \
  --model /path/to/ls_eend_ami_500ms.mlmodelc --wav "$AMI_ES2004_WAV" \
  --output "$EVENTS_JSON" --start 60 --duration 60
python3 Tests/SpeakerDiarizationAMI/score.py --events "$EVENTS_JSON" \
  --reference-rttm "$AMI_ES2004_RTTM" --md-eval "$MD_EVAL"
```

这些结果不足以选择通用默认模型或校准人名匹配门限。保守方案仍是标为未知、允许用户纠正，先在多说话人、非 AMI、中文、重叠及真实使用设备上扩展盲测；降低阈值虽可降低漏检，也可能增加误报与混淆。

## Sherpa-ONNX 离线候选对照

采用 [Sherpa-ONNX](https://github.com/k2-fsa/sherpa-onnx) 1.13.8 官方离线分离接口，pyannote segmentation 3.0 ONNX（转换模型版本 `9403a6902bb58e3d5ae8c7e77c3422de279db2e0`，SHA-256 `220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079`）和中英文 CAM++ ONNX（版本 `1a64735d2ab8c9b005101d5b0deff78c148248c0`，SHA-256 `945bcefe95672434d6ecf4c45bd0464d7e82be77d55985d0ec2f3253638110e1`）。使用默认聚类阈值 0.5、自动人数；本机 CPU 单线程，结果仍按上文人工标注、零 collar、含重叠评分。

| ES2004a | 漏检 | 误报 | 混淆 | DER | 输出人数 | 离线处理耗时 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0–60 s | 7.00 s | 2.07 s | 6.91 s | 78.81% | 7（参考 3） | 1.55 s |
| 60–120 s | 4.63 s | 1.55 s | 0 s | 14.95% | 2（参考 2） | 2.41 s |

```sh
python3 -m pip install 'sherpa-onnx==1.13.8' numpy
python3 Tests/SpeakerDiarizationAMI/sherpa_offline.py \
  --wav "$AMI_60S_PCM16_WAV" --segmentation "$SEGMENTATION_ONNX" \
  --embedding "$CAMPLUS_ONNX" --source-start 0 --output "$EVENTS_JSON"
python3 Tests/SpeakerDiarizationAMI/score.py --events "$EVENTS_JSON" \
  --reference-rttm "$AMI_ES2004_RTTM" --md-eval "$MD_EVAL"
```

第二段使用对应截取的 60 秒 WAV 和 `--source-start 60`。模型来源分别为 [segmentation ONNX](https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0) 和 [CAM++ ONNX](https://huggingface.co/echo-hello/speech_campplus_sv_zh_en_16k-common_advanced-onnx)；第三方 ONNX 转换与发行许可需要单独审计。以上是离线实验，耗时不代表流式延迟；样本有限，也未验证中文带人工说话人标注的录音、其他设备或姓名识别。第一段过度分裂，不足以作为直接替换当前实现的依据。
