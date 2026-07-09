import SwiftUI
import CoreGraphics
import CoreMedia
import Combine
import OSLog

@main
struct MacOSHostApp: App {
    @StateObject private var controller = HostController()
    
    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .frame(width: 400, height: 350)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

class HostController: ObservableObject, DisplayServerDelegate, ScreenCapturerDelegate, VideoEncoderDelegate {
    @Published var isServerRunning = false
    @Published var isDisplayCreated = false
    @Published var isClientConnected = false
    
    private var wrapper: VirtualDisplayWrapper?
    private let server = DisplayServer()
    private let capturer = ScreenCapturer()
    private let encoder = VideoEncoder()
    private let logger = Logger(subsystem: "com.wifidisplay.host", category: "HostController")
    
    private var currentStreamWidth = 0
    private var currentStreamHeight = 0
    
    init() {
        server.delegate = self
        capturer.delegate = self
        encoder.delegate = self
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    func toggleServer() {
        if isServerRunning {
            stopServer()
        } else {
            startServer()
        }
    }
    
    private func startServer() {
        server.start()
        isServerRunning = true
    }
    
    private func stopServer() {
        stopStreaming()
        server.stop()
        isServerRunning = false
    }
    
    func createVirtualDisplay() {
        guard wrapper == nil else { return }
        
        // Initialize the virtual display at 1920x1080.
        // Once created, the user can choose any resolution (including game and iPhone specific ratios)
        // directly from macOS System Settings > Displays, and the stream will dynamically adapt.
        let defaultWidth = 1920
        let defaultHeight = 1080
        let defaultPPI = 220
        let defaultHiDPI = false
        
        let wrapper = VirtualDisplayWrapper(name: "WiFi-Extension", width: Int32(defaultWidth), height: Int32(defaultHeight), ppi: Int32(defaultPPI), hiDPI: defaultHiDPI)
        
        if let wrapper = wrapper {
            self.wrapper = wrapper
            self.isDisplayCreated = true
            server.virtualDisplayID = wrapper.displayID
            
            if isClientConnected {
                startStreaming()
            }
        }
    }
    
    func destroyVirtualDisplay() {
        stopStreaming()
        wrapper?.destroy()
        wrapper = nil
        isDisplayCreated = false
        server.virtualDisplayID = nil
    }
    
    private func startStreaming() {
        guard isClientConnected, let displayID = wrapper?.displayID else { return }
        
        var actualWidth = Int(CGDisplayPixelsWide(displayID))
        var actualHeight = Int(CGDisplayPixelsHigh(displayID))
        
        // Fallback if querying fails
        if actualWidth == 0 || actualHeight == 0 {
            actualWidth = 1920
            actualHeight = 1080
        }
        
        logger.info("Starting stream with actual display dimensions: \(actualWidth)x\(actualHeight)")
        
        self.currentStreamWidth = actualWidth
        self.currentStreamHeight = actualHeight
        
        encoder.startSession(width: Int32(actualWidth), height: Int32(actualHeight))
        capturer.startCapture(displayID: displayID, width: actualWidth, height: actualHeight)
    }
    
    private func stopStreaming() {
        capturer.stopCapture()
        encoder.stopSession()
        self.currentStreamWidth = 0
        self.currentStreamHeight = 0
    }
    
    @objc private func screenParametersChanged() {
        guard isClientConnected, let displayID = wrapper?.displayID else { return }
        
        let actualWidth = Int(CGDisplayPixelsWide(displayID))
        let actualHeight = Int(CGDisplayPixelsHigh(displayID))
        
        if actualWidth == 0 || actualHeight == 0 { return }
        
        if actualWidth != currentStreamWidth || actualHeight != currentStreamHeight {
            logger.info("Display resolution changed dynamically from \(self.currentStreamWidth)x\(self.currentStreamHeight) to \(actualWidth)x\(actualHeight). Re-initializing stream...")
            
            // Re-initialize streaming at new resolution
            capturer.stopCapture()
            encoder.stopSession()
            
            self.currentStreamWidth = actualWidth
            self.currentStreamHeight = actualHeight
            
            encoder.startSession(width: Int32(actualWidth), height: Int32(actualHeight))
            capturer.startCapture(displayID: displayID, width: actualWidth, height: actualHeight)
        }
    }
    
    // MARK: - DisplayServerDelegate
    func didConnectClient() {
        DispatchQueue.main.async {
            self.isClientConnected = true
            if self.isDisplayCreated {
                self.startStreaming()
            }
        }
    }
    
    func didDisconnectClient() {
        DispatchQueue.main.async {
            self.isClientConnected = false
            self.stopStreaming()
        }
    }
    
    // MARK: - ScreenCapturerDelegate
    func didCaptureFrame(sampleBuffer: CMSampleBuffer) {
        encoder.encode(sampleBuffer: sampleBuffer)
    }
    
    // MARK: - VideoEncoderDelegate
    func didEncodeFrame(data: Data, isKeyFrame: Bool) {
        server.sendFrameData(data)
    }
}

struct ContentView: View {
    @ObservedObject var controller: HostController
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Wi-Fi Display Sharing (macOS Host)")
                .font(.headline)
                .padding(.top)
            
            GroupBox(label: Text("Server Controls")) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Server Status: \(controller.isServerRunning ? "ACTIVE" : "STOPPED")")
                            .bold()
                            .foregroundColor(controller.isServerRunning ? .green : .gray)
                        Text(controller.isClientConnected ? "Client Connected" : "Waiting for Client...")
                            .font(.caption)
                            .foregroundColor(controller.isClientConnected ? .green : .secondary)
                    }
                    Spacer()
                    Button(action: controller.toggleServer) {
                        Text(controller.isServerRunning ? "Stop Server" : "Start Server")
                            .frame(width: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.isServerRunning ? .red : .blue)
                }
                .padding(.vertical, 5)
            }
            
            GroupBox(label: Text("Virtual Display Settings")) {
                VStack(spacing: 10) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Virtual Display: \(controller.isDisplayCreated ? "CREATED" : "NONE")")
                                .bold()
                                .foregroundColor(controller.isDisplayCreated ? .blue : .gray)
                            Text("Configure resolution in macOS System Settings > Displays")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: {
                            if controller.isDisplayCreated {
                                controller.destroyVirtualDisplay()
                            } else {
                                controller.createVirtualDisplay()
                            }
                        }) {
                            Text(controller.isDisplayCreated ? "Destroy" : "Create")
                                .frame(width: 100)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!controller.isServerRunning)
                    }
                }
                .padding(.vertical, 5)
            }
            
            Spacer()
        }
        .padding()
    }
}
