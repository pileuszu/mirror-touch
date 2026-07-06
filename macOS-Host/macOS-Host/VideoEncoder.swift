import Foundation
import VideoToolbox
import CoreMedia
import OSLog

protocol VideoEncoderDelegate: AnyObject {
    func didEncodeFrame(data: Data, isKeyFrame: Bool)
}

class VideoEncoder {
    private var session: VTCompressionSession?
    weak var delegate: VideoEncoderDelegate?
    private let logger = Logger(subsystem: "com.wifidisplay.host", category: "VideoEncoder")
    
    deinit {
        stopSession()
    }
    
    func startSession(width: Int32, height: Int32) {
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        
        var compressionSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: { (outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer) in
                guard status == noErr, let sampleBuffer = sampleBuffer else { return }
                let encoder = Unmanaged<VideoEncoder>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
                encoder.handleEncodedFrame(sampleBuffer)
            },
            refcon: refCon,
            compressionSessionOut: &compressionSession
        )
        
        guard status == noErr, let session = compressionSession else {
            logger.error("Failed to create VTCompressionSession: \(status)")
            return
        }
        
        self.session = session
        
        // Configure low-latency properties
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber) // Keyframe every 30 frames (0.5s at 60fps)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) // Disable B-frames for zero latency
        
        // Target bit rate of 15 Mbps for crystal clear retina streaming over local Wi-Fi
        let bitRate = 15_000_000 as CFNumber
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate)
        
        // Clean up session initialization
        VTCompressionSessionPrepareToEncodeFrames(session)
        logger.info("VTCompressionSession successfully initialized for resolution: \(width)x\(height)")
    }
    
    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session = session else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        
        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        
        if status != noErr {
            logger.error("Failed to encode frame: \(status)")
        }
    }
    
    func stopSession() {
        guard let session = session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
        logger.info("VTCompressionSession stopped")
    }
    
    // Convert AVCC to Annex B and extract SPS/PPS for keyframes
    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        
        // Check if this is a keyframe
        var isKeyFrame = false
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [CFDictionary],
           let attachments = attachmentsArray.first {
            let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            if let notSync = CFDictionaryGetValue(attachments, key) {
                let notSyncBool = Unmanaged<CFBoolean>.fromOpaque(notSync).takeUnretainedValue()
                isKeyFrame = !CFBooleanGetValue(notSyncBool)
            } else {
                isKeyFrame = true
            }
        }
        
        var dataStream = Data()
        
        // For keyframes, prepend SPS and PPS
        if isKeyFrame {
            var parameterSetCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
            
            for i in 0..<parameterSetCount {
                var parameterSetPointer: UnsafePointer<UInt8>?
                var parameterSetSize = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: i,
                    parameterSetPointerOut: &parameterSetPointer,
                    parameterSetSizeOut: &parameterSetSize,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                
                if let pointer = parameterSetPointer {
                    let startCode = Data([0x00, 0x00, 0x00, 0x01])
                    dataStream.append(startCode)
                    dataStream.append(pointer, count: parameterSetSize)
                }
            }
        }
        
        // Extract the main H.264 data (AVCC format) and convert to Annex B
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        
        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else { return }
        
        var bufferOffset = 0
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        
        while bufferOffset < totalLength - 4 {
            // Read NAL unit length (4 bytes big-endian)
            let rawLengthPointer = pointer.advanced(by: bufferOffset)
            var nalUnitLength: UInt32 = 0
            memcpy(&nalUnitLength, rawLengthPointer, 4)
            nalUnitLength = CFSwapInt32BigToHost(nalUnitLength)
            
            // Append start code and NAL unit body
            dataStream.append(startCode)
            let rawDataPointer = UnsafeRawPointer(rawLengthPointer.advanced(by: 4))
            dataStream.append(rawDataPointer.assumingMemoryBound(to: UInt8.self), count: Int(nalUnitLength))
            
            bufferOffset += 4 + Int(nalUnitLength)
        }
        
        delegate?.didEncodeFrame(data: dataStream, isKeyFrame: isKeyFrame)
    }
}
