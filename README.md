# MORIQ

MORIQ 是原生 macOS 项目。当前是 M0/M1 工作原型及 M2/M3 的部分代码，不是可发布版本。保留了历史 ScreenBuddy 规格，原来的底部浅色玻璃 AI 胶囊是 MORIQ 的一个功能；旧品牌不出现在应用界面。

## 打开与构建

本机使用 `~/Applications/MORIQ.app` 启动。开发基线 macOS 15+。可打开 `MORIQ.xcodeproj` 构建；也可以在独立目录构建，避免覆盖正在运行的应用：

```sh
xcodebuild -project MORIQ.xcodeproj -scheme MORIQ -configuration Debug -derivedDataPath /tmp/moriq-build build
codesign --verify --deep --strict /tmp/moriq-build/Build/Products/Debug/MORIQ.app
```

本机 Debug 构建使用开发者签名，未公证、未准备分发，部分转换引擎依赖本机开发文件。更新应用前先退出旧实例，并验证新构建；不要直接覆盖正在运行的应用。退出入口位于菜单栏图标。

## 当前状态

转换圆盘、文件暂存架、加密剪贴板、超级截图及 AI 屏幕助手均已接入。圆盘支持部分图片、Office、PDF、音频、视频与 ZIP/TAR/TAR.GZ 归档格式；Office 转换需要本机 LibreOffice，具体覆盖和未完成项目见下文状态文件。截图支持标注、复制、OCR 和本地翻译；屏幕助手提问时将采样画面及识别文字发送给 AI 服务。介绍页面中的操作是演示，不代表跨应用验收已完成。详细已测内容与剩余限制见 `KNOWN_GAPS.md`；参考开源项目及对照标准见 `docs/GITHUB_BENCHMARK.md`。

测试转换引擎：

```sh
swiftc MORIQ/ImageConverter.swift Tests/main.swift -o /tmp/moriq-converter-tests
/tmp/moriq-converter-tests
swiftc MORIQ/ImageConverter.swift Tests/ConversionMatrix/main.swift -o /tmp/moriq-matrix-test
/tmp/moriq-matrix-test
```

测试会在系统临时目录创建并清理测试图片。详见 `KNOWN_GAPS.md`。编译日志为 `docs/build-debug.log`。交接包在 `Handoff/`，旧版规格在 `docs/ScreenBuddy_Legacy/`。
