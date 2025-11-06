# LUT Integration Guide

This document explains how the LUT (Look-Up Table) post-processing system works in the Slo camera app.

## Overview

The app applies a **Fuji Neopan** LUT to all recorded videos, giving them a classic black & white film look. The LUT is applied as part of the video export pipeline after the slow-motion time-stretch effect.

## How It Works

### 1. Video Processing Pipeline

```
Record 240fps → Time Stretch (1.5s → 6s) → Apply LUT → Export Final Video
```

### 2. LUT Processing Components

#### LUTParser.swift
Parses `.cube` files and converts them to Core Image compatible data:
- Reads the cube file format
- Extracts RGB values for each LUT entry
- Converts to `CIColorCube` filter format
- Handles 32x32x32 3D LUTs (32,768 color mappings)

#### LUTProcessor.swift
Applies the LUT to video frames:
- Uses Metal-backed `CIContext` for GPU acceleration
- Processes video frame-by-frame
- Maintains video orientation and audio tracks
- Reports progress during processing
- Exports at high quality (10 Mbps H.264)

#### CameraManager.swift
Orchestrates the video pipeline:
- Records at 240fps
- Creates slow-motion composition
- Applies LUT through `LUTProcessor`
- Publishes progress updates to UI
- Handles cleanup of temporary files

## User Experience

### Recording Flow
1. User taps record button
2. Records for 1.5 seconds (auto-stops)
3. Shows "Processing..." overlay
4. Creates slow-motion effect (4x time stretch)
5. Shows "Applying Fuji Neopan LUT..." with progress percentage
6. Displays final video in preview

### Progress Indication
The UI shows two types of progress:
- **Generic spinner**: During slow-motion creation
- **Circular progress (0-100%)**: During LUT application

## Technical Specifications

### LUT File Format
```
TITLE "Adanmq_Fuji Neopan"
LUT_3D_SIZE 32

0.0224 0.0224 0.0224
0.0293 0.0293 0.0293
...
(32,768 RGB triplets)
```

### Core Image Integration
- Uses `CIColorCube` filter
- Requires RGBA format (32 bits per pixel)
- Dimension: 32x32x32 color cube
- Data size: 131,072 bytes (32³ × 4 channels × 4 bytes/float)

### Performance Characteristics
- **Input**: 1080p video at 240fps (time-stretched to ~40fps effective)
- **Processing time**: ~10-20 seconds for 6-second video
- **Memory**: Uses Metal shared memory for efficiency
- **Quality**: 10 Mbps H.264, maintains original resolution

## Adding Custom LUTs

### Step 1: Prepare Your LUT
Ensure your LUT is in `.cube` format with a power-of-2 dimension (16, 32, or 64).

### Step 2: Add to Project
```bash
cp YourLUT.cube Utilities/
```

### Step 3: Update CameraManager
In `CameraManager.swift`, modify the `applyLUT` method:

```swift
guard let lutURL = Bundle.main.url(
    forResource: "YourLUT",  // Change this
    withExtension: "cube",
    subdirectory: "Utilities"
) else {
    // ...
}
```

### Step 4: Update UI Text (Optional)
In `CameraView.swift`, update the processing message:

```swift
Text(cameraManager.lutProcessingProgress > 0 ? 
     "Applying Your LUT Name..." : // Change this
     "Processing...")
```

## Troubleshooting

### LUT Not Applied
If the LUT isn't being applied:
1. Check Console for "LUT file not found" warning
2. Verify the `.cube` file is in `Utilities/` directory
3. Ensure the file is included in the Xcode project
4. Check that the resource name matches exactly (case-sensitive)

### Slow Processing
If LUT processing is too slow:
- Ensure you're testing on a physical device (not Simulator)
- Check that Metal is being used (look for MTLDevice in logs)
- Consider using a smaller LUT size (16x16x16 instead of 32x32x32)

### Color Issues
If colors look wrong:
- Verify your LUT file is valid (check with a `.cube` validator)
- Ensure RGB values are in 0.0-1.0 range
- Check that `LUT_3D_SIZE` matches your data (32 → 32,768 entries)

## Disabling LUT Processing

To temporarily disable LUT processing, modify the `applyLUT` method in `CameraManager.swift`:

```swift
private func applyLUT(to sourceURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
    // Skip LUT processing - return original video
    completion(.success(sourceURL))
    return
    
    // ... rest of the code ...
}
```

## Advanced: Multiple LUTs

To support multiple LUTs, you could:
1. Add a LUT picker UI
2. Store selected LUT name in `@AppStorage`
3. Load different LUT based on user selection

Example:
```swift
@AppStorage("selectedLUT") private var selectedLUT = "Fuji_Neopan"

private func applyLUT(to sourceURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
    guard let lutURL = Bundle.main.url(
        forResource: selectedLUT,
        withExtension: "cube",
        subdirectory: "Utilities"
    ) else {
        // ...
    }
    // ...
}
```

## Future Enhancements

Potential improvements to the LUT system:
- **Real-time preview**: Apply LUT during live camera preview
- **LUT library**: Include multiple built-in LUTs
- **Custom LUT import**: Allow users to import their own LUTs
- **LUT intensity control**: Blend between original and LUT-processed
- **Batch processing**: Apply LUTs to existing videos in Photos library

## Resources

- [Adobe Cube LUT Specification](https://wwwimages.adobe.com/content/dam/acom/en/products/speedgrade/cc/pdfs/cube-lut-specification-1.0.pdf)
- [Core Image Filter Reference - CIColorCube](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html#//apple_ref/doc/filter/ci/CIColorCube)
- [AVFoundation Video Composition](https://developer.apple.com/documentation/avfoundation/avvideocomposition)

