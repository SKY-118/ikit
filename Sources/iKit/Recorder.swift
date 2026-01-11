import Foundation
import ScreenCaptureKit
import AVFoundation

@available(macOS 13.0, *)
class MeetingRecorder: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    
    var isRecording = false
    var isFinished = false
    private var startTime: CMTime?
    
    private var lastScreenshotTime: Date = Date()
    private var screenshotInterval: TimeInterval = 10.0 // Default
    private var outputDirectory: String = ""

    func start(targetAppKeywords: [String], outputPath: String, duration: Double? = nil, screenshotInterval: Double? = nil) async throws {
        if let interval = screenshotInterval { self.screenshotInterval = interval }
        self.outputDirectory = (outputPath as NSString).deletingLastPathComponent
        print("🔍 Scanning for apps: \(targetAppKeywords.joined(separator: ", "))")
        
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let apps = content.applications.filter { app in
            let name = app.applicationName.lowercased()
            return targetAppKeywords.contains { name.contains($0.lowercased()) }
        }
        
        guard let display = content.displays.first else {
            throw NSError(domain: "iKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        
        let filter = apps.isEmpty ? 
            SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []) :
            SCContentFilter(display: display, including: apps, exceptingWindows: [])
            
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        
        // Enable video capture for screenshots
        config.width = 1280
        config.height = 720
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS is enough for us
        
        let url = URL(fileURLWithPath: outputPath)
        if FileManager.default.fileExists(atPath: outputPath) { try? FileManager.default.removeItem(at: url) }
        
        assetWriter = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48000,
            AVEncoderBitRateKey: 128000
        ]
        
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        audioInput?.expectsMediaDataInRealTime = true
        if let input = audioInput, assetWriter?.canAdd(input) == true { assetWriter?.add(input) }
        
        try assetWriter?.startWriting()
        
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .background))
        
        try await stream?.startCapture()
        isRecording = true
        // ... (rest of timer logic)
        
        if let d = duration {
            print("🔴 Recording for \(d) seconds...")
            Task {
                try await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000))
                if isRecording { try await self.stop() }
            }
        } else {
            print("🔴 Recording... (Press Enter to stop)")
        }
    }
    
    func stop() async throws {
        isRecording = false
        print("⏳ Stopping capture...")
        try await stream?.stopCapture()
        
        audioInput?.markAsFinished()
        await assetWriter?.finishWriting()
        isFinished = true
        print("✅ File saved.")
    }
    
        // MARK: - SCStreamOutput
    
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    
            guard isRecording else { return }
    
            
    
            if type == .audio {
    
                if startTime == nil {
    
                    startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    
                    assetWriter?.startSession(atSourceTime: startTime!)
    
                    print("🎵 Audio session started.")
    
                }
    
                
    
                if audioInput?.isReadyForMoreMediaData == true {
    
                    audioInput?.append(sampleBuffer)
    
                }
    
            } else if type == .screen {
    
                // Handle periodic screenshots
    
                let now = Date()
    
                if now.timeIntervalSince(lastScreenshotTime) >= screenshotInterval {
    
                    lastScreenshotTime = now
    
                    saveScreenshot(from: sampleBuffer)
    
                }
    
            }
    
        }
    
        
    
        private func saveScreenshot(from sampleBuffer: CMSampleBuffer) {
    
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    
            let ciImage = CIImage(cvImageBuffer: imageBuffer)
    
            let context = CIContext()
    
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
    
            
    
            let timestamp = Int(Date().timeIntervalSince1970)
    
            let screenshotPath = "\(outputDirectory)/screenshot_\(timestamp).jpg"
    
            let url = URL(fileURLWithPath: screenshotPath)
    
            
    
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
    
            guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [:]) else { return }
    
            
    
            do {
    
                try jpegData.write(to: url)
    
                print("📸 Screenshot saved: \(url.lastPathComponent)")
    
            } catch {
    
                print("❌ Failed to save screenshot: \(error)")
    
            }
    
        }
    
    }
    
    