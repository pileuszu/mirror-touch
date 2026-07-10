import SwiftUI
import CoreGraphics
import CoreMedia
import Combine
import OSLog
import Darwin

@main
struct MacOSHostApp: App {
    @StateObject private var controller = HostController()
    
    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .frame(width: 420, height: 420)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

class HostController: ObservableObject, DisplayServerDelegate, ScreenCapturerDelegate, VideoEncoderDelegate {
    @Published var isServerRunning = false
    @Published var isDisplayCreated = false
    @Published var isClientConnected = false
    @Published var activeIPs: [IPEntry] = []
    
    struct IPEntry: Identifiable, Hashable {
        let id: String
        let interface: String
        let ip: String
        let friendlyName: String
    }
    
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
        
        updateActiveIPs()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    func updateActiveIPs() {
        var ips = [IPEntry]()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            var addr = ptr.pointee.ifa_addr.pointee
            
            // Check for UP, non-LOOPBACK
            if (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0 {
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(&addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        let name = String(cString: ptr.pointee.ifa_name)
                        let friendly = friendlyInterfaceName(name)
                        
                        // Prevent duplicates
                        if !ips.contains(where: { $0.ip == ip }) {
                            ips.append(IPEntry(id: "\(name)-\(ip)", interface: name, ip: ip, friendlyName: friendly))
                        }
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        
        DispatchQueue.main.async {
            self.activeIPs = ips.sorted { $0.interface < $1.interface }
        }
    }
    
    private func friendlyInterfaceName(_ name: String) -> String {
        if name.hasPrefix("en") {
            if name == "en0" {
                return "Wi-Fi / Ethernet"
            }
            return "Wired / USB Connection"
        } else if name.hasPrefix("bridge") {
            return "Internet Sharing"
        } else if name.hasPrefix("ap") {
            return "Access Point"
        } else if name.hasPrefix("awdl") {
            return "AirDrop / Apple P2P"
        }
        return "Network Interface"
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
        updateActiveIPs()
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
            
            if controller.isServerRunning {
                GroupBox(label: Text("Network Connection Info")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Connect your phone using one of these IPs in Direct IP tab:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 2)
                        
                        if controller.activeIPs.isEmpty {
                            Text("No active IPv4 interfaces found")
                                .font(.caption)
                                .foregroundColor(.red)
                        } else {
                            ForEach(controller.activeIPs) { entry in
                                HStack {
                                    Text("\(entry.friendlyName) (\(entry.interface)):")
                                        .bold()
                                        .font(.caption)
                                    Spacer()
                                    Text(entry.ip)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
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
