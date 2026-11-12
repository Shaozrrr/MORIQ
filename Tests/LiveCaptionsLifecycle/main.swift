import Foundation
precondition(!CaptionAnalyzerAvailability.enabled, "unverified analyzer input must not run in process")
print("PASS unverified analyzer path disabled by default")
