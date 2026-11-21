import Foundation
func check(_ input: String, _ expected: String?) {
    let actual = CleanClipboardLink.clean(input)
    precondition(actual == expected, "unexpected result for \(input): \(String(describing: actual))")
}
check("https://example.com/article?utm_source=test&id=5&fbclid=abc#part", "https://example.com/article?id=5#part")
check("https://example.com/?utm_source=a&utm_medium=b", "https://example.com/")
check("https://example.com/a?x=a%2Bb&UTM_SOURCE=mail&x=2#f", "https://example.com/a?x=a%2Bb&x=2#f")
check("https://example.com/?ref=friend", nil)
check("https://example.com/?utm_source=a&X-Amz-Signature=abc", nil)
check("https://example.com/?utm_source=a&token=abc", nil)
check("https://example.com/?utm_source=a&code=abc", nil)
check("https://example.com/?utm_source=a&hmac=abc", nil)
check("https://example.com/?utm_source=a&oauth_signature=abc", nil)
check("hello https://example.com/?utm_source=a", nil)
check("file:///tmp/a?utm_source=a", nil)
check("https://example.com/#frag?utm_source=a", nil)
check("https://example.com/?%75tm_source=a&x=1", "https://example.com/?x=1")
print("CleanClipboardLink tests passed")
