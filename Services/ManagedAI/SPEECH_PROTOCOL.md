# 托管语音网关（开发原型）

本机回环原型，不是已部署服务。真实服务商账号、产品身份签发、费用控制、TLS 部署、跨实例限流、持续计费上限和实际语音验收均未完成；不能直接用于公开运营。客户端不内置或读取服务商密钥。默认运行器只监听 127.0.0.1，不能通过更改监听地址直接作为生产服务。

客户端连接 `/v1/speech/stream`，使用 `Authorization: Bearer <用户会话令牌>`。发送 `{ "type": "start", "source": "en", "target": "zh" }`，等待 `{ "type": "ready" }` 后发送二进制 16kHz、单声道、有符号 16 位小端 PCM；推荐每包 2560 字节（80ms），服务端单包上限 6400 字节。结束发送精确文本 `{"type":"finish"}`；取消直接关闭连接。收到的 `source`、`translation` 事件有 `text`、`segment`、`final`。两种流的段号各自递增，**不保证可直接按号配对**；上游文本是增量还是完整重写，官方文档没有给出明确可依赖语义，必须用真实服务确认，不能凭模拟测试声称兼容。其他事件是 `ready`、`finished` 或无敏感信息的 `error`。任何通信都不记录文本或音频。

上游固定到官方 AST 2.0 地址，密钥仅由网关环境变量 `MORIQ_SPEECH_PROVIDER_KEY` 提供。原型暂以 `MORIQ_SPEECH_TOKEN_HASHES` 的逗号分隔 SHA-256 哈希进行本机测试身份校验。真实账号与现有 AccountStore 的生命周期、到期/撤销和配额还没整合；服务前不得使用此方式替代产品账户系统。最大音频数据对应 30 分钟，但并非真正的计费限额。无需在客户端放置固定令牌或上游凭据。

协议依据 [AST 2.0 官方文档](https://docs.volcengine.com/docs/doubao-voice/simultaneous-interpretation2-0-api-access-documentation?lang=zh) 及其页面提供的 Python 示例 protobuf；2026-11-12 下载的官方示例 SHA-256 `b8184a650c4bc7599ea9a1ae3fbba40fdc0d88c14ac9f386c10ca83192033f09`。测试使用该示例的生成类解析本实现的 start/audio 请求，及序列化真实 schema 的响应后由本实现解码。官方示例仅供协议交叉检验，没有打包进产品。

`Tests/ManagedSpeech/run.sh` 启动 Swift 客户端、回环网关和独立模拟上游，验证音频转发、字幕事件与结束、错误账户拒绝；所有令牌及音频均为虚构，未连接真实服务，未验证质量、延迟或平台计费。依赖 Python 的 `websockets` 16；产品服务器的依赖需要锁定并独立部署。

## 本机应用桥接（受限原型）

仅当 `MORIQManagedSpeechEndpoint` 明确配置、账户会话存在、用户在设置启用系统音频发送授权时才连接；缺少条件、连接中断或撤销授权时停止采集并显示原因，不静默回退。`ManagedSpeechAudioBridge` 在屏幕录制音频回调中转 16kHz PCM16、80ms 分包，发送队列满时停止而非静默丢包。由于上游 partial 合并和原译句段对应关系未证实，当前桥接只显示上游确认的最终句，原文和译文不关联写入历史，不可称逐字实时翻译。

隔离测试 `Tests/ManagedSpeechSystemAudio/run.sh` 只捕获测试进程自身播放的合成声音，实际经 ScreenCaptureKit、PCM 转换、Swift 客户端、回环网关和模拟上游得到双语最终事件；`Tests/ManagedSpeech/run.sh` 覆盖 48kHz 合成采样转换、账户令牌拒绝、断线关闭上游与授权监测回调。测试没有连接真实上游；单独的授权撤销通知测试不等于已验收实际应用的整条撤权路径。
