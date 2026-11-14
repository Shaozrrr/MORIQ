# Railway 个人与好友：零供应商调用的连通性检查

此入口仅供后续在独立 Railway 服务上检查 HTTPS/WSS、客户端认证和字幕显示。它在服务内创建本机假上游与固定译文，**不会连接语音或翻译供应商**，也不能验收真实识别、质量、费用、存储或正式安装体验。数据库为临时目录，重启重置，不应作为真实服务的预算保护。

客户端只能发送测试生成的全零 PCM；不要把麦克风、系统声音或其他真实内容发送给此服务。假上游会拒绝非零音频，但这个检查发生在音频到达服务之后，并不能防止网络传输。不要将真实用户导入此测试。

启动需要 `MORIQ_FAKE_BETA_ACK=synthetic-no-provider-data`、Railway 的 `PORT`、`MORIQ_FAKE_SESSION_HASHES`（1–10 个不同的 SHA-256 十六进制哈希，用逗号分隔）、`MORIQ_FAKE_SESSION_EXPIRY_UNIX`（60 秒至 7 天内的 UTC Unix 秒）。只接受每个人独立的随机应用会话哈希；明文会话只应安全交付对应人并保存在客户端 Keychain，不得写入包、聊天、源码或日志。该哈希不是语音/翻译供应商密钥。

入口明确拒绝包含 `MORIQ_SPEECH_PROVIDER_KEY`、`MORIQ_DEEPSEEK_PROVIDER_KEY` 或 `MORIQ_DEEPL_PROVIDER_KEY` 的环境。不能与已有其他项目共享配置；尚未连接 Railway、未上传或部署。安装 `deploy/requirements.txt` 后，可用 `python deploy/start_railway_fake.py` 在服务目录启动。`GET /healthz` 仅表示进程可响应。

本机可重复检查：`python3 -m unittest discover -s Tests/ManagedDeployment -p 'test_railway_fake.py'`；测试启动实际子进程，验证无效凭据、合成 PCM、原文与假译文。公网 WSS、证书、实际客户端和资源费用需要部署后单独验收。
