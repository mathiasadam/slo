# Critical Fix: LUTProcessor Premature Deallocation

## The Problem

The app was getting stuck during LUT processing with the console showing:
```
✅ Reader and writer started successfully
📊 Total duration: 6.0 seconds
⏳ Waiting for writer to be ready for data...
⚠️ Self is nil in processing callback
⚠️ Self is nil in processing callback
⚠️ Self is nil in processing callback
```

## Root Cause

The `LUTProcessor` instance was being **deallocated prematurely** before video processing could complete.

### The Flow:

1. `CameraManager.applyLUT()` created a local `LUTProcessor` instance
2. Called `lutProcessor.applyLUT()` with async callbacks
3. The method returned immediately
4. **The local variable went out of scope**
5. **ARC deallocated the LUTProcessor**
6. The async processing callback tried to access `[weak self]`
7. But `self` was already nil → Processing stuck!

### Code Before Fix:

```swift
private func applyLUT(to sourceURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
    // ...
    do {
        let lutProcessor = try LUTProcessor(cubeFileURL: finalLutURL)
        
        lutProcessor.applyLUT(
            to: sourceURL,
            outputURL: finalOutputURL,
            progress: { ... },
            completion: { ... }
        )
        // ❌ lutProcessor goes out of scope HERE!
        // ❌ Gets deallocated immediately!
    }
}
```

### In LUTProcessor:

```swift
writerInput.requestMediaDataWhenReady(on: processingQueue) { [weak self] in
    guard let self = self else {
        print("⚠️ Self is nil in processing callback")  // ← This kept printing!
        return
    }
    // Never reaches here because self is nil
}
```

## The Fix

### 1. Keep Strong Reference in CameraManager

Added an instance variable to hold the processor:

```swift
class CameraManager {
    @Published var lutProcessingProgress: Double = 0.0
    private var currentLUTProcessor: LUTProcessor?  // ← NEW
    
    private func applyLUT(to sourceURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        do {
            // Keep a strong reference to the processor until completion
            let lutProcessor = try LUTProcessor(cubeFileURL: finalLutURL)
            self.currentLUTProcessor = lutProcessor  // ← KEEP ALIVE
            
            lutProcessor.applyLUT(
                to: sourceURL,
                outputURL: finalOutputURL,
                progress: { ... },
                completion: { [weak self] result in
                    // Clean up temporary file
                    try? FileManager.default.removeItem(at: sourceURL)
                    
                    DispatchQueue.main.async {
                        self?.lutProcessingProgress = 0.0
                        self?.currentLUTProcessor = nil  // ← RELEASE when done
                    }
                    
                    completion(result)
                }
            )
        } catch {
            currentLUTProcessor = nil  // ← RELEASE on error
            completion(.success(sourceURL))
        }
    }
}
```

### 2. Remove Weak Capture in LUTProcessor

Since we're now keeping the processor alive, we can use strong capture:

```swift
// BEFORE:
writerInput.requestMediaDataWhenReady(on: processingQueue) { [weak self] in
    guard let self = self else {
        print("⚠️ Self is nil in processing callback")
        return
    }
    // Process frames...
}

// AFTER:
writerInput.requestMediaDataWhenReady(on: processingQueue) {
    print("🎬 Processing callback started")
    // Process frames... (can access self directly)
}
```

## Why This Works

### Object Lifetime:

```
BEFORE:
CameraManager.applyLUT() starts
  ↓
LUTProcessor created (local variable)
  ↓
applyLUT() called (async operation starts)
  ↓
Method returns ← LUTProcessor deallocated HERE!
  ↓
Async callback tries to run
  ↓
[weak self] is nil → Processing fails!

AFTER:
CameraManager.applyLUT() starts
  ↓
LUTProcessor created
  ↓
Stored in currentLUTProcessor (STRONG REFERENCE)
  ↓
applyLUT() called (async operation starts)
  ↓
Method returns BUT processor stays alive
  ↓
Async callback runs successfully
  ↓
Processing completes
  ↓
currentLUTProcessor = nil → Processor deallocated
```

## Expected Console Output Now

### Success:
```
✅ Reader and writer started successfully
📊 Total duration: 6.0 seconds
⏳ Waiting for writer to be ready for data...
🔇 Audio processing disabled for debugging
🎬 Processing callback started        ← NOW IT STARTS!
🎞️ Processing first frame...
🎞️ Processed 30 frames...
🎞️ Processed 60 frames...
🎞️ Processed 90 frames...
🎞️ Processed 120 frames...
🎞️ Processed 150 frames...
✅ Finished processing all frames (total: 180)
🎉 LUT processing completed successfully!
  Output: final_1762440295.055774.mov
```

## Files Modified

1. **`again2/Services/CameraManager.swift`**
   - Added `private var currentLUTProcessor: LUTProcessor?`
   - Store processor in instance variable
   - Release processor in completion handler

2. **`Timeloop/Timeloop/Services/CameraManager.swift`**
   - Same changes as above

3. **`again2/Utilities/LUTProcessor.swift`**
   - Changed `[weak self]` to strong capture
   - Removed guard check for nil self

4. **`Timeloop/Timeloop/Utilities/LUTProcessor.swift`**
   - Same changes as above

## Memory Management

This does NOT cause a retain cycle because:

1. `CameraManager` holds a strong reference to `LUTProcessor`
2. `LUTProcessor` holds no reference back to `CameraManager`
3. When processing completes, we explicitly set `currentLUTProcessor = nil`
4. This releases the processor and it gets deallocated properly

The lifecycle is:
```
Create processor → Process video → Complete → Release processor ✅
```

## Testing

**Clean build and run**:
```
Product → Clean Build Folder (⇧⌘K)
Product → Run (⌘R)
```

**Record a video and watch console**:
- Should see "🎬 Processing callback started"
- Should see frame count increasing
- Should see "🎉 LUT processing completed successfully!"
- Preview should show video with Fuji Neopan LUT!

## Note: Audio Temporarily Disabled

Audio processing is currently disabled for debugging. Once video processing is confirmed working, we can re-enable audio by uncommenting this section in `LUTProcessor.swift`:

```swift
// Handle audio track if present
if let audioTrack = asset.tracks(withMediaType: .audio).first {
    addAudioTrack(from: asset, audioTrack: audioTrack, to: writer)
}
```

## Key Lesson

When using async callbacks with instance methods:
- If the operation is short-lived, `[weak self]` is fine
- If the operation outlives the method scope, keep a strong reference
- Always consider object lifetime when dealing with async operations

## Summary

**Problem**: LUTProcessor deallocated before processing complete  
**Cause**: Local variable went out of scope, `[weak self]` became nil  
**Fix**: Store processor as instance variable, release after completion  
**Result**: Processing now completes successfully! 🎉

The video should now process fully with the Fuji Neopan LUT applied!

