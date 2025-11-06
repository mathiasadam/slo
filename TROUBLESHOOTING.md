# Troubleshooting LUT Integration

## Issue: Preview Not Showing LUT Effect

If your recorded videos are playing in the preview but don't show the Fuji Neopan LUT effect, follow these steps:

### Step 1: Check Console Logs

When you record a video, look for these messages in Xcode's Console:

#### ✅ **Good - LUT is Working**
```
✅ Found LUT file at: /path/to/Fuji_Neopan.cube
🎨 Initializing LUT Processor with file: Fuji_Neopan.cube
✅ LUT filter created successfully
✅ Metal-backed CIContext created with device: Apple GPU
🎬 Starting LUT processing
  Source: temp_slowmo_1234567890.mov
  Output: final_1234567890.mov
  Video: 1920x1080
✅ Finished processing all frames
🎉 LUT processing completed successfully!
  Output: final_1234567890.mov
```

#### ❌ **Problem - LUT Not Found**
```
❌ ERROR: LUT file not found in bundle. Tried:
  - Bundle.main.url(forResource: 'Fuji_Neopan', withExtension: 'cube', subdirectory: 'Utilities')
  - Bundle.main.url(forResource: 'Fuji_Neopan', withExtension: 'cube')
  - Bundle.main.path(forResource: 'Fuji_Neopan', ofType: 'cube')
  - Video will be processed without LUT
```

### Step 2: Verify LUT File is in Bundle

#### Method A: Check in Xcode
1. Open your project in Xcode
2. In the Project Navigator (left sidebar), expand the `Utilities` folder
3. Look for `Fuji_Neopan.cube` - it should be visible
4. Select the file and open the File Inspector (right sidebar)
5. Under "Target Membership", ensure your app target is **checked**

#### Method B: Check Build Phases
1. Select your project in Xcode
2. Select your app target
3. Go to "Build Phases" tab
4. Expand "Copy Bundle Resources"
5. Look for `Fuji_Neopan.cube` in the list
6. If it's not there, click the "+" button and add it

#### Method C: Terminal Verification
Run this command to check if the file exists:
```bash
cd /Users/mathiasadam/Desktop/slo
ls -lh again2/Utilities/Fuji_Neopan.cube
```

Should show:
```
-rw-r--r--  1 user  staff   672K Nov  6 15:25 again2/Utilities/Fuji_Neopan.cube
```

### Step 3: Clean Build and Reinstall

If the file is in the project but still not found:

1. **Clean Build Folder**
   - In Xcode: `Product` → `Clean Build Folder` (⇧⌘K)

2. **Delete App from Device**
   - Physically remove the app from your iPhone
   - Or run: `xcrun simctl uninstall booted slo` (if using simulator)

3. **Rebuild and Install**
   - Build and run again
   - The LUT file should now be in the app bundle

### Step 4: Verify File Format

If the LUT file is found but processing fails:

1. Check the file isn't corrupted:
```bash
head -20 again2/Utilities/Fuji_Neopan.cube
```

Should show:
```
TITLE "Adanmq_Fuji Neopan"

LUT_3D_SIZE 32

0.0224 0.0224 0.0224
0.0293 0.0293 0.0293
...
```

2. Check file size:
```bash
wc -l again2/Utilities/Fuji_Neopan.cube
```

Should show approximately **32,775 lines** (32³ entries + header)

### Step 5: Test with Debug Breakpoint

Add a breakpoint in `CameraManager.swift` in the `applyLUT` method:

```swift
private func applyLUT(to sourceURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
    // Add breakpoint here ⬇️
    var lutURL: URL?
    ...
}
```

When recording stops, the debugger will pause here. In the debug console, type:
```
po Bundle.main.bundlePath
po Bundle.main.url(forResource: "Fuji_Neopan", withExtension: "cube")
```

This will show you the actual bundle path and whether the LUT is found.

## Common Issues and Solutions

### Issue 1: "LUT file not found in bundle"

**Cause**: The `.cube` file isn't included in the app bundle

**Solution**:
1. Right-click `Fuji_Neopan.cube` in Xcode
2. Select "Show File Inspector"
3. Check the box next to your target under "Target Membership"
4. Clean and rebuild

### Issue 2: "No video track found"

