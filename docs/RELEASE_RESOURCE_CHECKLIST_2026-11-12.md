# MORIQ 发布资源、许可证与源码检查清单

检查时间：2026-11-12。对象为 `/tmp/moriq-font-signed-build/Build/Products/Debug/MORIQ.app` 的 `Contents/Resources`，构建号 2，`MORIQ.debug.dylib` SHA-256 为 `23dfdc6405cbd0bbd70ea5a553a6ee8f8af503470fe146606e091db6773a42a9`。这是**本机 Debug 候选快照**，不是公证发行物；构建后需对最终发行包重做检查。本清单记录证据与待办，**不作已符合许可证或已获公证的结论**。

## 已检查的本地证据

- [x] `shasum -a 256 -c Vendor/MediaEngine/SHA256SUMS`：FFmpeg 二进制及 FFmpeg、LAME、libogg、libvorbis、libvpx、libwebp、Opus 七份本地源码归档的哈希均匹配仓库清单。哈希匹配不代表这些归档与上游原始发布物已独立比对，也不代表构建可复现。
- [x] 候选的 `ffmpeg` 与 `Vendor/MediaEngine/ffmpeg` 逐字节一致；`licenses/` 包含 FFmpeg LGPL、LAME、libogg、libvorbis、libvpx、libwebp、Opus 许可文本及 libvpx 专利文本。该快照中的 FFmpeg 构建记录为静态链接、禁用 GPL/nonfree；签名后的二进制会改变，不应使用签名前二进制哈希直接断言签名版相同。
- [x] `Vortex-LICENSE.txt` 与 `Vendor/Vortex/LICENSE` 相同；`THIRD_PARTY_NOTICES.md` 与 `MORIQ/Resources/THIRD_PARTY_NOTICES.md` 相同，包含鲸鱼动画参考项目的署名和 MIT 文本。
- [x] Pandoc 许可文本与 `Vendor/Pandoc/LICENSE.txt` 相同，包内保留 `Pandoc/PROVENANCE.txt` 和双架构程序。
- [x] 两架构 LibreOffice 应用内均存在 `Contents/Resources/LICENSE`；两架构 JRE 均有 `NOTICE`，arm64 JRE 的 `legal/` 下存在 48 个模块目录。`OfficeEngine/converter.jar` 哈希为 `87a650110cb1ac2bd52fab64d22bdfe2ab4d4c17118e76e491900afb48b3c37d`；JAR 内 `META-INF/licenses/` 中可见 31 个依赖许可目录。计数不是完整 SBOM 或逐项许可审查。
- [x] 候选 `sheet-view-preserver.jar` 哈希为 `24fcba26b752d5f3a6246434acbe1b5a97916643c76f3b1403ec878131a5b093`，仓库存在 `Tools/SheetViewPreserver/SheetViewPreserver.java` 与构建脚本；尚未独立重建并比对该 JAR。

## 发行前必须继续完成

### 1. 锁定最终发布物和依赖清单

- [ ] 固定最终 app、DMG、各架构二进制的版本、构建号和 SHA-256；保留构建命令、Xcode/SDK 版本、签名证书标识及依赖锁定记录。不要把临时 Debug 包的校验值当作最终发行证据。
- [ ] 按实际链接和随包文件生成逐版本软件组成清单（SBOM），包括 FFmpeg 配置启用的库、LibreOffice 内组件、JRE 模块、Stirling 转换器 JAR 内依赖、Pandoc、Vortex、动画和自研 helper；将 JAR 内 31 个许可目录与其依赖元数据逐一核对，补齐缺失、重复或版本不匹配项。
- [ ] 最终归档中逐项验证许可、版权和 NOTICE 文本是否仍存在、内容是否对应所分发版本；检查用户能否方便找到它们。当前源码检索未发现明显的应用内“第三方许可”入口，不能以 Finder 能深入浏览 `.app` 推断用户入口已做好。
- [ ] 审核 `THIRD_PARTY_NOTICES.md` 中“本包的 MIT 许可证位于 LICENSE”及旧的 DSH 用语：确认指代的是上游作品而非无意声称整个 MORIQ 采用 MIT，并与实际分发文件一致。

### 2. 逐组件核查源码和重建资料

