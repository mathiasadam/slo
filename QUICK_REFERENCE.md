# Quick Reference - LUT System

## File Structure
```
Utilities/
├── Fuji_Neopan.cube    # The LUT color data (32x32x32)
├── LUTParser.swift      # Parses .cube files → CIFilter
└── LUTProcessor.swift   # Applies LUT to video frames
```

## Key Code Locations

### Load LUT
`CameraManager.swift` line ~290:
```swift
Bundle.main.url(forResource: "Fuji_Neopan", withExtension: "cube", subdirectory: "Utilities")
```

### Apply LUT to Video
`CameraManager.swift` line ~303:
```swift
lutProcessor.applyLUT(to: sourceURL, outputURL: finalOutputURL, progress: { ... })
```

### UI Progress Display
`CameraView.swift` line ~115-130:
```swift
if cameraManager.lutProcessingProgress > 0 {
    // Show circular progress and percentage
}
```

## Quick Commands

### Test a Different LUT
```bash
# Copy your LUT
cp /path/to/your.cube Utilities/

# Update CameraManager.swift
# Change "Fuji_Neopan" to "your"
```

### Debug LUT Loading
Add to `applyLUT()`:
```swift
print("Looking for LUT at: \(lutURL?.path ?? "nil")")
```

### Bypass LUT (for testing)
In `CameraManager.applyLUT()`:
```swift
completion(.success(sourceURL))
return  // Early return skips LUT
```

## Common Issues

| Issue | Solution |
|-------|----------|
| "LUT file not found" | Check file is in Utilities/ and name matches exactly |
| Slow processing | Use physical device, not Simulator |
| Colors wrong | Verify .cube format is valid (RGB 0.0-1.0) |
| Crash on Metal | Check device supports Metal (iPhone 5s+) |

## Performance Metrics

- **32x32x32 LUT**: ~10-20s for 6s video (iPhone 12+)
- **16x16x16 LUT**: ~5-10s (faster, less accurate)
- **64x64x64 LUT**: ~30-40s (slower, more accurate)

## Testing Checklist

- [ ] LUT file loads without errors
- [ ] Progress bar shows 0-100%
- [ ] "Applying Fuji Neopan LUT..." message appears
- [ ] Final video has color grading applied
- [ ] Audio is preserved
- [ ] Video orientation is correct
- [ ] Temporary files are cleaned up

## Code Snippets

### Parse a LUT manually
```swift
let (lutData, dimension) = try LUTParser.parseCubeFile(at: cubeURL)
print("LUT size: \(dimension)x\(dimension)x\(dimension)")
```

### Create CIFilter from LUT
```swift
let filter = try LUTParser.createColorCubeFilter(from: cubeURL)
filter.setValue(inputImage, forKey: kCIInputImageKey)
let output = filter.outputImage
```

### Apply to single image
```swift
let processor = try LUTProcessor(cubeFileURL: lutURL)
// Use processor.lutFilter directly
```

## Architecture

```
User taps record
    ↓
CameraManager.startRecording()
    ↓
AVCaptureMovieFileOutput records 1.5s @ 240fps
    ↓
CameraManager.createSlowMotionVideo()
    ↓ [Time stretch: 1.5s → 6s]
    ↓
CameraManager.applyLUT()
    ↓ [Load cube file]
LUTParser.parseCubeFile()
    ↓ [Convert to RGBA data]
    ↓
LUTProcessor.applyLUT()
    ↓ [Process frame-by-frame]
    ↓ [CIColorCube filter + Metal rendering]
    ↓
Export final video
    ↓
Show in PreviewView
```

## Key Classes

| Class | Purpose |
|-------|---------|
| `LUTParser` | Static methods to parse .cube files |
| `LUTProcessor` | Instance that processes entire videos |
| `CameraManager` | Coordinates capture → process → LUT |
| `CameraView` | Shows progress UI |

## Modifying the LUT Effect

### Adjust Intensity (blend original with LUT)
In `LUTProcessor.processFrame()`:
```swift
let blended = CIFilter(name: "CIBlendWithMask")!
blended.setValue(outputImage, forKey: kCIInputImageKey)
blended.setValue(ciImage, forKey: kCIInputBackgroundImageKey)
// Add intensity control here
```

### Apply to Preview (not just export)
Would require adding video output with real-time Core Image filter.
See: `AVCaptureVideoDataOutput` + live filter rendering

## Resources

- Source: `/Users/mathiasadam/Desktop/slo/`
- Projects: `again2.xcodeproj`, `Timeloop.xcodeproj`
- Docs: `README.md`, `LUT_GUIDE.md`

