import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var permissionError: String?
    @State private var setupError: String?
    
    var body: some View {
        ZStack {
            Theme.backgroundColor
                .ignoresSafeArea()
            
            if let previewLayer = cameraManager.previewLayer, cameraManager.isAuthorized {
                CameraPreviewView(previewLayer: previewLayer)
                    .ignoresSafeArea()
                    .onAppear {
                        cameraManager.startSession()
                    }
                    .onDisappear {
                        cameraManager.stopSession()
                    }
            } else if let error = permissionError ?? setupError {
                VStack(spacing: 20) {
                    Text("Camera Setup Error")
                        .foregroundColor(Theme.foregroundColor)
                        .font(.title2)
                    
                    Text(error)
                        .foregroundColor(Theme.foregroundColor.opacity(0.7))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                ProgressView()
                    .tint(Theme.foregroundColor)
            }
        }
        .task {
            await setupCamera()
        }
    }
    
    private func setupCamera() async {
        // Check permissions first
        let permissionsGranted = await cameraManager.checkPermissions()
        
        if !permissionsGranted {
            permissionError = "Camera and microphone access are required. Please enable them in Settings."
            return
        }
        
        // Setup camera
        do {
            try await cameraManager.setupCamera()
        } catch let error as CameraError {
            setupError = error.localizedDescription
        } catch {
            setupError = "An unexpected error occurred while setting up the camera."
        }
    }
}

