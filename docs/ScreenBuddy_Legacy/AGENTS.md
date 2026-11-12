# ScreenBuddy — Codex Project Instructions

## Read first

Before coding, read:
- `01_DECISIONS.md`
- `02_PRODUCT_PRD.md`
- `03_UI_UX_SPEC.md`
- `04_BRAND_SPEC.md`
- `05_TECH_ARCHITECTURE.md`
- `06_IMPLEMENTATION_GUIDE.md`
- `07_PRIVACY_SECURITY.md`
- `08_BUSINESS_AND_POLICY.md`
- `09_CODEX_TASK_BREAKDOWN.md`
- `11_RISKS_AND_OPEN_ITEMS.md`

## Non-negotiable product rules

1. Native macOS app. Do not use Electron.
2. Menu bar app. All settings live behind the top menu bar item.
3. Main assistant is completely hidden until the global hotkey is pressed.
4. Main UI is one compact rounded dialog at bottom-center. No logo, title bar, toolbar, status row, or settings gear inside the dialog.
5. Long answers must scroll; never clip content.
6. Brand mark must follow `assets/brand_board_user_selected.png`: black `#000000` panel + cobalt `#2563FF` offset panel + ScreenBuddy wordmark. Do not invent a new logo.
7. Menu bar mark is monochrome, no surrounding square.
8. Screen capture is user-authorized. Default is on-demand. Live is explicit opt-in and visible in the menu bar.
9. No cloud token proxy and no ScreenBuddy-paid model usage.
10. Use only official SIWC OAuth and Codex App Server integration. Never read private cookies/session caches or reverse-engineer private endpoints.
11. Do not gate access to ChatGPT plan usage behind Pro. Commercial eligibility is not confirmed; do not implement payments or claim compliance until explicitly cleared.
12. No MCP server, no computer control, no voice, no cloud sync in V1.

## Engineering rules

- Use Swift Concurrency and modular services.
- Keep screen capture, auth, Codex transport, context assembly, persistence, and UI separated.
- Use protocols and test doubles for system services.
- No secrets or screen contents in logs.
- All background work must be cancellable.
- Stop and release SCStream on stop/quit/permission revocation.
- Build and test after every task. Report actual output, not guesses.
- Do not claim a feature works on all apps unless tested.
- Do not add extra product scope without asking.
