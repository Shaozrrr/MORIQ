# MORIQ 本地构建与公开发行准备

`Tools/Release/moriq_release.py` 分成预检、构建、签名、封装四步。**工具不会提交公证、上传或发布**，也不会覆盖已有输出或已安装应用；签名密钥由系统钥匙串管理，脚本不包含或接收私钥。下面的公证步骤仅作人工执行说明，需要发行者在确认具体包和账号后自行执行。

## 当前状态

2026-11-12 本机 `security find-identity -v -p codesigning` 只发现 Apple Development 身份，没有有效的 Developer ID Application 身份。实际证书缺失测试确认签名步骤在创建输出目录之前失败。脚本流程只通过隔离假工具测试，未执行实际 Release 双架构构建、Developer ID 签名、DMG 封装或公证；不能当作已生成可发行包。当前机器只有 Apple Silicon，实体 Intel、真实新机 Gatekeeper、升级迁移和安装回退仍未验收。旧开发版 `local.moriq.app` 与拟发行包的 Bundle ID 和 Team ID 要提前确定，变更可能影响系统授权、钥匙串和升级识别，不能仅凭相同名字推断兼容。

## 人工操作次序

1. 确认项目版本和许可、签名身份、目标架构；取用有权限的 Developer ID Application **证书名称**，不要在命令中放私钥或密码。以下示例使用环境变量 `MORIQ_RELEASE_IDENTITY`，变量值为证书显示名称而非密钥。
2. 每步的 `--out` 必须是尚不存在的新目录，且不能位于项目源码或应用安装目录；确保磁盘空间足够。

```sh
python3 Tools/Release/moriq_release.py preflight --identity "$MORIQ_RELEASE_IDENTITY"
python3 Tools/Release/moriq_release.py build --out /absolute/path/to/new-moriq-build
python3 Tools/Release/moriq_release.py sign \
  --app /absolute/path/to/new-moriq-build/derived/Build/Products/Release/MORIQ.app \
  --out /absolute/path/to/new-moriq-signed \
  --identity "$MORIQ_RELEASE_IDENTITY" --version 1.0.0 --build-number 3
```

`build` 禁用签名、请求 `arm64 x86_64` 并检查主程序实际架构。`sign` 仅在输出副本中修改版本、对本项目编译的 FFmpeg 单独签名，再检查上游 Pandoc、JRE、LibreOffice 两架构的 Developer ID、时间戳和 hardened runtime，最后签应用并做深度验签。签名时没有使用 `--deep` 作为递归签名手段。有限的已知组件检查和 `--deep` 验签**不代表**应用 `Resources` 内所有嵌套代码都已覆盖；必须结合文件清单和公证日志进一步审查，不能依赖静默强行重签上游组件。

3. 如要让应用本身也可附票，发行者确认具体内容后，可手工用 `ditto -c -k --keepParent` 将已签名 app 打包 ZIP，使用 Apple `notarytool submit ... --keychain-profile <已配置的本机配置名> --wait` 提交；查看 `notarytool log` 及警告，接受后手工对 **app** 执行 `xcrun stapler staple` 和 `xcrun stapler validate`。这一步会把包上传到 Apple；脚本不会代为执行。应通过系统支持的安全方式事先配置凭据，勿把密码、API 私钥或令牌写进脚本或聊天。
4. 对已签名、经上述检查的应用生成本地 DMG：

```sh
python3 Tools/Release/moriq_release.py package \
  --app /absolute/path/to/new-moriq-signed/MORIQ.app \
  --out /absolute/path/to/new-moriq-dmg --identity "$MORIQ_RELEASE_IDENTITY"
```

产物 `MORIQ.dmg` 带 Applications 链接并经过本地签名；仍**未公证**。如要发行，发行者需自行决定并执行对 DMG 的 `notarytool submit`、读取日志、`stapler staple` 和 `stapler validate`，不得把本地签名成功称为公证成功。公证通过后，还需在隔离的新机/干净用户环境、Apple Silicon 和实体 Intel 上检查安装、启动、Gatekeeper、全功能、授权、数据迁移、回退及卸载，并完成全部第三方许可和源码义务审核。

Apple 官方参考：[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[Creating distribution-signed code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)、[Building a universal macOS binary](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary)。

## 本轮隔离测试

- `python3 Tests/ReleasePipeline/test_release.py`：6 项通过，假工具模拟证书、架构门禁、来源包复制、版本写入、签名与 DMG 调用，断言无 `notarytool` / 上传调用且不以 `--deep` 执行签名；不验证真实 Xcode、签名服务或 DMG 内容。
- 对不存在的真实 Developer ID 身份执行 `preflight`、`sign`，均失败；`sign` 未创建输出目录。现有安装应用和用户数据未修改。
- 若真实步骤失败，输出目录可能含不完整中间产物，不得分发；先排查日志，再选择一个新的空输出路径。工具不会自动删除用户指定目录。
