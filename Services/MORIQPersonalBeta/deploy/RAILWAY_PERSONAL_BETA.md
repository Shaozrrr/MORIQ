# MORIQ 个人 / 好友在线服务准备

仅供自己和受邀好友使用；没有注册、公开试用或自助签发入口。每个人使用单独的、短期 MORIQ 应用会话，不能把语音或翻译服务商密钥放进客户端。这里是可审查的部署准备，**不是已部署或已完成生产验收的服务**。

## 启动前提

- 使用独立 Railway 服务和持久卷，单实例；不复用其他项目的变量或数据库。源码根目录为 `Services/ManagedAI`，Dockerfile 为 `Dockerfile.personal`。
- Railway 官方说明卷由 root 挂载；本镜像默认非 root，若卷权限不允许读取和写入，需依照 [Railway 卷文档](https://docs.railway.com/volumes) 配置 `RAILWAY_RUN_UID=0` 并检查实际属主。在卷内创建服务用户拥有的私有目录（例如 `/data/moriq`，权限 0700），数据库和锁文件必须只允许服务进程用户访问。
- 服务停机期间，使用 `provision_personal_beta.py` 初始化一次全局每日请求数和音频秒数预算，再为每位使用者创建独立、到期的会话。输出文件必须在当前用户拥有的 0700 目录，文件创建时为 0600，程序不打印令牌，也不接收服务商密钥。
- 首次在隔离环境准备数据库后，安全地将**数据库文件**放入新卷的私有路径；会话明文只通过私密渠道交给对应使用者，在其 MORIQ 通用设置中保存至钥匙串。不要把明文会话放进 GitHub、应用包、环境变量或聊天。后续切勿通过覆盖运行中的数据库来重置用量；应停机、备份并按安全运维流程处理。
- 需要配置 `PORT`（由 Railway 提供）、`RAILWAY_VOLUME_MOUNT_PATH`（由卷提供）、`MORIQ_ACCOUNT_DB`、`MORIQ_ACCOUNT_REQUESTS_PER_MINUTE`、`MORIQ_RAILWAY_STAGING_ACK`、`MORIQ_PROVIDER_SECRET_SEALED_ACK` 和服务端语音凭证。自动翻译还需显式 beta 开关、确认值与服务端翻译凭证。服务商密钥通过托管平台的密封变量安全输入，严禁写入镜像、源码或客户端；ACK 只是运维声明，程序不能验证平台是否真的已密封。
- 秒数与请求数限制不是美元账单上限。上线前需检查供应商的费用限制、告警与余额，确认并发和超限行为；Soniox 官方说明费用上限可能有短暂生效延迟，可能产生超出部分的费用。

## 明确配置清单

下面是当前代码识别的配置；`<安全输入>` 是占位说明，绝不能将实际值写入此文件。初始限额仍需结合人数、预计使用时长与可接受费用审定。

| 配置 | 值或来源 |
| --- | --- |
| `PORT` | Railway 自动提供 |
| `RAILWAY_VOLUME_MOUNT_PATH` | Railway 连接独立卷后自动提供，例如 `/data` |
| `MORIQ_ACCOUNT_DB` | 卷内私有目录中的数据库绝对路径，例如 `/data/moriq/accounts.db` |
| `MORIQ_RAILWAY_STAGING_ACK` | `authenticated-single-instance-not-public-release` |
| `MORIQ_PROVIDER_SECRET_SEALED_ACK` | `1`；只代表运维已检查，不是自动核验 |
| `MORIQ_ACCOUNT_REQUESTS_PER_MINUTE` | 1–60 的整数；计数包含识别连接及翻译请求 |
| `MORIQ_GUEST_BETA_ENABLED` | `0` 或不设置；设为 `1` 将拒绝启动 |
| `MORIQ_SPEECH_PROVIDER_KEY` | 语音服务商密钥；Railway 服务端密封变量安全输入 |
| `MORIQ_CAPTION_AUTO_TRANSLATION_BETA` | `1` 才开启翻译；默认 `0` |
| `MORIQ_CAPTION_AUTO_TRANSLATION_ACK` | `deepseek-server-side-bounded`，仅翻译开启时需要 |
| `MORIQ_DEEPSEEK_PROVIDER_KEY` | 翻译服务商密钥；仅翻译开启时从 Railway 密封变量安全输入 |
| `RAILWAY_RUN_UID` | 如果卷属主使非 root 无法读写，按 Railway 文档设 `0` |

测试可先采用全局每日 2,500 次请求、7,200 秒音频，每位用户每日 600 次请求、1,800 秒音频、每分钟 30 次请求；这些只是可调整的保护阈值，翻译调用也会消耗请求数，不能据此推算实际费用。单条 session 最长 7 天，过期需重新安全发放。无论怎样配置，供应商侧费用上限和实际账单仍需另行核对。

## 本地安全初始化示例

以下数值仅展示格式，实际应按参与人数、预期时长和费用选择；全局与个人限制必须相互匹配。先创建仅当前用户可访问的私有目录，再在停止服务的环境执行（不要将服务商密钥粘贴在命令行）：

```sh
python deploy/provision_personal_beta.py init --database /private/path/accounts.db --daily-requests 120 --daily-speech-seconds 1800
python deploy/provision_personal_beta.py issue --database /private/path/accounts.db --account friend-1 --daily-requests 60 --daily-speech-seconds 900 --ttl-seconds 604800 --output /private/path/friend-1.session
```

全局初始化使用一次性插入，不能通过重跑来覆盖；重复账号和已有输出文件会被拒绝。此工具使用与服务相同的独占锁，服务运行中拒绝修改。删除会话文件不会撤销服务器上的会话；应通过受信运维途径调用 `SessionIssuer.revoke`，并完成服务端撤销与客户端失效验收。

## 最短验收顺序

1. 先使用 `Dockerfile.fake` 和全零合成音频验证网络、证书、账户与客户端；假服务不能使用真实屏幕、系统音频或供应商密钥。
2. 确认真实服务的持久卷、密钥、供应商费用限制与私密会话交付后，才进行一次短、受控、可计数的真实字幕测试；明确记录发送内容与服务商。
3. 检查好友凭证隔离、过期/撤销、超限、断线关闭、服务重启后额度保留、翻译错误和拒绝 guest 注册。检查日志不包含凭据、音频或字幕；失败时停止开放服务。
4. 真正的 Apple 签名、公证、Gatekeeper、安装、启动和回退需在最终安装包上单独验收。不要在这些检查前覆盖现有应用或宣称他人下载即可使用。

## 无 CLI 首次初始化独立卷

以下只针对全新、专用于 MORIQ 的空卷；先使用合成凭据验证，切勿对已有数据库重试或清空卷。首次初始化部署不连接任何语音、翻译供应商，也不对外提供服务。

1. 在本机私有目录使用上述 `init` 和 `issue` 创建账户与个人会话。然后执行 `python deploy/export_bootstrap_seed.py --database /private/path/accounts.db --output /private/path/bootstrap-seed.json`。seed 只有会话的 SHA-256 哈希和限额，不含会话原文或供应商密钥；文件仍应私密保存，不要提交或发到聊天。有效时长是从卷初始化时间起计算，因而应尽快完成部署。
2. Railway UI 为专用服务挂载独立 `/data` 卷，设置单实例。按需设置 `RAILWAY_RUN_UID=0`；禁止给初始化部署设置任何供应商密钥。暂时取消 HTTP 健康检查，bootstrap 不监听网络。临时启动命令设为 `python deploy/bootstrap_personal_volume.py`。
3. 在 Railway UI 设置临时密封变量 `MORIQ_PERSONAL_BOOTSTRAP_ACK=one-time-hashes-only-no-provider`，再把本机 `bootstrap-seed.json` 的内容安全输入密封变量 `MORIQ_PERSONAL_BOOTSTRAP_SEED`。不要将 seed 复制进代码、日志或聊天。部署并检查日志仅出现 `Bootstrap completed`；若失败或中断，不要删除卷或覆盖数据库，应停止并检查原因。
4. 成功后删除两个 bootstrap 变量；启动命令改回 `python deploy/start_railway_staging.py`，并设置正式运行变量和服务端密钥。保留同一专用卷与 UID，恢复适当健康检查。确认非授权会话拒绝、用量重启保持、guest 不可用；然后才进行短时真实服务验收。

初始化脚本以独占方式创建数据库并使用锁；已有数据库（即使为中断留下的不完整文件）均拒绝覆盖。bootstrap 自身不提供 HTTP 服务，重启时会拒绝再次初始化；只有切换为正常命令才能运行。已用本机容器专用临时卷及合成数据验证，Railway 端仍需实际验收。
