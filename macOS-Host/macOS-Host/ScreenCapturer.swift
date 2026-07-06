import Foundation
import ScreenCaptureKit
import CoreMedia
import OSLog

protocol ScreenCapturerDelegate: AnyObject {
    func didCaptureFrame(sampleBuffer: CMSampleBuffer)
}

class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.wifidisplay.capturer", qos: .userInteractive)
    weak var delegate: ScreenCapturerDelegate?
    
    private let logger = Logger(subsystem: "com.wifidisplay.host", category: "ScreenCapturer")
    
    func startCapture(displayID: CGDirectDisplayID, width: Int, height: Int) {
        Task { [weak self] in
            guard let self = self else { return }
            
            var attempt = 0
            let maxAttempts = 6 // Retry for up to 3 seconds to let macOS register the new virtual display
            
            while attempt < maxAttempts {
                attempt += 1
                self.logger.info("Attempting to start screen capture (attempt \(attempt)/\(maxAttempts))...")
                
                do {
                    // Slight delay to avoid race conditions with display registration
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                    
                    let content = try await SCShareableContent.current
                    
                    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                        self.logger.warning("Display \(displayID) not found in shareable content yet. Retrying...")
                        continue
                    }
                    
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    
                    let config = SCStreamConfiguration()
                    config.width = width
                    config.height = height
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // Target 60 fps
                    config.queueDepth = 5
                    config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // NV12 is efficient for H.264/HEVC encoding
                    config.colorSpaceName = CGColorSpace.sRGB
                    
                    let stream = SCStream(filter: filter, configuration: config, delegate: self)
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    
                    try await stream.startCapture()
                    self.logger.info("Successfully started screen capture for display \(displayID)")
                    self.stream = stream
                    return // Success! Exit loop
                } catch {
                    self.logger.error("Failed to start capture stream on attempt \(attempt): \(error.localizedDescription, privacy: .public)")
                    self.stream = nil
                }
            }
            
            self.logger.error("Failed to start screen capture after \(maxAttempts) attempts.")
        }
    }
    
    func stopCapture() {
        guard let stream = stream else { return }
        stream.stopCapture { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to stop capture stream: \(error.localizedDescription)")
            } else {
                self?.logger.info("Successfully stopped screen capture")
            }
            self?.stream = nil
        }
    }
    
    // MARK: - SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        delegate?.didCaptureFrame(sampleBuffer: sampleBuffer)
    }
    
    // MARK: - SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Stream stopped with error: \(error.localizedDescription)")
    }
}
