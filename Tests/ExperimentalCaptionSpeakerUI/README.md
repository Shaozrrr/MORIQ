# 实验性说话人字幕界面

仅在 `DEBUG` 且启用 `MORIQ_SPEAKER_EXPERIMENTAL` 编译条件的单路系统声音字幕中，额外设置 `MORIQ_EXPERIMENTAL_SPEAKER=1` 及以下变量后接线：

- `MORIQ_WHISPER_HELPER`、`MORIQ_WHISPER_MODEL`、`MORIQ_SPEAKER_HELPER`、`MORIQ_SPEAKER_MODEL`：已在本机准备的绝对路径；不会自动下载。
- `MORIQ_SPEAKER_MINIMUM_COVERAGE`、`MORIQ_SPEAKER_MAXIMUM_COMPETITION`：显式提供的实验阈值，须满足 `0 ≤ maximum < minimum ≤ 1`；此处没有发行默认值。

不设置开关时不启用。开启时若路径、语言或阈值无效会显示错误，不回退成伪归属；双音源同传模式明确不支持此实验。只在识别窗口和说话人区间均为 final 时展示匿名编号，覆盖不足、冲突或分离不可用保留未知；编号不是姓名，不跨会话识别。窗口关闭、停止或失败会清除实验结果。连续同一标签会合并展示，但跨窗口重复词、多人重叠和短发言仍可能出错。

离屏真实管线测试由 `run.sh` 在临时目录编译并运行，调用两个本机助手，不启动系统/麦克风采集。除上述变量，还需提供明确授权的公开 WAV 路径 `MORIQ_PUBLIC_SPEAKER_AUDIO` 和本机 `MORIQ_TEST_FFMPEG`；例如公开 LibriSpeech 双人交替拼接样本。可选 `MORIQ_SPEAKER_PREVIEW_PATH` 输出离屏预览，仅用于公开样本。脚本确认真实路径可以产生至少两个匿名标签，停止与重新打开不会显示上一会话结果；它不能证明实时设备准确率或产品满足发行条件。
