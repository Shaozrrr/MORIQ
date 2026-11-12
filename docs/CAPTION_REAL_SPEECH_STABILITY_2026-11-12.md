# 实时字幕中间结果稳定性验证

测试使用 whisper.cpp 官方公开 JFK 样本（`samples/jfk.wav`），以项目随包的 base 模型及辅助程序读取音频，记录到的中间识别先后包含 `And so my fellow America`、`And so my fellow Americans ask`、`And so my fellow Americans ask not what you are coming from.`，最终结果为 `And so my fellow Americans, ask not what your country can do for you.`。测试样本来自 https://github.com/ggml-org/whisper.cpp/tree/master/samples ，不是用户的声音。

旧翻译路径会直接翻译正在被识别器改写的短句，可能把错误的 `coming from` 呈现给用户。新路径对英文中间结果先取相邻两次识别相同的完整词前缀；最终段仍全文翻译。没有 final 事件时，静默 1 秒后采用最新完整识别结果，避免末词永久缺失。状态回归以实测上述识别序列确认错误尾词不进入中间翻译，最终文本完整；2 秒节奏重放实际识别序列并经 macOS TranslationSession 得到包含“国家”的最终译文；180ms 连续输入系统翻译回归和历史归属测试也通过。

这是对一个真实语音样本的识别结果重放和局部语义断言，并非完整屏幕音频到字幕的时延对比或翻译质量评分；没有同豆包实测对比。两次识别的稳定等待对当前两秒步长可能增加约 2 秒中间译文延迟，尚未在嘈杂、口音、实体 Intel 或其他语种上量化。稳定前缀不能排除两次识别重复同一错误，不能保证最终识别或翻译准确。
