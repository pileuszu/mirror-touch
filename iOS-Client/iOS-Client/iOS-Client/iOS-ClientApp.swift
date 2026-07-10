import SwiftUI
import AVFoundation
import Combine
import Network
import OSLog

class ClientController: NSObject, ObservableObject, DisplayClientDelegate, VideoDecoderDelegate {
    @Published var client = DisplayClient()
    let decoder = VideoDecoder()
    let displayLayer = AVSampleBufferDisplayLayer()
    @Published var videoSize: CGSize = CGSize(width: 585, height: 1266)
    
    private let logger = Logger(subsystem: "com.wifidisplay.client", category: "ClientController")
    
    override init() {
        super.init()
        client.delegate = self
        decoder.delegate = self
    }
    
    func didConnect() {
        decoder.reset()
        DispatchQueue.main.async {
            self.displayLayer.sampleBufferRenderer.flush()
        }
    }
    
    func didDisconnect() {
        decoder.reset()
        DispatchQueue.main.async {
            self.displayLayer.sampleBufferRenderer.flush()
        }
    }
    
    func didReceiveFrameData(_ data: Data) {
        decoder.parseFrameData(data)
    }
    
    func didDecodeFrame(sampleBuffer: CMSampleBuffer) {
        self.logger.info("Successfully decoded frame!")
        DispatchQueue.main.async {
            if self.displayLayer.sampleBufferRenderer.status == .failed {
                self.logger.warning("Renderer status is failed, flushing...")
                self.displayLayer.sampleBufferRenderer.flush()
            }
            self.displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
            self.logger.info("Enqueued frame to displayLayer")
        }
    }
    
    func didUpdateDimensions(_ dimensions: CGSize) {
        DispatchQueue.main.async {
            if self.videoSize != dimensions {
                self.videoSize = dimensions
                self.logger.info("Updated video size: \(dimensions.width)x\(dimensions.height)")
            }
        }
    }
}

@main
struct iOSClientApp: App {
    @StateObject private var controller = ClientController()
    
    var body: some Scene {
        WindowGroup {
            MainView(controller: controller)
        }
    }
}

struct MainView: View {
    @ObservedObject var controller: ClientController
    @ObservedObject var client: DisplayClient
    
    init(controller: ClientController) {
        self.controller = controller
        self.client = controller.client
    }
    
    var body: some View {
        if client.isConnected {
            DisplayView(client: client, displayLayer: controller.displayLayer, videoSize: controller.videoSize)
                .onDisappear {
                    client.disconnect()
                }
        } else {
            HostSelectionView(client: client)
                .onAppear {
                    client.startBrowsing()
                }
                .onDisappear {
                    client.stopBrowsing()
                }
        }
    }
}

struct HostSelectionView: View {
    @ObservedObject var client: DisplayClient
    
    @State private var connectionMode = 0 // 0: Auto Discover, 1: Direct IP / Wired
    @State private var ipAddress = "172.20.10.2" // Default Mac IP over USB tethering
    @State private var portString = "8080"
    
    var body: some View {
        NavigationView {
            VStack {
                Picker("Connection Mode", selection: $connectionMode) {
                    Text("Auto Discover").tag(0)
                    Text("Direct IP (USB / Wired)").tag(1)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                if connectionMode == 0 {
                    // Auto-Discovery Mode (Wi-Fi & USB Automatic Broadcast)
                    Text(client.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    List(client.discoveredHosts) { host in
                        Button(action: {
                            client.connect(to: host.endpoint)
                        }) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(host.name)
                                        .font(.headline)
                                    
                                    HStack {
                                        Image(systemName: host.connectionType == "USB / Cable" ? "cable.connector.horizontal" : "wifi")
                                            .font(.caption)
                                        Text(host.connectionType)
                                            .font(.caption)
                                    }
                                    .foregroundColor(host.connectionType == "USB / Cable" ? .blue : .secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .listStyle(InsetGroupedListStyle())
                } else {
                    // Direct IP Mode (USB Cable / Manual IP)
                    Form {
                        Section(header: Text("Host Configuration")) {
                            HStack {
                                Text("IP Address")
                                Spacer()
                                TextField("Mac IP (e.g. 172.20.10.2)", text: $ipAddress)
                                    .keyboardType(.numbersAndPunctuation)
                                    .multilineTextAlignment(.trailing)
                            }
                            
                            HStack {
                                Text("Port")
                                Spacer()
                                TextField("8080", text: $portString)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        
                        Section {
                            Button(action: {
                                if let port = UInt16(portString) {
                                    client.connectToHost(ip: ipAddress, port: port)
                                }
                            }) {
                                HStack {
                                    Spacer()
                                    Text("Connect Direct / Wired")
                                        .bold()
                                    Spacer()
                                }
                            }
                            .foregroundColor(.white)
                            .listRowBackground(Color.blue)
                        }
                        
                        Section(footer: Text("💡 Connection Tip:\nIf you are using a USB cable connection, turn on 'Personal Hotspot' (개인 핫스팟) on your iPhone and connect the USB cable. Your Mac will automatically connect over the high-speed USB interface and typically reside at IP address '172.20.10.2'.")) {
                            EmptyView()
                        }
                    }
                }
            }
            .navigationTitle("MirrorTouch")
        }
    }
}
