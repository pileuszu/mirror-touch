#!/bin/bash

# Exit immediately if any command fails
set -e

echo "🔨 Building macOS-Host in Release mode..."
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project macOS-Host/macOS-Host.xcodeproj -scheme macOS-Host -configuration Release -derivedDataPath build -quiet

echo "🚚 Copying standalone app to /Applications..."
# Remove old app in /Applications if it exists
if [ -d "/Applications/macOS-Host.app" ]; then
    rm -rf "/Applications/macOS-Host.app"
fi

# Copy the newly compiled app
cp -R build/Build/Products/Release/macOS-Host.app /Applications/

# Copy to repository root as well
rm -rf macOS-Host.app
cp -R build/Build/Products/Release/macOS-Host.app ./

echo "✨ Successfully built and deployed to /Applications and repository root!"
