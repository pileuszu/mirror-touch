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
    @Published var selectedResolution = Resolution(width: 585, height: 1266, ppi: 230, hiDPI: true, name: "iPhone 13/14 Pro (Portrait - Optimized)")
    
    private var wrapper: VirtualDisplayWrapper?
    private let server = DisplayServer()
    private let capturer = ScreenCapturer()
    private let encoder = VideoEncoder()
    private let logger = Logger(subsystem: "com.wifidisplay.host", category: "HostController")
    
    struct Resolution: Hashable {
        let width: Int
        let height: Int
        let ppi: Int
        let hiDPI: Bool
        let name: String
    }
    
    let resolutions = [
        // Optimized scaled-down options (reduces pixel count 4x for ultra-low streaming latency)
        Resolution(width: 585, height: 1266, ppi: 230, hiDPI: true, name: "iPhone 13/14 Pro (Portrait - Optimized)"),
        Resolution(width: 1266, height: 585, ppi: 230, hiDPI: true, name: "iPhone 13/14 Pro (Landscape - Optimized)"),
        Resolution(width: 645, height: 1398, ppi: 230, hiDPI: true, name: "iPhone 14/15 Pro Max (Portrait - Optimized)"),
        Resolution(width: 1398, height: 645, ppi: 230, hiDPI: true, name: "iPhone 14/15 Pro Max (Landscape - Optimized)"),
        Resolution(width: 414, height: 896, ppi: 163, hiDPI: true, name: "iPhone 11 / XR (Portrait - Optimized)"),
        Resolution(width: 896, height: 414, ppi: 163, hiDPI: true, name: "iPhone 11 / XR (Landscape - Optimized)"),
        
        // High Quality Native Options
        Resolution(width: 1170, height: 2532, ppi: 460, hiDPI: true, name: "iPhone 13/14 Pro (Portrait - Native)"),
        Resolution(width: 2532, height: 1170, ppi: 460, hiDPI: true, name: "iPhone 13/14 Pro (Landscape - Native)"),
        Resolution(width: 1920, height: 1080, ppi: 220, hiDPI: false, name: "Standard 1080p"),
        
        // 4:3 Game Mode Options
        Resolution(width: 1024, height: 768, ppi: 150, hiDPI: false, name: "Game Mode Fullscreen (1024x768 - 4:3)"),
        Resolution(width: 1024, height: 840, ppi: 150, hiDPI: false, name: "Game Mode Windowed (1024x840 - Height Buffer)"),
        Resolution(width: 2048, height: 1536, ppi: 264, hiDPI: true, name: "Game Mode Retina Full (2048x1536 - 4:3)"),
        Resolution(width: 2048, height: 1680, ppi: 264, hiDPI: true, name: "Game Mode Retina Windowed (2048x1680)")
    ]
    
    init() {
        server.delegate = self
        capturer.delegate = self
        encoder.delegate = self
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
        
        let res = selectedResolution
        let wrapper = VirtualDisplayWrapper(name: "WiFi-Extension", width: Int32(res.width), height: Int32(res.height), ppi: Int32(res.ppi), hiDPI: res.hiDPI)
        
        if let wrapper = wrapper {
            self.wrapper = wrapper
            self.isDisplayCreated = true
            
            server.virtualDisplayID = wrapper.displayID
            server.virtualDisplayWidth = CGFloat(res.width)
            server.virtualDisplayHeight = CGFloat(res.height)
            
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
        
        // Fallback to selected resolution if querying fails
        if actualWidth == 0 || actualHeight == 0 {
            let res = selectedResolution
            actualWidth = res.width
            actualHeight = res.height
        }
        
        logger.info("Starting stream with actual display dimensions: \(actualWidth)x\(actualHeight)")
        
        encoder.startSession(width: Int32(actualWidth), height: Int32(actualHeight))
        capturer.startCapture(displayID: displayID, width: actualWidth, height: actualHeight)
    }
    
    private func stopStreaming() {
        capturer.stopCapture()
        encoder.stopSession()
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
                        Text("Target Client:")
                        Spacer()
                        Picker("", selection: $controller.selectedResolution) {
                            ForEach(controller.resolutions, id: \.self) { res in
                                Text("\(res.name) (\(res.width)x\(res.height))").tag(res)
                            }
                        }
                        .labelsHidden()
                        .disabled(controller.isDisplayCreated)
                    }
                    
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Virtual Display: \(controller.isDisplayCreated ? "CREATED" : "NONE")")
                                .bold()
                                .foregroundColor(controller.isDisplayCreated ? .blue : .gray)
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
