#!/bin/bash
set -euo pipefail

# Always run from the repo root regardless of where the script is called from
cd "$(dirname "$0")/.."

CRATE=warp_ios_bridge
OUT_DIR="ios/WarpIOSBridge.xcframework"
GENERATED_DIR="ios/warp-ios/warp-ios/WarpApp/Generated"

echo "Building for iOS device (aarch64-apple-ios)..."
cargo build --release --target aarch64-apple-ios -p $CRATE

echo "Building for iOS simulator (aarch64-apple-ios-sim)..."
cargo build --release --target aarch64-apple-ios-sim -p $CRATE

echo "Generating Swift bindings..."
mkdir -p "$GENERATED_DIR"
cargo run -p $CRATE --bin uniffi-bindgen generate \
  --library "target/aarch64-apple-ios/release/lib${CRATE}.a" \
  --language swift \
  --out-dir "$GENERATED_DIR"

# Patch UniFFI 0.28 + Xcode compatibility: wrap bare function ref in a literal closure
sed -i '' 's/uniffiFutureContinuationCallback,$/{ h, p in uniffiFutureContinuationCallback(handle: h, pollResult: p) },/' "$GENERATED_DIR/warp_ios_bridge.swift"

# Copy the generated header AND modulemap to the include dir for xcframework packaging
mkdir -p "target/ios-headers"
cp "$GENERATED_DIR"/*.h "target/ios-headers/"
cp "$GENERATED_DIR"/*.modulemap "target/ios-headers/module.modulemap"

echo "Packaging xcframework..."
rm -rf "$OUT_DIR"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/release/lib${CRATE}.a" \
  -headers "target/ios-headers" \
  -library "target/aarch64-apple-ios-sim/release/lib${CRATE}.a" \
  -headers "target/ios-headers" \
  -output "$OUT_DIR"

XCODE_COPY="ios/warp-ios/warp-ios/WarpApp/WarpIOSBridge.xcframework"
if [ -d "$(dirname "$XCODE_COPY")" ]; then
    rm -rf "$XCODE_COPY"
    cp -R "$OUT_DIR" "$XCODE_COPY"
    echo "Synced to Xcode project: $XCODE_COPY"
fi

echo "Done: $OUT_DIR"
