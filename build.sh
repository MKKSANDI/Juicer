#!/bin/bash

# Build script for Juicer macOS app
set -e

echo "🍊 Building Juicer macOS App..."
echo "================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if we're on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo -e "${RED}Error: This script only works on macOS${NC}"
    exit 1
fi

# Check for required tools
if ! command -v swiftc &> /dev/null; then
    echo -e "${RED}Error: swiftc not found. Please install Xcode.${NC}"
    exit 1
fi

# Get macOS SDK path
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo "")
if [ -z "$SDK_PATH" ]; then
    echo -e "${RED}Error: Could not find macOS SDK. Please install Xcode Command Line Tools.${NC}"
    echo "Run: xcode-select --install"
    exit 1
fi

# Get SDK version
SDK_VERSION=$(xcrun --show-sdk-version --sdk macosx 2>/dev/null || echo "13.0")
MIN_DEPLOYMENT="13.0"

echo "📦 SDK Path: $SDK_PATH"
echo "📦 SDK Version: $SDK_VERSION"
echo "📦 Minimum Deployment: $MIN_DEPLOYMENT"
echo ""

# Create build directory
BUILD_DIR="build"
APP_NAME="Juicer"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "🧹 Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "🔨 Compiling Swift files..."

# Compile all Swift files
# Try to build universal binary, fallback to current architecture if lipo fails
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    TARGET="arm64-apple-macosx${MIN_DEPLOYMENT}"
else
    TARGET="x86_64-apple-macosx${MIN_DEPLOYMENT}"
fi

echo "🔨 Compiling for architecture: $ARCH ($TARGET)"

swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -o "$MACOS_DIR/$APP_NAME" \
    Sources/Juicer/JuicerApp.swift \
    Sources/Juicer/ContentView.swift \
    Sources/Juicer/BatteryManager.swift \
    -framework AppKit \
    -framework SwiftUI \
    -framework IOKit \
    -framework Foundation \
    -framework CoreGraphics \
    -framework CoreImage \
    -framework Combine

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Compilation failed!${NC}"
    exit 1
fi

echo "📝 Copying Info.plist..."
cp Info.plist "$CONTENTS_DIR/"

# Create PkgInfo
echo "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Make executable
chmod +x "$MACOS_DIR/$APP_NAME"

echo "🔐 Code signing app..."
# Code sign with ad-hoc signature (allows running without developer certificate)
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || {
    echo -e "${YELLOW}⚠️  Code signing failed, but continuing...${NC}"
}

# Remove quarantine attribute if present
xattr -d com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

echo ""
echo -e "${GREEN}✅ Build successful!${NC}"
echo ""
echo "📱 App bundle created at: $APP_BUNDLE"
echo ""
echo "🚀 To run the app:"
echo "   open $APP_BUNDLE"
echo ""
echo "Or double-click the app in Finder!"
echo ""
echo -e "${YELLOW}Note: If macOS still blocks the app, you may need to:${NC}"
echo "   1. Right-click the app → Open (first time only)"
echo "   2. Or run: xattr -cr $APP_BUNDLE"
