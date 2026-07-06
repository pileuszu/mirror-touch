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
    
    var body: some View {
        NavigationView {
            VStack {
                Text(client.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding()
                
                List(client.discoveredHosts) { host in
                    Button(action: {
                        client.connect(to: host.endpoint)
                    }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(host.name)
                                    .font(.headline)
                                Text("Bonjour Service")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
            }
            .navigationTitle("Select Mac Host")
        }
    }
}
