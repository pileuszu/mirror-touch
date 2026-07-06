import Foundation
import Network
import CoreGraphics
import OSLog

protocol DisplayServerDelegate: AnyObject {
    func didConnectClient()
    func didDisconnectClient()
}

class DisplayServer {
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    weak var delegate: DisplayServerDelegate?
    
    private let logger = Logger(subsystem: "com.wifidisplay.host", category: "DisplayServer")
    var virtualDisplayID: CGDirectDisplayID?
    var virtualDisplayWidth: CGFloat = 1920
    var virtualDisplayHeight: CGFloat = 1080
    
    func start(port: UInt16 = 8080) {
        do {
            let parameters = NWParameters.tcp
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            // Advertise via Bonjour
            listener.service = NWListener.Service(name: "\(Host.current().localizedName ?? "MacHost")", type: "_wifidisplay._tcp")
            
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.logger.info("DisplayServer is ready and advertising on port \(port)")
                case .failed(let error):
                    self?.logger.error("DisplayServer failed with error: \(error.localizedDescription)")
                default:
                    break
                }
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            listener.start(queue: DispatchQueue.global(qos: .userInteractive))
            self.listener = listener
            
        } catch {
            logger.error("Failed to start listener: \(error.localizedDescription)")
        }
    }
    
    func stop() {
        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil
        logger.info("DisplayServer stopped")
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        // We only allow one client connected at a time
        activeConnection?.cancel()
        
        activeConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.info("Client connected from \(String(describing: connection.endpoint))")
                self?.delegate?.didConnectClient()
                self?.receiveInput(connection)
            case .failed(let error):
                self?.logger.error("Connection failed: \(error.localizedDescription)")
                self?.handleDisconnect()
            case .cancelled:
                self?.logger.info("Connection cancelled")
                self?.handleDisconnect()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .userInteractive))
    }
    
    private func handleDisconnect() {
        activeConnection = nil
        delegate?.didDisconnectClient()
    }
    
    // Send H.264 stream packet: [4 bytes length][H.264 Annex B payload]
    func sendFrameData(_ data: Data) {
        guard let connection = activeConnection else { return }
        
        var packet = Data()
        var length = UInt32(data.count)
        length = CFSwapInt32HostToBig(length)
        
        withUnsafePointer(to: &length) { pointer in
            packet.append(UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: 4)
        }
        packet.append(data)
        
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to send frame packet: \(error.localizedDescription)")
            }
        })
    }
    
    // Receive input events: [1 byte eventType][4 bytes float x][4 bytes float y] (9 bytes total)
    private func receiveInput(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 9, maximumLength: 9) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                self.logger.error("Receive error: \(error.localizedDescription)")
                return
            }
            
            if let data = data, data.count == 9 {
                let eventType = data[0]
                
                var xRaw: UInt32 = 0
                var yRaw: UInt32 = 0
                
                _ = data.subdata(in: 1..<5).withUnsafeBytes { pointer in
                    memcpy(&xRaw, pointer.baseAddress!, 4)
                }
                _ = data.subdata(in: 5..<9).withUnsafeBytes { pointer in
                    memcpy(&yRaw, pointer.baseAddress!, 4)
                }
                
                xRaw = CFSwapInt32BigToHost(xRaw)
                yRaw = CFSwapInt32BigToHost(yRaw)
                
                var xFloat: Float = 0
                var yFloat: Float = 0
                
                memcpy(&xFloat, &xRaw, 4)
                memcpy(&yFloat, &yRaw, 4)
                
                self.handleClientInput(eventType: eventType, xRatio: CGFloat(xFloat), yRatio: CGFloat(yFloat))
            }
            
            if isComplete {
                self.logger.info("Client closed connection")
                self.handleDisconnect()
            } else {
                self.receiveInput(connection)
            }
        }
    }
    
    // Inject input events back into macOS
    private func handleClientInput(eventType: UInt8, xRatio: CGFloat, yRatio: CGFloat) {
        // Resolve absolute position in our virtual display
        var targetDisplayID = CGMainDisplayID()
        if let vID = virtualDisplayID {
            targetDisplayID = vID
        }
        
        let displayBounds = CGDisplayBounds(targetDisplayID)
        let absoluteX = displayBounds.origin.x + (xRatio * displayBounds.size.width)
        let absoluteY = displayBounds.origin.y + (yRatio * displayBounds.size.height)
        
        let point = CGPoint(x: absoluteX, y: absoluteY)
        var cgType: CGEventType?
        var button: CGMouseButton = .left
        
        switch eventType {
        case 0: // Move
            cgType = .mouseMoved
        case 1: // Left Down
            cgType = .leftMouseDown
            button = .left
        case 2: // Left Up
            cgType = .leftMouseUp
            button = .left
        case 3: // Right Down
            cgType = .rightMouseDown
            button = .right
        case 4: // Right Up
            cgType = .rightMouseUp
            button = .right
        default:
            break
        }
        
        guard let type = cgType else { return }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        
        // Post the event globally
        event.post(tap: .cghidEventTap)
        logger.debug("Injected event \(type.rawValue) at \(point.x), \(point.y)")
    }
}
