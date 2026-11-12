# 参考资料（官方文档）

核对日期：2026-11-09。开发时仍需查看最新版本，不要把协议示例硬编码成永远不变。

## Apple

- ScreenCaptureKit 总览：<https://developer.apple.com/documentation/screencapturekit>
- SCScreenshotManager：<https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager>
- SCContentSharingPicker：<https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker>
- SCStream：<https://developer.apple.com/documentation/screencapturekit/scstream>
- Vision：<https://developer.apple.com/documentation/vision>
- RecognizeTextRequest：<https://developer.apple.com/documentation/vision/recognizetextrequest>
- NSStatusItem：<https://developer.apple.com/documentation/appkit/nsstatusitem>
- NSPanel：<https://developer.apple.com/documentation/appkit/nspanel>
- NSVisualEffectView：<https://developer.apple.com/documentation/appkit/nsvisualeffectview>
- Accessibility API：<https://developer.apple.com/documentation/applicationservices/accessibility>

## OpenAI / Codex / SIWC

- Codex App Server：<https://learn.chatgpt.com/docs/app-server>
- Codex App Server + SIWC ChatGPT plan usage：<https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server>
- SIWC 开源应用集成 Cookbook：<https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt>
- SIWC Terms：<https://openai.com/policies/sign-in-with-chatgpt-terms/>
- SIWC Quickstart：<https://developers.openai.com/siwc/quickstart>
- Codex 开源仓库：<https://github.com/openai/codex>

## 关键官方事实摘要

1. Apple 推荐用 `SCContentSharingPicker.shared` 让用户选择共享内容；ScreenCaptureKit 支持窗口/显示器过滤和持续采集。
2. Vision `RecognizeTextRequest` 可在本地做文字识别。
3. Codex App Server 支持 stdio JSONL JSON-RPC、thread/turn 和流式事件；`turn/start` 输入支持 `localImage`。
4. SIWC Cookbook 的开源/本地路线有 host ID、OAuth/PKCE、token exchange 和本地凭证保存流程。
5. Codex App Server 的 SIWC 专页说明可以把 OAuth access token 通过 `ACCESS_TOKEN` 环境变量传给本地 app-server，并配置 Responses provider。
6. SIWC Terms 要求 plan usage 不能被转售/共享；请求必须来自用户本地或其控制的运行环境；后台请求要明确授权；用户必须能够不付费、不升级应用就使用 ChatGPT plan 连接能力。
7. OpenAI Cookbook 当前说明，付费或远程托管应用在提供 ChatGPT plan usage 前需要申请资格。ScreenBuddy 的 Pro 收费边界需书面确认。
