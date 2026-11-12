# MORIQ 候选包只读审计（2026-11-12）

## 审计对象和边界

本次实际检查 `/tmp/moriq-font-signed-build/Build/Products/Debug/MORIQ.app` 和 `$HOME/Applications/MORIQ.app` 的包元数据；没有替换、启动、升级、卸载应用，也没有读取用户剪贴板、钥匙串或文档。该候选是 Debug 构建，不是交付版；临时路径可被后续构建覆盖。为了能辨别样本，候选 `MORIQ.debug.dylib` SHA-256 为 `f7bbd743012360d09a54bc9cc77bb02eafed97e849b653bbd95d8a0404e679b0`；随包 ffmpeg SHA-256 为 `ab8053d1095ac8b7ba7dbde08d248571ac1d2bbc6246d7fc9aa65c3d9ca066e8`。现有安装版主程序 SHA-256 为 `2eee617952f4a780c75bbe4093ac8fbce95df4978f0f8eb8d9616f15cde6433a`。构建后有任何变化须重新计算。

## 实际包和身份

- 候选 `codesign --verify --deep --strict` 通过；包和现有安装版的 identifier 都为 `local.moriq.app`，签名均为同一 Apple Development 身份、Team ID `448XHY4GGS`，均带 hardened runtime 标记。这只验证包签名和身份一致，不能证明权限、钥匙串或数据迁移正常。
- 对该 Debug 包运行 `spctl -a -vv` 返回 `rejected`，来源为 Apple Development。没有证明 Developer ID 分发签名、公证或 Gatekeeper 首次安装通过，不能作为对外发布包。
- 实测候选 app 主可执行文件及 debug dylib 是 **arm64**；随包 FFmpeg 为 arm64/x86_64 通用二进制，LibreOffice、Pandoc、JRE 各有两个架构版本。辅助组件双架构不等于 app 本身支持 Intel，也不等于真实 Intel 安装运行通过。Info.plist 指定 macOS 15.0 起。
- 候选总大小约 2.3 GB，资源中 LibreOffice 约 1.6 GB、PDF/Office 转换运行时约 346 MB、Pandoc 约 305 MB、FFmpeg 约 51 MB；现有安装版约 8.9 MB。新包体积将影响下载、备份及升级空间；实际安装峰值尚未测。
- 安装版与候选的展示版本均为 `0.1.0`，构建号均为 `1`；无法凭当前版本号辨别升级或回滚。应在发布流程中为每个候选建立可追踪、递增的版本和构建号。

## 随包依赖及来源证据

| 组件 | 当前证据 | 尚待核验 |
| --- | --- | --- |
| FFmpeg | 包内自报 9.0.2；构建配置禁用 GPL/nonfree/network，启用多个第三方静态库；两架构 `otool -L` 所列为系统库。`Vendor/MediaEngine/README.md`、`SHA256SUMS`、`sources`、`licenses` 保存来源、源码包和许可文本；应用内有 `Resources/licenses`。 | 验证随实际发放物的源码提供方式、静态链接的替换/重链接等具体义务，以及重建结果和许可证完整性；不能只凭构建参数宣称已满足分发要求。 |
| LibreOffice | `Vendor/OfficeSuite/README.md` 记录官方包版本 26.8.2.2、下载来源及两架构归档哈希；包内 arm64 和 x86_64 应用均存在；检查到 arm64 内含 `LICENSE`、`LICENSE.html`。源码按程序优先选用随包对应架构，之后才查本机候选路径。 | 复核最终发放包与记录的原始归档对应关系、全部依赖许可/通知与源码义务；真实 Intel 实机转换尚未验收。 |
| Office/PDF 引擎 | 记录 Stirling Office Convert CLI 0.3.3、Temurin JRE 25.0.5+8 的来源和归档哈希；转换 jar 的包内与仓库 SHA-256 相同，均为 `87a650110cb1ac2bd52fab64d22bdfe2ab4d4c17118e76e491900afb48b3c37d`。包内有转换器许可、JRE NOTICE，JAR 内可见依赖许可目录；本地工具另有 `sheet-view-preserver.jar`。 | 逐项核对 JAR 及 JRE 内依赖清单、对应版本、许可证及分发义务；核对 helper 构建来源和最终包哈希。 |
| Pandoc | 包内 arm64 运行 `--version` 返回 3.13；含两架构程序、`LICENSE.txt`、`PROVENANCE.txt`，后者记录 GPL-2.0-or-later、上游源码及归档哈希。 | 完整核查相应源码及许可分发方式；真实 Intel 环境运行和质量待测。 |
| Vortex 与鲸鱼动画 | 包内存在 `Vortex-LICENSE.txt`。`WhaleBackground.html` 注释说明参考 ASCII Sharks 并指向 `THIRD_PARTY_NOTICES.md`；仓库 `docs/ThirdParty/ascii-whales-NOTICES.md` 有上游 MIT 署名及许可证。 | 当前候选资源中未发现注释所指的 `THIRD_PARTY_NOTICES.md` 或鲸鱼专用许可证文件；需要核对最终产物的署名和许可告知是否完整并更正该引用。不能仅凭仓库文件推断用户拿到的包含有告知。 |

