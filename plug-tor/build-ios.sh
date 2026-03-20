#!/bin/bash
set -e

echo "Building plug-tor for iOS..."

# Build for iOS device (arm64)
echo "→ Building aarch64-apple-ios..."
cargo build --release --target aarch64-apple-ios

# Build for iOS simulator (arm64 - M1/M2)
echo "→ Building aarch64-apple-ios-sim..."
cargo build --release --target aarch64-apple-ios-sim

# Create xcframework directory
FRAMEWORK_DIR="PlugTor.xcframework"
rm -rf "$FRAMEWORK_DIR"

# Create module.modulemap for Swift import
mkdir -p headers
cp include/plug_tor.h headers/

cat > headers/module.modulemap << 'EOF'
module PlugTor {
    header "plug_tor.h"
    export *
}
EOF

# Create xcframework
echo "→ Creating XCFramework..."
xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libplug_tor.a \
    -headers headers/ \
    -library target/aarch64-apple-ios-sim/release/libplug_tor.a \
    -headers headers/ \
    -output "$FRAMEWORK_DIR"

echo "✅ PlugTor.xcframework created!"
echo ""
echo "To integrate:"
echo "1. Drag PlugTor.xcframework into your Xcode project"
echo "2. import PlugTor in Swift files"
echo "3. Call plug_tor_start() to bootstrap Tor"
