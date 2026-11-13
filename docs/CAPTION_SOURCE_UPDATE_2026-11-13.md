# 字幕声音来源及验收（2026-11-13）

- 产品对照：Apple Live Captions 和 AirTranslate 支持电脑声音、麦克风；Windows Live Captions 默认关闭麦克风。MORIQ 选择单一声音来源，默认为系统声音；麦克风需主动选择并给予系统权限。两路同时采集、设备选择及回声消除尚未实现和验收。
- 麦克风权限已加入首次权限页；在线系统声音与麦克风分别需要对应传输授权，撤销后停止。麦克风路径尚未在本机实际授予权限并录入真实语音，不能称为通过现场验收。
- `Tests/CaptionContinuity/run.sh` 检查语音来源不交叉、片段、历史与过期译文；`Tests/ManagedSpeech/run.sh` 检查模拟流及授权撤销。`Tests/CaptionContinuity/run-continuous.sh` 通过本机英语到中文连续输入翻译。
- `MORIQ_CAPTION_TEST_SECONDS=20 bash Tests/LiveCaptionsIntegrated/run.sh` 用测试进程的合成声音验证系统音频到本机双语视图：1019 个音频缓冲、9 次双语更新、2 条历史，未报错。此测试不包含麦克风、真实会议、长时间、远程在线服务或多设备。
- 同一隔离链路延长至 90 秒：4523 个音频缓冲、46 次双语更新、11 条历史，最后一次更新距结束 1 秒；9 次资源采样首值约 342.8 MiB、峰值约 363.3 MiB，结束后无测试进程残留。重复合成声音不代表真实语音翻译质量，也不是数小时稳定性证明。
- 远程语音由原文和译文独立事件流组成；当前未验证两者片段能准确配对，在线模式的译文历史不能视为完整。云端尚未部署，且并未证明整体体验达到豆包或其他竞品。

参考：[AirTranslate](https://github.com/himomohi/AirTranslate)、[live-translate](https://github.com/mtib/live-translate)、[Microsoft Live Captions](https://support.microsoft.com/en-us/accessibility/windows/use-live-captions-to-better-understand-audio)、[Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)。
