import Foundation
let text = ";FFMETADATA1\ntitle=多行\\\n下一行\\=value\nname=重复\nname=重复\npath=a\\\\\\;b\nencoder=discard\nDURATION=discard\n"
let entries = ExternalMediaConverter.metadataEntries(text)
precondition(entries["title=多行\\\n下一行\\=value"] == 1)
precondition(entries["name=重复"] == 2)
precondition(entries["path=a\\\\\\;b"] == 1)
precondition(entries.count == 3)
print("PASS escaped multiline, UTF-8 and duplicate metadata records")
