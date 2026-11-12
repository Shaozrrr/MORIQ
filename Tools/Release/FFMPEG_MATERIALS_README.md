# MORIQ FFmpeg 候选及可重链接材料

这是独立构建候选，不会自动安装、覆盖 MORIQ、签名分发、公证或上传。该候选由所附固定归档重建，构建日志与配置可能包含构建机本地路径，公开前应检查和处理；不应冒充此前已打包的 FFmpeg：请比较 `metadata/candidate-sha256.txt` 与实际拟分发二进制，并仅为经过一致性确认的版本提供材料。`COMPLETE` 只表示构建脚本完成，不代表重链接、发行或许可义务已验收。

- `sources/`：FFmpeg 9.0.2、LAME 3.100、libogg 1.3.6、libvorbis 1.3.7、libvpx 1.17.0、libwebp 1.6.0、Opus 1.5.2 的输入归档；`metadata/source-sha256.txt` 用于校验。
- `licenses/`：本次启用库的许可及相关通知文件。各库适用条款和完整通知仍须逐项审查。
- `build/arm64/`、`build/x86_64/`：保留 FFmpeg 构建树中的对象、静态库，以及本地依赖源码、对象和 `local/lib`；`metadata/config-*.mak`、`config-*.log`、`link-*.txt`、`toolchain.txt` 保留实际配置、链接命令和工具版本；`metadata/object-sha256.txt` 覆盖保留的对象和静态库。
- `ffmpeg`：由以上两架构输出合并并临时 ad-hoc 签名的候选。Developer ID 签名、公证、实际发行系统测试均是后续单独事项。
- `metadata/build-recipe-used.sh`：本次实际执行的配方快照；`metadata/build-recipe.sh` 是后续完善的可复用配方。
- `metadata/build-recipe.sh`：复用本包输入重新构建到一个**不存在的新绝对目录**；需 macOS 15 SDK、Xcode/clang、make、pkgconf、nasm 和足够磁盘空间。具体版本见工具记录。运行前自行核对脚本及所有源码。
- `relink.py`：使用本包已保存对象与静态库在新路径重新链接；可指定替代静态库目录，不能覆盖已有输出。替换库版本/架构/接口必须由使用者自己验证。
- `compare-capabilities.py`：比较候选和参考引擎声明的编码器、解码器、格式和协议列表，不等于输出质量测试。
- `verify.py`：独立核验源归档、对象清单与候选哈希，并在临时目录重新链接及运行两架构的合成 PNG 转换；Intel 架构在 Apple Silicon 上需要可用的 Rosetta。它不证明全部编码器、实体 Intel 或全部许可义务。

示例（在材料目录内运行）：

```sh
shasum -a 256 -c metadata/source-sha256.txt
python3 verify.py .
python3 verify-modified-ogg.py .
python3 relink.py arm64 /absolute/path/to/new-ffmpeg-arm64
python3 relink.py arm64 /absolute/path/to/new-ffmpeg-custom --override-lib-dir /absolute/path/to/replacement-static-libs
bash metadata/build-recipe.sh /absolute/path/to/new-build-materials
```

FFmpeg 上游列出 LGPL 构建、源码和告知事项，并推荐动态链接作为一种简化路径：[FFmpeg legal](https://www.ffmpeg.org/legal.html)。GNU 对 LGPL 静态链接的说明强调提供对象形式以支持修改库后重链接：[GNU GPL FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#LGPLStaticVsDynamic)。这些资料不是本材料已充分满足条款的证明：发布前仍需确认实际所分发二进制与材料匹配、所有启用依赖的许可/通知与完整对应源码，以及用户取得、替换、重新链接和运行的方式。建议由负责发行的专业人员核查；本说明不是法律意见。
