# 说话人身份匹配：隔离研究

使用 FluidAudio 固定提交 d653a34a620c013febd7530427b4963ae18064b2 的 CampPlusEmbedder；它调用 CAM++ CoreML 声纹模型，SDK 明确标注 beta。输入仅使用 Tests/SpeakerDiarizationResearch/public_two_speaker.py 准备的公开 LibriSpeech 两人交替录音，按已知片段边界切成 8 个独立片段，每人 4 段；没有采集用户声音。Mac 本机算出 28 个音频对的余弦相似度：12 个同人对范围 0.796–0.923，16 个不同人对范围 0.244–0.487。

这是两个朗读者、少量干净音频、一次实验，不含多人重叠、短语音、跨设备或跨时间；不能据此设定产品阈值、推断实际误认率或声称可靠姓名识别。它是同类项目的现成模型可运行性实验，未接入 MORIQ，不存储声纹。模型许可需核对上游 CAM++ 权重条款，转换页注明上游许可适用；模型作者也将转换版本标记 beta。姓名需要用户明确提供匹配或录入，低置信度必须保持未知并允许纠错/删除。

参考：https://github.com/FluidInference/FluidAudio ，https://huggingface.co/FluidInference/campplus-coreml ，https://github.com/sblattj/whosaid 。`Tests/SpeakerVerificationResearch` 包含仅打印相似度的 Swift 程序，依赖固定版本 FluidAudio 与公开分段 WAV；其首次运行会下载模型。模型、WAV、个人录音与声纹均不随代码分发。
