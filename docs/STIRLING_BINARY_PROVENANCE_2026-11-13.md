# Stirling 转换器发行来源核验

对象：build 9 签名应用 `Contents/Resources/OfficeEngine/converter.jar`。本记录只核验转换器二进制来源，不代表完成全部依赖许可审查。

## 已核验

- Stirling Office Convert 官方 [v0.3.3 发行页](https://github.com/Stirling-Tools/Stirling-Office-Convert/releases/tag/v0.3.3) 指向提交 `68bd2ad`。GitHub 发行资产 API 对 `stirling-office-convert-cli.jar` 报告的 SHA-256 为 `87a650110cb1ac2bd52fab64d22bdfe2ab4d4c17118e76e491900afb48b3c37d`。
- 本地 `Vendor/OfficeEngine/converter.jar` 与 build 9 app 内对应文件分别计算 SHA-256，均为上述值。源码工作区及签名包里的二进制与上游发行资产的字节摘要一致；无法由摘要单独证明上游构建可复现。
- `CONVERTER-LICENSE` 在源码工作区与 build 9 app 内的 SHA-256 均为 `94838a9a135b813032c95d85f356e0605a0ec337ab84de422d13cac237e20ffb`。
- 上游 v0.3.3 源码压缩包已从 GitHub API 取得；内容路径前缀为 `Stirling-Tools-Stirling-Office-Convert-68bd2ad/`，该文件 SHA-256 为 `cce8a89d2ace58291a7c8bc76191eec80bc190570d13fa5640d175f0ab143518`。文件已上传 MORIQ GitHub 发行草稿，远端摘要一致；草稿尚未公开，接收者目前不可取得。它也不能替代对构建依赖源码的逐项核对。
- JAR 中存在 31 个 `META-INF/licenses/` 目录和 41 个 Maven `pom.properties`。这些数字不能直接一一匹配或证明许可证齐全。

## 谨慎解释

对 17 个待核 Maven 坐标下载的原始 JAR，部分同路径 class 与打包 CLI 不同，部分缺失。上游 CLI 本身与 MORIQ 发行候选逐字节摘要一致，因此不能把该差异归因于 MORIQ 自行修改；打包/裁剪或重编译可能造成差异，原因仍须由上游构建过程确认。此前获取的对应 Maven 版本 `sources.jar` 是候选材料，不能凭相同坐标断定已覆盖所有实际打包类或证明完全对应。

## 未完成

- 完成 Maven 坐标、内嵌许可/NOTICE、上游实际构建与对应源码的逐项映射；核对无匹配许可目录的依赖、继承父 POM 的条款及适用的源码提供方式。
- 静态链接 FFmpeg 的本地构建与重链接材料仍未作为完整材料向发行接收者提供；核对实际交付和适用义务。FFmpeg 官方[发行说明](https://ffmpeg.org/legal.html)提出动态链接和提供对应源码等合规检查建议；是否可采用其他方式及具体义务需针对实际发行物判断。
- 复查 LibreOffice、JRE、Pandoc、语音及其他随包组件的来源、对应源码和告知；构建最终公开版本后重新核验。当前发行草稿未公开。

复核命令：

```sh
gh api repos/Stirling-Tools/Stirling-Office-Convert/releases/tags/v0.3.3 --jq '.assets[] | {name,digest}'
shasum -a 256 Vendor/OfficeEngine/converter.jar /path/to/MORIQ.app/Contents/Resources/OfficeEngine/converter.jar
```
