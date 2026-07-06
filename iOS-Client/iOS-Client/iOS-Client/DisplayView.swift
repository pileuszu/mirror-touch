import SwiftUI
import AVFoundation

class VideoPreviewView: UIView {
    private let displayLayer: AVSampleBufferDisplayLayer
    
    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        self.backgroundColor = .black
        displayLayer.videoGravity = .resize
        self.layer.addSublayer(displayLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = self.bounds
        displayLayer.contentsScale = self.traitCollection.displayScale
    }
}

struct StreamPlayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    
    func makeUIView(context: Context) -> VideoPreviewView {
        return VideoPreviewView(displayLayer: layer)
    }
    
    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
    }
}

struct DisplayView: View {
    @ObservedObject var client: DisplayClient
    let displayLayer: AVSampleBufferDisplayLayer
    let videoSize: CGSize
    
    @State private var isTouchActive = false
    
    // Safety letterbox margins to avoid iPhone 13 notch and rounded corners
    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 8
    
    var body: some View {
        GeometryReader { geometry in
            // Calculate available canvas size inside the safe padding
            let canvasWidth = geometry.size.width - (horizontalPadding * 2)
            let canvasHeight = geometry.size.height - (verticalPadding * 2)
            
            // Calculate the actual size of the video screen fitted inside the canvas preserving aspect ratio
            let videoAspect = videoSize.width / videoSize.height
            let canvasAspect = canvasWidth / canvasHeight
            
            let fitWidth = videoAspect > canvasAspect ? canvasWidth : (canvasHeight * videoAspect)
            let fitHeight = videoAspect > canvasAspect ? (canvasWidth / videoAspect) : canvasHeight
            
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all) // Black letterbox background
                
                StreamPlayerView(layer: displayLayer)
                    .frame(width: fitWidth, height: fitHeight)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                // Touch location is already relative to StreamPlayerView frame
                                let xRatio = Float(value.location.x / fitWidth)
                                let yRatio = Float(value.location.y / fitHeight)
                                let clampedX = max(0, min(1, xRatio))
                                let clampedY = max(0, min(1, yRatio))
                                
                                if !isTouchActive {
                                    isTouchActive = true
                                    // Touch Down
                                    client.sendInputEvent(eventType: 1, xRatio: clampedX, yRatio: clampedY)
                                } else {
                                    // Touch Move
                                    client.sendInputEvent(eventType: 0, xRatio: clampedX, yRatio: clampedY)
                                }
                            }
                            .onEnded { value in
                                let xRatio = Float(value.location.x / fitWidth)
                                let yRatio = Float(value.location.y / fitHeight)
                                let clampedX = max(0, min(1, xRatio))
                                let clampedY = max(0, min(1, yRatio))
                                
                                isTouchActive = false
                                // Touch Up
                                client.sendInputEvent(eventType: 2, xRatio: clampedX, yRatio: clampedY)
                            }
                    )
            }
        }
        .edgesIgnoringSafeArea(.all)
    }
}
