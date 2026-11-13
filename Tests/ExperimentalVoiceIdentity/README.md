# 说话人声纹命名隔离实验

对照 [whosaid](https://github.com/sblattj/whosaid) 的用户命名、余弦匹配及低置信度保留匿名和 [diarize](https://github.com/elien666/diarize) 的跨录音匹配、删除与纠错流程，使用 FluidAudio 固定提交 `d653a34a620c013febd7530427b4963ae18064b2` 的 CAM++ 本机嵌入模型。此代码是隔离测试，不接入 MORIQ，不做实时姓名判断。

调用者显式提供本地模型和公开语音片段，不使用麦克风、不下载模型或调用在线服务；Swift 包构建可能需要取得上游构建依赖。`0.wav`、`2.wav` 为同一公开朗读者的不同录音，`1.wav`、`3.wav` 为另一朗读者的不同录音，来源和制作方式见 [声纹研究](../../docs/SPEAKER_VERIFICATION_RESEARCH_2026-11-13.md) 与 [说话人分离研究](../../docs/SPEAKER_DIARIZATION_RESEARCH_2026-11-13.md)。

```sh
MORIQ_FLUIDAUDIO_SOURCE=/absolute/path/to/FluidAudio \
MORIQ_CAMPLUS_MODEL=/absolute/path/to/campplus-model-directory \
MORIQ_PUBLIC_CLIPS=/absolute/path/to/public-clips \
MORIQ_TEST_MATCH_THRESHOLD=0.7 MORIQ_TEST_MARGIN=0.1 \
sh Tests/ExperimentalVoiceIdentity/run.sh
```

测试显式命名注册、相同及不同说话人、短音频拒绝、不确定竞争返回未知、临时注册表重读与删除、不同模型版本不匹配。两项数值只是本测试参数，不是生产阈值；两个说话人、少量干净样本不能推算误认率，也不能代表带噪声、重叠或跨设备表现。临时数据只包含公开音频的嵌入，目录与文件分别设 0700 / 0600 并在退出时删除；这是测试用存储，不是经安全审查的产品声纹库。CAM++ Core ML 转换模型标为 beta，SDK、模型与权重的发行许可必须分别核实。
