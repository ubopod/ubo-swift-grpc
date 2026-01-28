#!/bin/bash
# Generate Swift protobuf and gRPC files from proto definitions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROTO_DIR="$SCRIPT_DIR/../proto"
OUTPUT_DIR="$SCRIPT_DIR/Sources/UboSwift/Generated"

# Check if proto directory exists
if [ ! -d "$PROTO_DIR" ]; then
    echo "Error: Proto directory not found at $PROTO_DIR"
    echo "Copy proto/ directory from ubo_app/ubo_app/rpc/proto/"
    exit 1
fi

# Check for required tools
if ! command -v protoc &> /dev/null; then
    echo "Error: protoc not found. Install with: brew install protobuf"
    exit 1
fi

if ! command -v protoc-gen-swift &> /dev/null; then
    echo "Error: protoc-gen-swift not found. Install with: brew install swift-protobuf"
    exit 1
fi

# Check for grpc-swift plugin (may be named protoc-gen-grpc-swift or protoc-gen-grpc-swift-2)
GRPC_SWIFT_PLUGIN=""
if command -v protoc-gen-grpc-swift &> /dev/null; then
    GRPC_SWIFT_PLUGIN="protoc-gen-grpc-swift"
elif command -v protoc-gen-grpc-swift-2 &> /dev/null; then
    GRPC_SWIFT_PLUGIN="protoc-gen-grpc-swift-2"
else
    echo "Error: protoc-gen-grpc-swift not found. Install with: brew install grpc-swift"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo "Generating Swift protobuf files..."

# Generate Swift files for all proto files
protoc \
    --proto_path="$PROTO_DIR" \
    --plugin="protoc-gen-grpc-swift=$(which $GRPC_SWIFT_PLUGIN)" \
    --swift_out="$OUTPUT_DIR" \
    --swift_opt=Visibility=Public \
    --grpc-swift_out="$OUTPUT_DIR" \
    --grpc-swift_opt=Visibility=Public \
    "$PROTO_DIR/package_info/v1/package_info.proto" \
    "$PROTO_DIR/ubo/v1/ubo.proto" \
    "$PROTO_DIR/store/v1/store.proto" \
    "$PROTO_DIR/secrets/v1/secrets.proto"

echo "Swift proto files generated successfully in $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
