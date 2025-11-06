import Foundation
import AVFoundation
import CoreImage
import CoreMedia

class LUTProcessor {
    
    private let lutFilter: CIFilter
    private let context: CIContext
    
    init(cubeFileURL: URL) throws {
        print("🎨 Initializing LUT Processor with file: \(cubeFileURL.lastPathComponent)")
        
        self.lutFilter = try LUTParser.createColorCubeFilter(from: cubeFileURL)
        print("✅ LUT filter created successfully")
        
        // Create Metal-backed CIContext for better performance
        if let device = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: device)
            print("✅ Metal-backed CIContext created with device: \(device.name)")
        } else {
            self.context = CIContext()
            print("⚠️ Fallback to standard CIContext (no Metal)")
        }
    }
    
    // Apply LUT to a video and export it
    func applyLUT(to sourceURL: URL, outputURL: URL, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        print("🎬 Starting LUT processing")
        print("  Source: \(sourceURL.lastPathComponent)")
        print("  Source path: \(sourceURL.path)")
        print("  Output: \(outputURL.lastPathComponent)")
        print("  Output path: \(outputURL.path)")
        
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
        
        let asset = AVAsset(url: sourceURL)
        
        // Wait a moment for asset to load
        Task {
            do {
                // Load tracks asynchronously
                let tracks = try await asset.load(.tracks)
                let videoTracks = tracks.filter { $0.mediaType == .video }
                
                guard let videoTrack = videoTracks.first else {
                    print("❌ No video track found in source")
                    completion(.failure(LUTError.invalidFormat("No video track found")))
                    return
                }
                
                let naturalSize = try await videoTrack.load(.naturalSize)
                let preferredTransform = try await videoTrack.load(.preferredTransform)
                print("  Video: \(naturalSize.width)x\(naturalSize.height)")
                
                // Continue processing synchronously
                DispatchQueue.global(qos: .userInitiated).async {
                    self.processVideo(
                        asset: asset,
                        videoTrack: videoTrack,
                        naturalSize: naturalSize,
                        preferredTransform: preferredTransform,
                        sourceURL: sourceURL,
                        outputURL: outputURL,
                        progress: progress,
                        completion: completion
                    )
                }
            } catch {
                print("❌ Failed to load asset: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }
    
    private func processVideo(asset: AVAsset, videoTrack: AVAssetTrack, naturalSize: CGSize, preferredTransform: CGAffineTransform, sourceURL: URL, outputURL: URL, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        print("📹 Setting up reader and writer...")
        
        // Setup reader - must keep strong references for async callback
        guard let reader = try? AVAssetReader(asset: asset) else {
            print("❌ Failed to create AVAssetReader")
            completion(.failure(LUTError.filterCreationFailed))
            return
        }
        
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        
        guard reader.canAdd(readerOutput) else {
            print("❌ Cannot add readerOutput to reader")
            completion(.failure(LUTError.filterCreationFailed))
            return
        }
        
        reader.add(readerOutput)
        print("✅ Added reader output to reader")
        
        // Setup writer
        guard let writer = try? AVAssetWriter(url: outputURL, fileType: .mov) else {
            completion(.failure(LUTError.filterCreationFailed))
            return
        }
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: naturalSize.width,
            AVVideoHeightKey: naturalSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000, // 10 Mbps for high quality
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = preferredTransform
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(naturalSize.width),
                kCVPixelBufferHeightKey as String: Int(naturalSize.height)
            ]
        )
        
        writer.add(writerInput)
        
        // Start processing
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
        
        let processingQueue = DispatchQueue(label: "com.slo.lutprocessing")
        let totalDuration = CMTimeGetSeconds(asset.duration)
        print("📊 Total duration: \(totalDuration) seconds")
        
        var frameCount = 0
        let frameCountQueue = DispatchQueue(label: "com.slo.framecount")
        
        print("⏳ Waiting for writer to be ready for data...")
        
        // Keep strong references to reader, readerOutput, writer, and adaptor in the closure
        writerInput.requestMediaDataWhenReady(on: processingQueue) { [reader, readerOutput, writer, adaptor] in
            print("🎬 Processing callback started")
            
            while writerInput.isReadyForMoreMediaData {
                autoreleasepool {
                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        // Finished reading
                        print("✅ Finished processing all frames (total: \(frameCount))")
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                print("🎉 LUT processing completed successfully!")
                                print("  Output: \(outputURL.lastPathComponent)")
                                completion(.success(outputURL))
                            } else {
                                print("❌ Export failed: \(writer.error?.localizedDescription ?? "Unknown error")")
                                completion(.failure(writer.error ?? LUTError.filterCreationFailed))
                            }
                        }
                        return
                    }
                    
                    frameCountQueue.sync {
                        frameCount += 1
                        if frameCount == 1 {
                            print("🎞️ Processing first frame...")
                        } else if frameCount % 30 == 0 {
                            print("🎞️ Processed \(frameCount) frames...")
                        }
                    }
                    
                    // Process frame with LUT
                    if let processedBuffer = self.processFrame(sampleBuffer: sampleBuffer) {
                        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        adaptor.append(processedBuffer, withPresentationTime: presentationTime)
                        
                        // Report progress
                        let currentTime = CMTimeGetSeconds(presentationTime)
                        let progressValue = min(currentTime / totalDuration, 1.0)
                        DispatchQueue.main.async {
                            progress(progressValue)
                        }
                    } else {
                        print("⚠️ Failed to process frame \(frameCount)")
                    }
                }
            }
            
            print("⚠️ Writer is no longer ready for more data, waiting...")
        }
        
        print("🔇 No audio - video only export")
    }
    
    private func processFrame(sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("❌ No image buffer in sample")
            return nil
        }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        
        // Apply LUT filter
        lutFilter.setValue(ciImage, forKey: kCIInputImageKey)
        
        guard let outputImage = lutFilter.outputImage else {
            print("❌ LUT filter produced no output")
            return nil
        }
        
        // Create output pixel buffer
        var pixelBuffer: CVPixelBuffer?
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let outputBuffer = pixelBuffer else {
            print("❌ Failed to create pixel buffer: status=\(status)")
            return nil
        }
        
        // Render filtered image to pixel buffer
        context.render(outputImage, to: outputBuffer)
        
        return outputBuffer
    }
    
}

