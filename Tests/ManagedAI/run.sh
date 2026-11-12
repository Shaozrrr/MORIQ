#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 Tests/ManagedAI/test_server.py
python3 Tests/ManagedAI/test_accounts.py
binary="$(mktemp -t moriq-managed-client)"
trap 'rm -f "$binary"' EXIT
swiftc -D DEBUG -parse-as-library MORIQ/DeepSeek.swift MORIQ/ManagedAIClient.swift Tests/ManagedAI/client.swift -o "$binary"
python3 Tests/ManagedAI/integration.py "$binary"
