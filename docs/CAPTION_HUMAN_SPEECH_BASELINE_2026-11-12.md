# 字幕识别真人声音基线（隔离实验）

2026-11-12 在开发机对 [LibriSpeech 测试子集](https://huggingface.co/datasets/hf-internal-testing/librispeech_asr_dummy) validation 前 8 条进行了离线识别。语音来自同一位朗读者，不是用户音频。通过 Hugging Face 数据集服务读取原始标注和音频后，调用现有 `whisper-cli` 与多语言 `ggml-base.bin`；未启动 MORIQ、未采集系统声音、未上传声音。

本次采用小写、去标点、缩写 Mr. 归一为 mister 后按词计算编辑距离：12 个词错误 / 200 个参考词，WER 6.0%。完整单个片段离线推理计时约 0.30–0.63 秒，包含 CLI 调用和模型加载，不包含采集、等待分段、UI 或翻译延迟。该结果只反映少量干净朗读，不代表口音、多人、音乐噪声或对话表现，也不能与此前合成语音滚动窗口实验直接比较。

临时原始结果在 `/tmp/moriq-human-benchmark/results.json`，可能被系统清理。音频及标注来源可通过 Hugging Face datasets-server 的 `rows` 接口重取，参数为 `dataset=hf-internal-testing/librispeech_asr_dummy`、`config=clean`、`split=validation`、`offset=0`、`length=8`。样本固定为 `1272-128104-0000` 至 `1272-128104-0007`。

豆包对照尚未完成：本机 `/Applications/豆包浏览器.app` 为失效 Finder 替身，解析目标显示文件不存在；未安装或登录其他应用。公平验收应先取得可运行的豆包，再对双方输入同一批有授权的不同说话人、语速、背景噪声及专业术语语音，记录逐句原文 WER、译文人工评分、首字/句完成延迟、修正次数和稳定性；标明模型、设备、网络以及采集流程。不得以本基线声称达到或超过豆包。
