import Foundation
precondition(ScreenshotTranslationLanguage.source(for: "MORIQ SCREENSHOT TEST", target: "zh-Hans") == "en")
precondition(ScreenshotTranslationLanguage.source(for: "请在周五前审阅", target: "en") == "zh-Hans")
precondition(ScreenshotTranslationLanguage.source(for: "已经是中文", target: "zh-Hans") == nil)
precondition(ScreenshotTranslationLanguage.source(for: "Already English", target: "en") == nil)
precondition(ScreenshotTranslationLanguage.source(for: "123 456", target: "zh-Hans") == nil)
precondition(ScreenshotTranslationLanguage.source(for: "项目 MORIQ", target: "en") == "zh-Hans")
print("PASS explicit source language and same-language handling")