版本及来源证据来自仓库记录和本地可执行文件输出；本次未访问上游核验最新版本、归档真实性或许可解释。

## 升级与回退准备，不代表已执行

现有代码和项目文件的只读检索未发现明确的自动更新或回滚实现；未对所有依赖做穷尽式搜索。当前安装和候选身份相同，但签名相同本身不能证明覆盖后系统权限、Keychain 项、暂存架书签及加密剪贴板都能继续使用，也不能证明旧版可读取新版写入的数据。

在隔离环境应先准备原安装包的可校验备份、记录新旧包哈希与确切版本，验证新版本的启动、权限和数据；回退时恢复旧包并检查数据格式向后兼容。实际流程还需覆盖：复制中断、空间不足、程序运行中替换、异常退出、权限重授权、失败恢复、升级后回退以及卸载残留与用户数据保留。不得以计划步骤当作已完成的升级/回退验收。

## 2026-11-12 隔离文件升级与回退试验

执行 `python3 Tests/IsolatedUpgrade/main.py /tmp/moriq-font-signed-build/Build/Products/Debug/MORIQ.app`，对当时构建号为 `2` 的完整 Debug 候选，使用系统临时目录和自建的构建号为 `1` 的**简化旧版测试包**验证：

- 测试旧版与候选使用相同 bundle ID 和开发者 Team ID；候选经 `ditto` 拷贝后深度签名校验通过，Info.plist、主程序、debug dylib 和 FFmpeg 四项 SHA-256 与拷贝前后源包一致，构建号正确。
- 故意损坏暂存候选的 Info.plist 后，签名校验失败；旧测试包仍能验证且其主程序哈希不变。
- 模拟旧包改名为备份后、发布新包之前发生异常，按测试脚本恢复旧包；随后完成一次同卷发布与回退，旧测试包签名、主程序哈希和版本号恢复。临时目录在进程结束时删除。

这是测试脚本实现的隔离文件事务，不是产品已有安装器或自动更新功能；旧包为简化测试包而非用户安装版。没有启动任何测试应用，没有修改安装版、用户权限、钥匙串或数据，故不能证明真正升级中的授权、Keychain、剪贴板数据、书签迁移或旧版兼容性。也未验证磁盘写满/断电、跨卷替换、真实安装器、系统 Gatekeeper 和强制退出；源码在其他时刻重建后须重新执行并记录新候选哈希。


## 后续修正

上表为最初检查时的快照：鲸鱼动画署名与许可证现已随构建资源打包为 `THIRD_PARTY_NOTICES.md`，并与源文逐字节比较；当前候选构建号已从 1 调整为 2。上述动作不等同于全部第三方许可证义务或公证已完成。
