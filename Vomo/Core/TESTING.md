# Vomo - Testing Guide

## Overview

This project includes comprehensive automated testing:
- **Unit Tests**: Test core business logic
- **UI Tests**: Test user interactions and flows
- **Performance Tests**: Measure app performance
- **Accessibility Tests**: Ensure VoiceOver compatibility

## Running Tests

### In Xcode

1. **Run All Tests**: `Cmd + U`
2. **Run Specific Test**: Click the diamond next to the test function
3. **Run Test Suite**: Click diamond next to `@Suite` or test class
4. **View Results**: Open Test Navigator (`Cmd + 6`)

### Command Line

```bash
# Run all tests
xcodebuild test -scheme Vomo -destination 'platform=iOS Simulator,name=iPhone 15'

# Run only unit tests
xcodebuild test -scheme Vomo -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:VomoTests

# Run only UI tests
xcodebuild test -scheme Vomo -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:VomoUITests

# Run specific test
xcodebuild test -scheme Vomo -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:VomoTests/VaultManagerTests/testSampleVaultCreation
```

## Test Coverage

### Unit Tests (`VomoTests.swift`)

| Suite | Tests | Coverage |
|-------|-------|----------|
| Vault Manager | 4 tests | Core vault operations |
| Graph Building | 2 tests | Wiki link extraction & connections |
| File Scanning | 2 tests | Markdown detection & metadata |
| Cache | 2 tests | Cache creation & persistence |
| Performance | 2 tests | Scanning speed & progressive loading |
| Data Models | 5 tests | VaultFile, Graph structures |

**Total: ~17 unit tests**

### UI Tests (`VomoUITests.swift`)

| Category | Tests | What It Validates |
|----------|-------|-------------------|
| Vault Selection | 2 tests | First launch, sample vault creation |
| Navigation | 1 test | Tab bar switching |
| Search | 2 tests | Search bar, results display |
| Browsing | 2 tests | Folder navigation, expansion |
| Reading | 2 tests | Opening notes, content rendering |
| Graph | 1 test | Graph view existence |
| Settings | 1 test | Settings menu |
| Sync | 2 tests | Pull-to-refresh, status bar |
| Performance | 2 tests | Launch time, scrolling |
| Accessibility | 2 tests | VoiceOver labels, Dynamic Type |

**Total: ~17 UI tests**

## CI/CD Integration

### GitHub Actions

Create `.github/workflows/test.yml`:

```yaml
name: Run Tests

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    name: Test
    runs-on: macos-14
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Select Xcode
      run: sudo xcode-select -switch /Applications/Xcode_15.2.app
    
    - name: Build and Test
      run: |
        xcodebuild test \
          -scheme Vomo \
          -destination 'platform=iOS Simulator,name=iPhone 15' \
          -resultBundlePath TestResults \
          | xcpretty
    
    - name: Upload Test Results
      if: always()
      uses: actions/upload-artifact@v4
      with:
        name: test-results
        path: TestResults.xcresult
```

### Xcode Cloud

1. Open Xcode → Product → Xcode Cloud → Create Workflow
2. Select: **Test on Pull Request**
3. Configure:
   - Scheme: Vomo
   - Test: All Tests
   - Devices: iPhone 15, iPad Pro
4. Save workflow

## Code Coverage

Enable code coverage:

1. Edit Scheme (`Cmd + <`)
2. Test tab → Options
3. Check "Code Coverage"
4. Select targets to track

View coverage:
- Report Navigator (`Cmd + 9`)
- Coverage tab

Target: **>70% coverage** for core business logic

## Screenshot Testing (Optional)

For visual regression testing:

1. Run `testTakeScreenshots()` UI test
2. View screenshots in Test Report
3. Compare across releases
4. Use tools like:
   - [SnapshotTesting](https://github.com/pointfreeco/swift-snapshot-testing)
   - [iOSSnapshotTestCase](https://github.com/uber/ios-snapshot-test-case)

## Test Best Practices

### Writing Good Tests

✅ **DO:**
- Test one thing per test
- Use descriptive test names
- Keep tests independent
- Use `#expect()` for assertions
- Clean up after tests

❌ **DON'T:**
- Test implementation details
- Make tests depend on each other
- Use hardcoded waits (use `waitForExistence`)
- Ignore flaky tests

### Example Test Structure

```swift
@Test("Clear description of what is tested")
func testFeatureName() async throws {
    // Arrange: Set up test conditions
    let manager = VaultManager()
    manager.createSampleVault()
    
    // Act: Perform the action
    await manager.scanVault()
    try await Task.sleep(for: .seconds(2))
    
    // Assert: Verify results
    #expect(manager.files.count > 0, "Should have files")
    #expect(manager.hasVault, "Should have vault")
}
```

## Performance Benchmarking

### Metrics to Track

- **App Launch**: < 2 seconds
- **Vault Scan (100 files)**: < 5 seconds
- **Vault Scan (1000 files)**: < 30 seconds
- **Search Query**: < 0.5 seconds
- **File Opening**: < 0.3 seconds

### Running Performance Tests

```swift
@Test("Performance test", .timeLimit(.seconds(30)))
func testPerformance() async throws {
    // Test code
}
```

## Accessibility Testing

### Manual Testing Checklist

- [ ] Turn on VoiceOver (Settings → Accessibility)
- [ ] Navigate through app using gestures
- [ ] Verify all buttons have labels
- [ ] Test with Large Text enabled
- [ ] Test with Reduce Motion enabled
- [ ] Test color contrast

### Automated Accessibility Tests

```swift
func testVoiceOverLabels() throws {
    let button = app.buttons["Search"]
    XCTAssertNotNil(button.label)
    XCTAssertTrue(button.isAccessibilityElement)
}
```

## Debugging Tests

### Failed Test?

1. Check test report for error message
2. Look at failure screenshot
3. Run test individually with breakpoints
4. Check console logs
5. Verify test data setup

### Flaky Test?

1. Increase timeout values
2. Use `waitForExistence(timeout:)` instead of `sleep()`
3. Check for race conditions
4. Ensure test isolation
5. Add retry logic for network tests

## Continuous Improvement

### Monthly Test Review

- [ ] Check test coverage
- [ ] Remove obsolete tests
- [ ] Update tests for new features
- [ ] Fix flaky tests
- [ ] Review performance metrics
- [ ] Update this guide

### Quality Gates

Before merging code:
- ✅ All tests pass
- ✅ No test coverage regression
- ✅ No new flaky tests
- ✅ Performance within limits
- ✅ Accessibility tests pass

## Resources

- [Swift Testing Documentation](https://developer.apple.com/documentation/testing)
- [XCTest Documentation](https://developer.apple.com/documentation/xctest)
- [UI Testing Guide](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/testing_with_xcode/chapters/09-ui_testing.html)
- [Testing Tips](https://www.swiftbysundell.com/basics/unit-testing/)

---

**Happy Testing! 🧪**
