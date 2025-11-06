# Fix: Processing Stuck with "fopen failed" Error

## Problem
The app was getting stuck during LUT processing with the following error:
```
fopen failed for data file: errno = 2 (No such file or directory)
Errors found! Invalidating cache...
```

The LUT file was found and initialized correctly, but the actual video processing failed when trying to read/write video frames.

## Root Cause

The issue was caused by **synchronous access to AVAsset properties** that are now async in modern Swift. Specifically:

1. `videoTrack.naturalSize` - Was accessed synchronously
2. `videoTrack.preferredTransform` - Was accessed synchronously
3. No verification that source file exists before processing
4. No verification that output directory exists
5. AVAssetWriter/Reader starting without proper error checking

When these properties are accessed before the asset is fully loaded, it can cause file access errors during the actual processing.

## Fixes Applied

### 1. Async Asset Loading
Changed to properly load asset properties asynchronously:

```swift
// BEFORE - Synchronous (causes issues)
let asset = AVAsset(url: sourceURL)
guard let videoTrack = asset.tracks(withMediaType: .video).first else {
    // This might not work if asset isn't loaded yet
    return
}
let size = videoTrack.naturalSize // Synchronous access - BAD

// AFTER - Asynchronous (proper)
let asset = AVAsset(url: sourceURL)

Task {
    do {
        let tracks = try await asset.load(.tracks)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        guard let videoTrack = videoTracks.first else { return }
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        
        // Now process with loaded properties
        self.processVideo(asset: asset, videoTrack: videoTrack, 
                          naturalSize: naturalSize, 
                          preferredTransform: preferredTransform, ...)
    } catch {
        print("❌ Failed to load asset: \(error.localizedDescription)")
    }
}
```

### 2. File Existence Validation
Added checks before processing:

```swift
// Verify source file exists
let fileManager = FileManager.default
guard fileManager.fileExists(atPath: sourceURL.path) else {
    print("❌ Source file does not exist at path: \(sourceURL.path)")
    completion(.failure(LUTError.invalidFormat("Source file not found")))
    return
}

// Get file size to verify it's not corrupted
do {
    let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
    if let fileSize = attributes[.size] as? Int64 {
        print("  Source file size: \(fileSize) bytes")
        if fileSize == 0 {
            print("❌ Source file is empty!")
            completion(.failure(LUTError.invalidFormat("Source file is empty")))
            return
        }
    }
} catch {
    print("⚠️ Warning: Could not get file attributes: \(error.localizedDescription)")
}
```

### 3. Output Directory Creation
Ensure output directory exists:

```swift
// Ensure output directory exists
let outputDir = outputURL.deletingLastPathComponent()
if !fileManager.fileExists(atPath: outputDir.path) {
    do {
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        print("✅ Created output directory")
    } catch {
        print("❌ Failed to create output directory: \(error.localizedDescription)")
        completion(.failure(error))
        return
    }
}

// Remove output file if it already exists
if fileManager.fileExists(atPath: outputURL.path) {
    do {
        try fileManager.removeItem(at: outputURL)
        print("🗑️ Removed existing output file")
    } catch {
        print("⚠️ Warning: Could not remove existing output file: \(error.localizedDescription)")
    }
}
```

### 4. Writer/Reader Error Checking
Added explicit error checking when starting:

```swift
print("📝 Starting writer...")
writer.startWriting()

// Check if writer started successfully
if writer.status == .failed {
    print("❌ Writer failed to start: \(writer.error?.localizedDescription ?? "Unknown error")")
    completion(.failure(writer.error ?? LUTError.filterCreationFailed))
    return
}

print("▶️ Starting session and reader...")
writer.startSession(atSourceTime: .zero)
reader.startReading()

// Check if reader started successfully  
if reader.status == .failed {
    print("❌ Reader failed to start: \(reader.error?.localizedDescription ?? "Unknown error")")
    writer.cancelWriting()
    completion(.failure(reader.error ?? LUTError.filterCreationFailed))
    return
}

print("✅ Reader and writer started successfully")
```

### 5. Enhanced Logging
Added detailed logging to track the processing flow:

