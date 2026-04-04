#!/bin/bash

# Vomo - Test Setup Script
# Run this to configure testing in your Xcode project

set -e

echo "🧪 Setting up Vomo Testing..."
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Project name
PROJECT_NAME="Vomo"
SCHEME_NAME="Vomo"

echo "${BLUE}Step 1:${NC} Creating test targets in Xcode..."
echo "→ You'll need to do this manually in Xcode:"
echo "  1. File → New → Target → iOS Unit Testing Bundle"
echo "  2. Name it: ${PROJECT_NAME}Tests"
echo "  3. File → New → Target → iOS UI Testing Bundle"
echo "  4. Name it: ${PROJECT_NAME}UITests"
echo ""

echo "${BLUE}Step 2:${NC} Adding test files..."
echo "✅ VomoTests.swift (Unit tests)"
echo "✅ VomoUITests.swift (UI tests)"
echo "→ Drag these files into your test targets in Xcode"
echo ""

echo "${BLUE}Step 3:${NC} Enabling code coverage..."
echo "→ In Xcode:"
echo "  1. Product → Scheme → Edit Scheme (Cmd + <)"
echo "  2. Select 'Test' tab"
echo "  3. Options → Check 'Code Coverage'"
echo "  4. Select your main target"
echo ""

echo "${BLUE}Step 4:${NC} Running tests..."
echo "Command line test commands:"
echo ""
echo "# Run all tests"
echo "xcodebuild test -scheme ${SCHEME_NAME} -destination 'platform=iOS Simulator,name=iPhone 15'"
echo ""
echo "# Run unit tests only"
echo "xcodebuild test -scheme ${SCHEME_NAME} -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:${PROJECT_NAME}Tests"
echo ""
echo "# Run UI tests only"
echo "xcodebuild test -scheme ${SCHEME_NAME} -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:${PROJECT_NAME}UITests"
echo ""

echo "${GREEN}✅ Test files created!${NC}"
echo ""
echo "📚 Next steps:"
echo "  1. Add test targets in Xcode (see Step 1 above)"
echo "  2. Add test files to targets"
echo "  3. Enable code coverage (see Step 3 above)"
echo "  4. Run tests: Cmd + U in Xcode"
echo "  5. Read TESTING.md for detailed guide"
echo ""
echo "🎉 Happy testing!"
