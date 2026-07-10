import Foundation
import Network
import OSLog
import Combine

protocol DisplayClientDelegate: AnyObject {
    func didConnect()
    func didDisconnect()
    func didReceiveFrameData(_ data: Data)
}

struct DiscoveredHost: Identifiable, Hashable {
    let id: String
    let endpoint: NWEndpoint
    let name: String
    let connectionType: String // "Wi-Fi" or "USB / Cable"
}

class DisplayClient: ObservableObject {
    @Published var discoveredHosts = [DiscoveredHost]()
    @Published var isConnected = false
    @Published var statusMessage = "Disconnected"
    
    private var browser: NWBrowser?
    private var connection: NWConnection?
    weak var delegate: DisplayClientDelegate?
    
    private let logger = Logger(subsystem: "com.wifidisplay.client", category: "DisplayClient")
    
    func startBrowsing() {
        let parameters = NWParameters()
        let browser = NWBrowser(for: .bonjour(type: "_wifidisplay._tcp", domain: "local."), using: parameters)
        
        browser.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.logger.info("Bonjour browser is ready")
                DispatchQueue.main.async {
                    self.statusMessage = "Searching for Mac hosts..."
                }
            case .failed(let error):
                self.logger.error("Bonjour browser failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.statusMessage = "Search failed: \(error.localizedDescription)"
                }
            default:
                break
            }
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            let hosts = results.map { result in
                let name: String
                if case .service(let serviceName, _, _, _) = result.endpoint {
                    name = serviceName
                } else {
                    name = String(describing: result.endpoint)
                }
                
                // Determine connection type based on network interface media type
                var connectionType = "Wi-Fi"
                if result.interfaces.contains(where: { $0.type == .wiredEthernet }) {
                    connectionType = "USB / Cable"
                } else if result.interfaces.contains(where: { $0.type == .wifi }) {
                    connectionType = "Wi-Fi"
                } else {
                    connectionType = "Local"
                }
                
                return DiscoveredHost(id: String(describing: result.endpoint), endpoint: result.endpoint, name: name, connectionType: connectionType)
            }
            DispatchQueue.main.async {
                self?.discoveredHosts = hosts
            }
        }
        
        browser.start(queue: DispatchQueue.global(qos: .userInteractive))
        self.browser = browser
    }
    
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }
    
    func connectToHost(ip: String, port: UInt16) {
        if let portVal = NWEndpoint.Port(rawValue: port) {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ip), port: portVal)
            connect(to: endpoint)
        }
    }
    
    func connect(to endpoint: NWEndpoint) {
        disconnect()
        
        let endpointDesc: String
        if case .hostPort(let host, let port) = endpoint {
            endpointDesc = "\(host):\(port)"
        } else {
            endpointDesc = String(describing: endpoint)
        }
        
        DispatchQueue.main.async {
            self.statusMessage = "Connecting to \(endpointDesc)..."
        }
        
        let parameters = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: parameters)
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.logger.info("Connected to host")
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.statusMessage = "Connected to Host"
                }
                self.delegate?.didConnect()
                self.receiveFrameHeader(connection)
            case .failed(let error):
                self.logger.error("Connection failed: \(error.localizedDescription)")
                self.handleDisconnect(message: "Connection failed: \(error.localizedDescription)")
            case .cancelled:
                self.logger.info("Connection cancelled")
                self.handleDisconnect(message: "Disconnected")
            default:
                break
            }
        }
        
        connection.start(queue: DispatchQueue.global(qos: .userInteractive))
        self.connection = connection
    }
    
    func disconnect() {
        connection?.cancel()
        connection = nil
    }
    
    private func handleDisconnect(message: String) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.statusMessage = message
        }
        delegate?.didDisconnect()
    }
    
    // Receive length header: [4 bytes length in big-endian]
    private func receiveFrameHeader(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                self.logger.error("Failed to receive frame header: \(error.localizedDescription)")
                self.disconnect()
                return
            }
            
            if let data = data, data.count == 4 {
                var length: UInt32 = 0
                _ = data.withUnsafeBytes { pointer in
                    memcpy(&length, pointer.baseAddress!, 4)
                }
                length = CFSwapInt32BigToHost(length)
                
                self.logger.info("Received frame header, length: \(length)")
                
                self.receiveFramePayload(connection, length: Int(length))
            } else if isComplete {
                self.logger.info("Host closed connection")
                self.disconnect()
            }
        }
    }
    
    // Receive raw H.264 frame data of specified length
    private func receiveFramePayload(_ connection: NWConnection, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                self.logger.error("Failed to receive frame payload: \(error.localizedDescription)")
                self.disconnect()
                return
            }
            
            if let data = data, data.count == length {
                self.logger.info("Received frame payload, size: \(data.count)")
                self.delegate?.didReceiveFrameData(data)
            }
            
            if isComplete {
                self.logger.info("Host closed connection")
                self.disconnect()
            } else {
                // Receive next frame
                self.receiveFrameHeader(connection)
            }
        }
    }
    
    // Send input packet back to macOS host: [1 byte eventType][4 bytes float x][4 bytes float y] (9 bytes total)
    func sendInputEvent(eventType: UInt8, xRatio: Float, yRatio: Float) {
        guard let connection = connection, isConnected else { return }
        
        var packet = Data()
        packet.append(eventType)
        
        var xSwap = xRatio.bitPattern
        var ySwap = yRatio.bitPattern
        
        xSwap = CFSwapInt32HostToBig(xSwap)
        ySwap = CFSwapInt32HostToBig(ySwap)
        
        withUnsafePointer(to: &xSwap) { pointer in
            packet.append(UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: 4)
        }
        withUnsafePointer(to: &ySwap) { pointer in
            packet.append(UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: 4)
        }
        
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to send input event: \(error.localizedDescription)")
            }
        })
    }
}
