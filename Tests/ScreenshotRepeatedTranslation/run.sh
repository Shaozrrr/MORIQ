#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
python3 - "$tmpdir/annotation.swift" <<'PY'
from pathlib import Path
import sys
s=Path('MORIQ/ScreenshotCoordinator.swift').read_text()
body=s.split('enum ScreenshotAnnotation: Equatable {',1)[1].split('struct ScreenshotResultView: View {',1)[0]
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\nimport CoreText\nimport ImageIO\nimport UniformTypeIdentifiers\nimport Darwin\nenum ScreenshotAnnotation: Equatable {'+body)
PY
swiftc -parse-as-library "$tmpdir/annotation.swift" Tests/ScreenshotRepeatedTranslation/stubs.swift MORIQ/OCREngine.swift MORIQ/ScreenshotGeometry.swift MORIQ/ScreenshotEditSession.swift Tests/ScreenshotRepeatedTranslation/main.swift -o "$tmpdir/test"
"$tmpdir/test"