**Cause**: The slow-motion export failed before LUT processing

**Solution**:
- Check console for errors during slow-motion creation
- Verify the temp video file is created successfully
- Check device storage (low space can cause export failures)

### Issue 3: LUT Applies But Looks Wrong

**Cause**: LUT file is corrupted or wrong format

**Solution**:
1. Re-copy the LUT file from the original:
```bash
cp "/Applications/Maxon Cinema 4D 2025/Redshift/res/core/Data/LUT/AdanmqLUTS/Fuji_Neopan.cube" \
   "/Users/mathiasadam/Desktop/slo/again2/Utilities/Fuji_Neopan.cube"
```

2. Clean build and reinstall

### Issue 4: Processing is Slow or Hangs

**Cause**: Running on Simulator or old device

**Solution**:
- **Always test on a physical device** (Simulator doesn't support Metal properly)
- LUT processing requires Metal for good performance
- Expected time: 10-20 seconds for a 6-second video on iPhone 12+

### Issue 5: Preview Shows Wrong Video

**Cause**: Multiple videos being processed, showing cached version

**Solution**:
- Check that `processedVideoURL` is being set to the LUT-processed file
- Verify the filename in console logs matches what's being displayed
- Check for proper cleanup of temp files

## Verification Checklist

Use this to verify everything is working:

- [ ] LUT file exists at `again2/Utilities/Fuji_Neopan.cube`
- [ ] File size is 672 KB
- [ ] File has 32,775 lines
- [ ] File is checked in Target Membership
- [ ] Console shows "✅ Found LUT file"
- [ ] Console shows "🎨 Initializing LUT Processor"
- [ ] Console shows "✅ Metal-backed CIContext created"
- [ ] Console shows "🎬 Starting LUT processing"
- [ ] Console shows progress updates
- [ ] Console shows "🎉 LUT processing completed successfully"
- [ ] Preview video has visible black & white film look
- [ ] No red or incorrect colors
- [ ] Video is smooth (not choppy)

## Expected Console Output

Here's the complete expected console output when recording:

```
Recording started
✅ Found LUT file at: /var/.../Fuji_Neopan.cube
🎨 Initializing LUT Processor with file: Fuji_Neopan.cube
✅ LUT filter created successfully
✅ Metal-backed CIContext created with device: Apple A15 GPU
🎬 Starting LUT processing
  Source: temp_slowmo_1699302345.678.mov
  Output: final_1699302345.789.mov
  Video: 1920.0x1080.0
✅ Finished processing all frames
🎉 LUT processing completed successfully!
  Output: final_1699302345.789.mov
Setting up player with URL: file:///var/.../final_1699302345.789.mov
```

## Still Not Working?

If you've tried everything above and it's still not working:

1. **Check the video directly**:
   - Export the processed video to Photos
   - View it in the Photos app
   - Compare with a test video to confirm LUT is applied

2. **Try a simpler LUT**:
   - Create a test LUT with obvious colors (all red or all blue)
   - See if that gets applied
   - This helps isolate whether it's the LUT file or the code

3. **Enable more logging**:
   - Add more `print()` statements in `LUTProcessor.swift`
   - Log every frame being processed
   - Check if processing is actually happening

4. **Compare videos**:
   - Save a video before LUT (comment out LUT step)
   - Save a video after LUT
   - Compare them side-by-side to see the difference

## Quick Debug Commands

Run these in Terminal to check everything:

```bash
# Check LUT file exists and is correct size
ls -lh again2/Utilities/Fuji_Neopan.cube

# Verify LUT format
head -10 again2/Utilities/Fuji_Neopan.cube

# Count lines (should be ~32,775)
wc -l again2/Utilities/Fuji_Neopan.cube

# Find all cube files in project
find . -name "*.cube" -type f

# Check if file is in git
git ls-files | grep Fuji_Neopan
```

## Need More Help?

Look at these files for more information:
- `LUT_GUIDE.md` - Technical details about LUT system
- `QUICK_REFERENCE.md` - Developer quick reference
- `IMPLEMENTATION_SUMMARY.md` - What was implemented

Or check the console output while running the app - the emoji indicators (✅, ❌, 🎨, 🎬, 🎉) make it easy to spot issues!

