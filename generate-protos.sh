#!/bin/bash
# Generate Swift protobuf and gRPC files from proto definitions.
#
# By default this resolves the proto sources from the sibling Python repo at
# ../ubo_app/rpc/proto. A local ./proto directory (or symlink) is honoured if
# present for environments that vendor the protos.
#
# Flags:
#   --check         Generate into a temp dir and diff against the committed
#                   tree under Sources/UboSwift/Generated. Exits non-zero on
#                   drift. Used by `poe proto:swift:check`.
#   --proto-dir P   Override the proto source directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PROTO_DIR="$SCRIPT_DIR/../ubo_app/rpc/proto"
LOCAL_PROTO_DIR="$SCRIPT_DIR/proto"
OUTPUT_DIR="$SCRIPT_DIR/Sources/UboSwift/Generated"

PROTO_DIR=""
CHECK_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            CHECK_MODE=1
            shift
            ;;
        --proto-dir)
            PROTO_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ -z "$PROTO_DIR" ]; then
    if [ -d "$LOCAL_PROTO_DIR" ]; then
        PROTO_DIR="$LOCAL_PROTO_DIR"
    else
        PROTO_DIR="$DEFAULT_PROTO_DIR"
    fi
fi

if [ ! -d "$PROTO_DIR" ]; then
    echo "Error: proto directory not found at $PROTO_DIR" >&2
    echo "Hint: clone the parent ubo-apple-apps repo, or pass --proto-dir." >&2
    exit 1
fi

if [ ! -f "$PROTO_DIR/ubo/v1/ubo.proto" ]; then
    echo "Error: $PROTO_DIR/ubo/v1/ubo.proto is missing." >&2
    echo "Run 'uv run poe proto:generate' from the ubo-apple-apps root first." >&2
    exit 1
fi

if ! command -v protoc &> /dev/null; then
    echo "Error: protoc not found. Install with: brew install protobuf" >&2
    exit 1
fi

if ! command -v protoc-gen-swift &> /dev/null; then
    echo "Error: protoc-gen-swift not found. Install with: brew install swift-protobuf" >&2
    exit 1
fi

GRPC_SWIFT_PLUGIN=""
if command -v protoc-gen-grpc-swift &> /dev/null; then
    GRPC_SWIFT_PLUGIN="protoc-gen-grpc-swift"
elif command -v protoc-gen-grpc-swift-2 &> /dev/null; then
    GRPC_SWIFT_PLUGIN="protoc-gen-grpc-swift-2"
else
    echo "Error: protoc-gen-grpc-swift not found. Install with: brew install grpc-swift" >&2
    exit 1
fi

if [ "$CHECK_MODE" -eq 1 ]; then
    TARGET_DIR="$(mktemp -d)"
    trap 'rm -rf "$TARGET_DIR"' EXIT
else
    TARGET_DIR="$OUTPUT_DIR"
    mkdir -p "$TARGET_DIR"
fi

echo "Generating Swift proto files..."
echo "  proto source: $PROTO_DIR"
echo "  output:       $TARGET_DIR"

protoc \
    --proto_path="$PROTO_DIR" \
    --plugin="protoc-gen-grpc-swift=$(which $GRPC_SWIFT_PLUGIN)" \
    --swift_out="$TARGET_DIR" \
    --swift_opt=Visibility=Public \
    --grpc-swift_out="$TARGET_DIR" \
    --grpc-swift_opt=Visibility=Public \
    "$PROTO_DIR/package_info/v1/package_info.proto" \
    "$PROTO_DIR/ubo/v1/ubo.proto" \
    "$PROTO_DIR/store/v1/store.proto" \
    "$PROTO_DIR/secrets/v1/secrets.proto"

if [ "$CHECK_MODE" -eq 1 ]; then
    if diff -r -q -x .gitkeep "$OUTPUT_DIR" "$TARGET_DIR" > /dev/null; then
        echo "OK: $OUTPUT_DIR matches generated output."
        exit 0
    fi
    echo "DRIFT: $OUTPUT_DIR is out of date. Showing diff:" >&2
    diff -r -x .gitkeep "$OUTPUT_DIR" "$TARGET_DIR" || true
    echo "Run ./generate-protos.sh to regenerate." >&2
    exit 1
fi

echo "Swift proto files generated successfully in $OUTPUT_DIR"