```swift
print("🎬 Starting LUT processing")
print("  Source: \(sourceURL.lastPathComponent)")
print("  Source path: \(sourceURL.path)")
print("  Output: \(outputURL.lastPathComponent)")
print("  Output path: \(outputURL.path)")
print("  Source file size: \(fileSize) bytes")
print("  Video: \(naturalSize.width)x\(naturalSize.height)")
print("📹 Setting up reader and writer...")
print("📝 Starting writer...")
print("▶️ Starting session and reader...")
print("✅ Reader and writer started successfully")
```

## Expected Console Output Now

### Success Case:
```
✅ Found LUT file at: /path/to/Fuji_Neopan.cube
🎨 Initializing LUT Processor with file: Fuji_Neopan.cube
✅ LUT filter created successfully
✅ Metal-backed CIContext created with device: Apple A19 Pro GPU
🎬 Starting LUT processing
  Source: temp_slowmo_1762439780.899249.mov
  Source path: /var/.../temp_slowmo_1762439780.899249.mov
  Output: final_1762439781.8554559.mov
  Output path: /var/.../final_1762439781.8554559.mov
  Source file size: 1234567 bytes
  Video: 1920.0x1080.0
📹 Setting up reader and writer...
📝 Starting writer...
▶️ Starting session and reader...
✅ Reader and writer started successfully
✅ Finished processing all frames
🎉 LUT processing completed successfully!
```

### Error Case (source file missing):
```
✅ Found LUT file at: /path/to/Fuji_Neopan.cube
🎨 Initializing LUT Processor with file: Fuji_Neopan.cube
✅ LUT filter created successfully
✅ Metal-backed CIContext created with device: Apple A19 Pro GPU
🎬 Starting LUT processing
  Source: temp_slowmo_1762439780.899249.mov
  Source path: /var/.../temp_slowmo_1762439780.899249.mov
❌ Source file does not exist at path: /var/.../temp_slowmo_1762439780.899249.mov
```

### Error Case (writer failed):
```
...
📹 Setting up reader and writer...
📝 Starting writer...
❌ Writer failed to start: Operation not permitted
```

## Files Modified

1. `again2/Utilities/LUTProcessor.swift`
2. `Timeloop/Timeloop/Utilities/LUTProcessor.swift`

## Testing the Fix

### Step 1: Clean Build
```bash
# In Xcode
Product → Clean Build Folder (⇧⌘K)
```

### Step 2: Rebuild and Run
```bash
Product → Run (⌘R)
```

### Step 3: Record a Video
1. Tap record button
2. Wait for recording to complete
3. Watch the console output carefully

### Step 4: Verify Success
You should see:
- ✅ All green checkmarks in console
- "✅ Reader and writer started successfully"
- Progress updates
- "🎉 LUT processing completed successfully!"
- Preview shows video with Fuji Neopan LUT applied

### Step 5: If Still Failing
Check the console for which specific step is failing:
- If "❌ Source file does not exist" → Issue with slow-motion export
- If "❌ Writer failed to start" → Permission or disk space issue
- If "❌ Failed to load asset" → File corruption issue

## Why This Fixes "fopen failed"

The "fopen failed" error occurs when AVFoundation tries to access a file that doesn't exist or properties that aren't loaded. Our fixes address this by:

1. **Async Loading**: Ensures all asset properties are fully loaded before processing
2. **File Validation**: Confirms files exist before attempting to process them
3. **Directory Creation**: Ensures output directory exists before writing
4. **Early Error Detection**: Catches issues before they cause deeper failures

## Prevention

To prevent similar issues in the future:

1. Always use `async/await` for AVFoundation asset loading
2. Always verify file existence before processing
3. Always check AVAssetWriter/Reader status after starting
4. Always create directories before writing files
5. Always log detailed information at each step

## Related Issues

If you're still experiencing issues:
- Check `TROUBLESHOOTING.md` for general LUT issues
- Check device storage (low space can cause write failures)
- Verify camera permissions are granted
- Check that video is recording successfully before LUT processing

## Summary

**Problem**: Processing stuck with "fopen failed" error  
**Root Cause**: Synchronous access to async AVFoundation properties + insufficient validation  
**Fix**: Async asset loading + comprehensive file validation + error checking  
**Result**: Reliable LUT processing with clear error messages

The video processing should now complete successfully with the Fuji Neopan LUT applied! 🎬✨

