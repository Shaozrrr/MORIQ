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
