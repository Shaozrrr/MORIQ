# 本机与已配置在线语音：公开样本对照（2026-11-13）

调用仅限已开通的同传 2.0，不开通新服务；读取现有 Keychain 凭据后仅用于进程内 TLS，不打印、写盘或打包。两次请求分别发送公开样本 20.000 秒与 19.205 秒，共约 39.205 秒，无个人录音。服务是按量计费，已开通账户的免费额度可抵扣；官方计费文档列同传输入和文本输出分别 80 元/百万 token、输入音频约 6.25 token/秒。仅输入估约 0.0196 元、输出另计，实际扣费和余额以账单为准；非价格承诺。参见 https://docs.volcengine.com/docs/doubao-voice/billing-instructions?lang=zh 。

## 同输入语音识别小样本

LibriSpeech 两位朗读者 A0/B0/A1 与 0.4 秒间隔，19.205 秒、44 参考词，两端均按 80ms 帧近实时投喂，先后分别运行。小写、去标点、Mr. 归一化为 mister，计算整段最终识别词编辑距离；无用户语音。波形 SHA-256 `073d16da4f077f47c623f4786e2c7a3ae7d736088d2c3e01c18b1594eea36916`；获取来源和两人 ID 见 Tests/SpeakerDiarizationResearch/public_two_speaker.py。

| 实现 | 错词/参考词 | WER | 输入开始至首条非空原文 | 其他 |
|---|---:|---:|---:|---|
| 现有本机滚动 Whisper base | 5/44 | 11.36% | 2.165 秒 | 7 个部分事件，3 个完成事件 |
| 已接通在线同传 | 0/44 | 0% | 4.084 秒 | 首译文 4.316 秒；5 个完成事件，2 个句级说话人切换信号 |

首字时间从投喂开始算，包含样本起始等待、模型处理和网络，非纯推理时间；在线源句结束事件相对服务返回句末时间分别 0.886、1.245、1.120、0.873、1.623 秒，同样不代表人工标注的端到端延迟。三段清晰朗读、两人、一次运行、44 词，不能据此外推模型总体表现或证明在线方案在噪声/口音/真实会议中总是优于本机；并非翻译人工质量评估。`Tests/ManagedSpeech/compare_public_models.py --help` 有参数；脚本强制公开音频哈希、显式 `--run` 后才发请求，不输出原文或凭据。参考 A 采用 Tests/LiveCaptionsRealSpeech/README.md 所述公开行元数据，B 采用 `openslr/librispeech_asr` clean/test offset 1000 前 4 条中的首条（speaker_id 8455）；公开两人素材可按 Tests/SpeakerDiarizationResearch/public_two_speaker.py 重新取得并以相同方式拼接。

## 多人会议句级切换

AMI ES2002a Mix-Headset 60–80 秒，公开音频 SHA-256 `bd705284d4d2b1f945874361e6d9ecca8c484d10f203d25287bef62987f5f493`，人工 only_words RTTM 同 Tests/SpeakerDiarizationAMI/README.md，1× 投喂。服务返回 9 句原文和 9 句译文；首个原文/译文响应分别在输入开始 7.504/7.710 秒（其中音频初段不是连续讲话）。原文起始事件在音频时间 14.90、16.18、17.46 秒返回 `spk_chg=true`；对应译文起始事件也返回 true。人工标注在约 7.21、14.89 秒出现另一位讲话并与已有讲话重叠，17.44 秒出现第三位；14.90 和 17.46 接近标注，7.21 的重叠没有对应切换，16.18 不是明确新说话人起点。句级信号语义和人工重叠标注不完全等价，这不是精确召回率或 DER。首个切换以外 proto3 中未序列化 false 值的情况与字段不可用无法仅凭缺失断定；结果中并无稳定 speaker ID 或真实姓名。官方文档中的请求 `speaker_id` 是输出语音音色，而非识别出的身份；见 https://docs.volcengine.com/docs/doubao-voice/simultaneous-interpretation2-0-api-access-documentation?lang=zh 。

`Tests/ManagedSpeech/probe_public_ami.py --help` 为该公开样本的 opt-in 复现脚本，限制输入 WAV 哈希及 20 秒；会实际产生 API 调用并可能收费，不打印转写文本或密钥。已接通同传模型提供文本翻译和可选句级切换线索，但无法据此给个人稳定编号或姓名；其他服务的说话人分离/声纹接口不是此服务，不代表账号已经开通。此测试也不代表已搭建面向公众的在线服务。
