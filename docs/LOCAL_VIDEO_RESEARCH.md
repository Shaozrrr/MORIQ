# 本地视频理解评估

目的：评估能否用本机视频模型补充屏幕助手的时间理解。研究代码和权重只在隔离临时目录运行，未接入 MORIQ，未读取用户屏幕或把测试视频发到网络。

## 可复现样本

`Tests/LocalVideoBenchmark/generate_fixtures.py` 生成三个 640×360、6 秒的合成视频：蓝色方块向左、绿色方块静止、红色方块向右；画面分别带有 7392、2764、4826 的编号。运行脚本需要独立安装 OpenCV 和 NumPy。这里只是受控冒烟测试，不代表真实桌面理解能力。

在已安装 MLX-VLM 和 OpenCV 的隔离 Python 环境中，先运行 `python Tests/LocalVideoBenchmark/generate_fixtures.py <测试目录>`，再运行 `python Tests/LocalVideoBenchmark/run.py --model <本地模型目录> --fixtures <测试目录> --output <结果.json> --fps 2`。脚本使用离线模式并记录完整回答和耗时；需人工检查回答，不把进程退出成功等同于回答正确。

## 第一轮观察

- 测试环境：Apple M6，32 GB 内存；模型 `mlx-community/Qwen3-VL-2B-Instruct-4bit`，版本 `9c4f5209e57b31f4b9dfba735de3fb983739c9cc`；权重和配置合计约 1.8 GB。
- 使用 MLX-VLM 的视频输入、每秒 1 帧，统一提问方块颜色、移动和编号：三个样本的颜色与编号均正确，向右和静止正确，向左错误地回答静止。
- 每秒 2 帧、同一问题时，向左样本仍回答静止；另一个更短的问题得到正确的向左回答。因此这不是可靠通过。
- 对同一向左样本直接问“现在的屏幕上有什么”，模型只回答了项目编号，没有描述蓝色方块；这一普通问法也没有通过完整性检查。
- 单次加载模型并回答六秒合成视频约 1.5–3.4 秒，首次测得最大驻留内存约 2.2 GB、峰值内存占用约 3.9 GB；运行时间和统计受缓存、输入和设备影响。
- 该路径是对视频片段进行一次推理，不是持续视频流会话；小模型的准确性、复杂 UI、小字、遮挡、多任务和长时间开销均尚未达到产品验收。

## 四十亿参数模型

- `mlx-community/Qwen3-VL-4B-Instruct-4bit`，版本 `2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b`，模型文件约 3.1 GB。
- 每秒 2 帧、统一问题：向左样本仍误判为静止，还多报了颜色；静止与向右方向正确、编号均正确，向右样本也多报了一种颜色。向左样本改为每秒 4 帧仍误判静止。
- 直接问当前屏幕有什么时仍只回答编号，没有描述方块。该测试未通过，不接入应用。
- 三次每秒 2 帧测试各约 2.9–3.0 秒，最大驻留内存约 3.6 GB；每秒 4 帧的一次测试约 4.4 秒。均为独立启动后的单次观察，不能代表其他设备或真实工作负载。

## 八十亿参数模型

- `mlx-community/Qwen3-VL-8B-Instruct-4bit`，版本 `defcdea7cc7a4b0858fea563cbbce171d328e457`，模型文件约 5.8 GB。
- 每秒 2 帧、统一问题：静止和向右方向正确，向左仍误判静止；向左及向右样本附加了不存在的颜色或纹理。三次独立调用约 4.9–6.7 秒。
- 对向左样本换成更短的问题时回答了正确方向，但单次约 4.2 秒、最大驻留内存约 6.4 GB；直接问屏幕内容时提到了编号和蓝色矩形，却仍添加了不存在的竖线。
- 结果表明，增大模型仍不能通过这组基本场景的稳定性检查，暂不接入应用。模型每次分析完整片段仍不是连续视频流会话。

参考来源：[MLX-VLM 视频输入用法](https://github.com/Neywa-Labs/mlx-vlm#video-understanding)、[模型页面与许可证](https://huggingface.co/mlx-community/Qwen3-VL-2B-Instruct-4bit)、[MLX Swift 的视频输入](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/UserInput.swift)。
