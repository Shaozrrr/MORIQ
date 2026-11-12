# 08｜商业模式与 OpenAI 授权边界

## 1. 用户确认的商业想法

用户希望：
- ScreenBuddy 不替用户付模型 Token。
- 用户通过自己的 ChatGPT / Codex 账户使用 AI。
- ScreenBuddy 基础 AI 接入免费。
- 收费重点放在 ScreenBuddy 自己提供的桌面增强能力，例如持续感知、上下文记忆、多窗口对比和高级本地历史。
- 不做 Token 中转、余额充值或模型代理。

## 2. 这不是“已经批准的商业模式”

必须正视 OpenAI 官方条款：

1. SIWC ChatGPT plan usage 条款写明，用户必须能够不向应用开发者付费、也不升级应用付费版本，就通过 SIWC 使用自己的 ChatGPT plan。
2. OpenAI 官方 cookbook 当前说明：ChatGPT plan usage 的自助接入面向开源项目、本地运行的个人项目和选定私有应用；如果构建付费或远程托管应用，应先申请资格。
3. Codex App Server 官方文档明确：直接使用 app-server 的 ChatGPT subscription authentication 不能用于商业或托管服务；SIWC 是新的官方路径，但商业付费产品仍需按官方流程确认资格。

所以：不能仅凭“AI 连接按钮免费、Pro 只卖持续监控”就断言收费一定没问题。需要向 OpenAI 确认：一个开源/本地运行的 ScreenBuddy，允许用户免费用 SIWC 做基本屏幕问答，同时对本地持续监控/历史等功能收费，是否符合当前 SIWC Terms 和开源路线资格。

## 3. 推荐产品层级（政策确认前仅作为假设）

### Free
- ChatGPT / Codex 连接（若资格允许）。
- 快捷键唤出。
- 主动截图问答。
- 基础连续追问。
- 基础本地 OCR（可放免费层，具体看开发成本）。
- 所有通过 SIWC 使用用户 ChatGPT plan 的基本能力不得被 Pro 付费墙拦截。

### Pro（设想，待政策确认）
- 本地持续感知和关键帧缓存。
- 最近屏幕变化记忆。
- 多窗口/跨页面比较。
- 高级本地历史搜索。
- 自定义排除规则与高级上下文管理。

价格暂不锁定。此前讨论过一次性买断约 US$19.99–29.99 的测试价，但这不是最终定价，也不能在未确认 OpenAI 商业许可前上线收费。

## 4. 两条合规发行路线

### 路线 A：SIWC 开源/本地路线

- 公开源代码和许可，满足 OpenAI 对 open-source project 的定义。
- 应用本地运行，OAuth token 本地保存。
- 免费开放通过 SIWC 使用 ChatGPT plan 的基本能力。
- 任何 Pro 收费范围先向 OpenAI 书面确认；不能将 SIWC 使用权、模型调用能力或基础屏幕问答锁进付费墙。
- 需要遵守 SIWC DevKit 许可及 OpenAI 条款。

### 路线 B：商业闭源/付费路线

- 向 OpenAI 申请商业合作/相关资格；获得明确批准前，不把 SIWC 当作正式商业产品的推理通道。
- 若无法获得 SIWC 商业许可，则商业版采用 BYOK（用户自己的 API Key）接入；用户自己承担 API 费用。
- ScreenBuddy 仍然不建设 Token 中转站。

## 5. 明确禁止

- 不能卖 ChatGPT plan 用量。
- 不能共享或池化多个用户的套餐额度。
- 不能让一个用户的订阅服务其他用户。
- 不能让 ScreenBuddy 变成一般化的 ChatGPT API 代理。
- 不能在用户不知情的情况下持续自动调用模型。
- 不能把 Codex 登录 cookie、session 或 token 缓存当作接入方法。

## 6. 开发门槛

- P0 可以做本地技术验证，不代表已获商业授权。
- 对外 Beta / 正式收费前，必须完成 OpenAI 条款审查和必要的书面确认。
- 如果商业授权未确认，不得把“Pro 持续监控收费 + SIWC 模型调用”作为既定上线方案。
