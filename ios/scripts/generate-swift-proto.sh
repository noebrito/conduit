#!/usr/bin/env bash
set -euo pipefail

# Regenerates ios/Conduit/Models/Generated/sync.pb.swift from this repo's own
# proto/conduit/v1/sync.proto — the wire-schema-of-record described in the
# root README.
#
# Requires:
#   - protoc (the protobuf compiler)             `brew install protobuf`
#   - protoc-gen-swift, pinned to 1.38.1          `brew install swift-protobuf`
#     1.38.1 matches the SwiftProtobuf runtime pinned in
#     Conduit.xcodeproj's Package.resolved (apple/swift-protobuf @ 1.38.1) and
#     is what produced the currently-committed sync.pb.swift. A mismatched
#     protoc-gen-swift version can change generated struct visibility, add or
#     drop `Sendable`/`nonisolated` conformances, or otherwise produce a diff
#     unrelated to any actual schema change — check `protoc-gen-swift
#     --version` against the version above (and against
#     Package.resolved's "swift-protobuf" pin, if it has since moved) before
#     committing regenerated output. To build a specific version from source:
#     `git clone https://github.com/apple/swift-protobuf && cd swift-protobuf
#     && git checkout 1.38.1 && swift build -c release
#     --product protoc-gen-swift`.
#
# Usage: ios/scripts/generate-swift-proto.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PROTO_DIR="$REPO_ROOT/proto/conduit/v1"
PROTO_FILE="sync.proto"
OUT_DIR="$REPO_ROOT/ios/Conduit/Models/Generated"
REQUIRED_PROTOC_GEN_SWIFT_VERSION="1.38.1"

command -v protoc >/dev/null 2>&1 || {
  echo "error: protoc not found on PATH (brew install protobuf)" >&2
  exit 1
}
command -v protoc-gen-swift >/dev/null 2>&1 || {
  echo "error: protoc-gen-swift not found on PATH (brew install swift-protobuf)" >&2
  exit 1
}

actual_version="$(protoc-gen-swift --version 2>&1 | awk '{print $2}')"
if [[ "$actual_version" != "$REQUIRED_PROTOC_GEN_SWIFT_VERSION" ]]; then
  echo "warning: protoc-gen-swift is $actual_version, this repo's generated" \
    "output was last verified against $REQUIRED_PROTOC_GEN_SWIFT_VERSION" \
    "(see this script's header comment). Diff the result carefully." >&2
fi

cd "$PROTO_DIR"
protoc \
  --proto_path=. \
  --swift_out="$OUT_DIR" \
  --swift_opt=Visibility=Public \
  "$PROTO_FILE"

echo "Regenerated $OUT_DIR/sync.pb.swift"