- [ ] **FFmpeg 及静态库**：将七份精确版本源码、配置参数、补丁、构建脚本、编译器/工具版本与实际二进制建立可核查对应关系；确认使用静态链接时适用条款及用户替换/重链接资料需求。当前工作区 `Vendor/MediaEngine` 没有发现保存的 `.o` / `.a` 重链接产物，候选 `Resources` 没有随附这些源码归档及构建说明。需决定经审核的交付方式、生成必要材料并实际验证可取得、可使用。FFmpeg 上游说明了 LGPL/GPL 配置差异及发行检查点：[FFmpeg License and Legal Considerations](https://www.ffmpeg.org/legal.html)。
- [ ] **Pandoc 3.13**：核对打包的 GPL-2.0-or-later 文本与确切构建，准备经审核的对应源码提供路径/归档及记录；包内当前仅见二进制、许可和 `PROVENANCE.txt`，后者的上游链接不能单独证明对应源码供应安排已完成。版本源码和版权文件：[Pandoc 3.13 COPYRIGHT](https://github.com/jgm/pandoc/blob/3.13/COPYRIGHT)。
- [ ] **LibreOffice 26.8.2.2**：比对实际两架构应用、原始归档哈希和上游签名；获取并留存对应完整源码、构建及修改记录和其他随附组件的许可告知，明确接收者如何取得所需内容。项目说明中有来源与归档哈希，但本轮未独立取得并验证匹配源码。上游说明其发行涉及 MPL 2.0 及其他许可证：[LibreOffice licenses](https://www.libreoffice.org/licenses/)。
- [ ] **Temurin JRE 25.0.5+8**：核对两架构二进制及原始归档、完整 `legal` 和 `NOTICE`，识别对应 OpenJDK 源码版本、构建与可取得方式；逐项核对模块/附加许可。[Adoptium FAQ](https://adoptium.net/docs/faq) 将 Temurin 二进制说明为 GPLv2 加 Classpath Exception，具体发行仍需结合随包各项文本审核。
- [ ] **Stirling Office Convert 0.3.3**：核对上游发布包/源码与本地 JAR 哈希、记录本地修改；对内嵌依赖逐一核对许可及 NOTICE。项目源代码许可见 [Stirling Office Convert LICENSE](https://github.com/Stirling-Tools/Stirling-Office-Convert/blob/main/LICENSE)，不能仅凭顶层 MIT 忽略其依赖。
- [ ] **Vortex 和动画**：以固定提交验证源码、MIT 文本和版权归属；核对鲸鱼参考/改作的署名、原作者和许可。仓库 `Vendor/Vortex/PROVENANCE.txt` 已记录 Vortex 提交 `c9efc55beaf0837a8806f06615085365a3257b6d`。
- [ ] **自研 helper**：保留 `Tools/SheetViewPreserver` 源码与构建环境，隔离重建并对照功能及哈希；确认没有遗漏新增依赖。

### 3. 用户可取得性与最终验收

- [ ] 形成版本化的第三方告知及源码提供说明，写明每个适用组件的精确版本、来源、变更、许可文本和可取得材料；测试接收者实际能访问且归档可核验。若涉及托管或对外发布，须另行明确发布位置并由发行者执行；本轮没有上传。
- [ ] 对最终签名包及 DMG 再运行资源清单、签名/架构、许可与来源检查；验证不是只检查仓库。保留证据与审批记录，必要时由负责发行的专业人员审查具体义务。
- [ ] Developer ID、Apple 公证、实机安装、回退和 Intel 硬件验收仍独立未完成；流程见 `RELEASE_PIPELINE_2026-11-12.md`。不要把上述本地资源检查当作这些验收。

复查本地资源的最小命令（仅针对上述当前候选；路径变化需先确认）：

```sh
shasum -a 256 -c Vendor/MediaEngine/SHA256SUMS
cmp Vendor/Vortex/LICENSE /tmp/moriq-font-signed-build/Build/Products/Debug/MORIQ.app/Contents/Resources/Vortex-LICENSE.txt
cmp MORIQ/Resources/THIRD_PARTY_NOTICES.md /tmp/moriq-font-signed-build/Build/Products/Debug/MORIQ.app/Contents/Resources/THIRD_PARTY_NOTICES.md
cmp Vendor/Pandoc/LICENSE.txt /tmp/moriq-font-signed-build/Build/Products/Debug/MORIQ.app/Contents/Resources/Pandoc/LICENSE.txt
```
