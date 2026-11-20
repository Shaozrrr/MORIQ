import Foundation

@main struct NativeLaneUpdateTests {
    static func main() {
        var lane = CaptionLanePages(pageCapacity: 90)
        precondition(lane.append(confirmedDelta: "你好，", provisional: "这个", revision: 1))
        precondition(lane.text == "你好，这个")
        precondition(lane.append(confirmedDelta: "这是", provisional: "测试", revision: 2))
        precondition(lane.text == "你好，这是测试")
        precondition(!lane.append(confirmedDelta: "重复", provisional: "旧", revision: 2))
        precondition(lane.text == "你好，这是测试")
        precondition(!lane.append(confirmedDelta: "过期", provisional: "旧", revision: 1))
        precondition(lane.text == "你好，这是测试")
        precondition(lane.append(confirmedDelta: "测试。", provisional: "", revision: 3))
        precondition(lane.text == "你好，这是测试。")
        print("PASS native confirmed text, provisional replacement and revision rejection")
    }
}
