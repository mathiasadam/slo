# Slo - Slow Motion Camera App

A beautiful iOS camera app that captures 240fps slow-motion video with professional color grading using LUTs.

## Features

- **240fps Slow Motion**: Captures 1.5 seconds at 240fps, then stretches it to 6 seconds for dramatic slow-motion effects
- **Professional Color Grading**: Applies Fuji Neopan LUT for cinematic black & white film look
- **Real-time Preview**: Live camera preview with recording progress indicator
- **Metal-Accelerated Processing**: Uses Metal and Core Image for high-performance video processing
- **Portrait Optimized**: Designed for vertical video capture with cinematic stabilization

## Technical Details

### Video Processing Pipeline

1. **Capture**: Records at 240fps using iPhone's high-speed camera
2. **Time Stretch**: Extends the video duration by 4x (1.5s → 6s)
3. **LUT Application**: Applies Fuji Neopan color cube LUT for cinematic look
4. **Export**: Outputs high-quality H.264 video at 10 Mbps

### LUT System

The app includes a custom LUT processing system that:
- Parses `.cube` files (3D color lookup tables)
- Converts them to Core Image `CIColorCube` filters
- Applies them frame-by-frame during video export
- Uses Metal for hardware-accelerated rendering

### Project Structure

```
slo/
├── again2/                          # Main camera app
│   ├── Services/
│   │   └── CameraManager.swift      # Camera and recording logic
│   ├── Views/
│   │   ├── CameraView.swift         # Main camera interface
│   │   ├── CameraPreviewView.swift  # AVCaptureVideoPreviewLayer wrapper
│   │   └── PreviewView.swift        # Video playback preview
│   └── Utilities/
│       ├── LUTParser.swift          # Parses .cube LUT files
│       ├── LUTProcessor.swift       # Applies LUTs to video
│       └── Fuji_Neopan.cube         # Fuji Neopan film LUT
└── Timeloop/                        # Alternate version
    └── Timeloop/
        └── (same structure as again2)
```

## Adding Custom LUTs

To add your own LUT:

1. Place your `.cube` file in the `Utilities/` folder
2. Update the LUT file name in `CameraManager.swift`:

```swift
guard let lutURL = Bundle.main.url(forResource: "YourLUTName", withExtension: "cube", subdirectory: "Utilities") else {
    // ...
}
```

### LUT File Format

The app supports standard `.cube` format (3D LUT):

```
TITLE "Your LUT Name"
LUT_3D_SIZE 32

0.0224 0.0224 0.0224
0.0293 0.0293 0.0293
...
```

## Requirements

- iOS 18.0+
- iPhone with 240fps camera support (iPhone 8 or newer)
- Xcode 16.0+
- Swift 5.0+

## Permissions

The app requires:
- Camera access (for video capture)
- Microphone access (for audio recording)

## Building

1. Open `again2.xcodeproj` or `Timeloop.xcodeproj` in Xcode
2. Select your development team
3. Build and run on a physical iPhone (240fps not supported in Simulator)

## Performance

- LUT processing is done frame-by-frame with progress indication
- Uses Metal-backed `CIContext` for optimal performance
- Processes 6-second 1080p video in ~10-20 seconds (depending on device)

## Credits

- **LUT**: Fuji Neopan film emulation by Adamq
- **Framework**: AVFoundation, Core Image, Metal
