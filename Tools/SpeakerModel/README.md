# CAM++ v2 模型完整性核验（发行准备）

此工具只核验本地文件，不下载、执行或安装模型。清单固定 [FluidInference/campplus-coreml](https://huggingface.co/FluidInference/campplus-coreml/tree/f316edbc70d9023a94aaf8965538aba4330dc28e) 提交 `f316edbc70d9023a94aaf8965538aba4330dc28e` 的两个 v2 Core ML 目录，共 10 个文件。2026-11-13 对该提交的 Hugging Face 文件元数据，逐项比对本机缓存中的长度以及 Git LFS 的 SHA-256 / 普通 Git 文件的 blob SHA-1；全部一致后从本机对应字节生成清单中的 SHA-256。模型主权重约 27.7 MB，预处理权重约 0.9 MB。

```sh
python3 Tools/SpeakerModel/verify_campplus.py /absolute/path/to/model-root
python3 -m unittest discover -s Tests/SpeakerModel -p 'test_*.py'
```

模型根目录必须包含 `CamPlusPlus_v2.mlmodelc` 和 `CamPlusPreprocessor_v2.mlmodelc`。每个目录中只能有清单列出的文件与目录；工具拒绝符号链接、缺失、额外文件、非法路径、截断、大小不符和摘要不符。根目录可以另含其他模型版本。该工具是离线包装前检查，不是防止核验后文件被替换的运行时锁，也不能证明模型安全、准确或可以合法发行。

[转换模型说明](https://huggingface.co/FluidInference/campplus-coreml)指出权重来自上游 CAM++；[ModelScope 上游 v1.0.0 模型卡](https://www.modelscope.cn/api/v1/models/iic/speech_campplus_sv_zh-cn_16k-common/repo?Revision=v1.0.0&FilePath=README.md)声明 Apache License 2.0，[FluidAudio SDK](https://github.com/FluidInference/FluidAudio)另有自身 Apache-2.0 许可。转换文件、上游权重及其余依赖的许可和随包声明仍须完整核对；不能仅凭本清单认定发行合规。

用户无需服务器即可加载本地模型，但当前应用没有经过验收的模型安装器：FluidAudio 默认 CAM++ 下载使用浮动 `main`，且已有缓存的快捷检查仅判断文件存在，不应直接作为发布保证。若未来自动下载，应固定上述提交，安全取得全部文件、逐项核验后原子安装，且在非开发机、断网和重试场景验收。语音身份仍须用户明确提供名字或样本，声纹属于敏感数据，正式本地安全存储、删除、门限和误认率均尚未完成。
