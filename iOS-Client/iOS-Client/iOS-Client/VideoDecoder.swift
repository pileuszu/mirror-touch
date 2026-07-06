import Foundation
import CoreMedia
import VideoToolbox
import OSLog

protocol VideoDecoderDelegate: AnyObject {
    func didDecodeFrame(sampleBuffer: CMSampleBuffer)
    func didUpdateDimensions(_ dimensions: CGSize)
}

class VideoDecoder {
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    
    weak var delegate: VideoDecoderDelegate?
    private let logger = Logger(subsystem: "com.wifidisplay.client", category: "VideoDecoder")
    private var frameCount: Int64 = 0
    
    func parseFrameData(_ data: Data) {
        let nalUnits = splitAnnexB(data)
        var slices = [Data]()
        
        for nal in nalUnits {
            guard nal.count > 0 else { continue }
            let nalType = nal[0] & 0x1F
            
            if nalType == 7 { // SPS
                sps = nal
                updateFormatDescription()
            } else if nalType == 8 { // PPS
                pps = nal
                updateFormatDescription()
            } else if nalType == 5 || nalType == 1 { // IDR or Non-IDR Slice
                slices.append(nal)
            }
        }
        
        if !slices.isEmpty, let formatDesc = formatDescription {
            createSampleBuffer(slices: slices, formatDescription: formatDesc)
        }
    }
    
    private func splitAnnexB(_ data: Data) -> [Data] {
        var nalUnits = [Data]()
        var lastOffset = 0
        let count = data.count
        
        var i = 0
        while i < count - 4 {
            if data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1 {
                if i > lastOffset {
                    nalUnits.append(data.subdata(in: lastOffset..<i))
                }
                lastOffset = i + 4
                i += 3
            } else if data[i] == 0 && data[i+1] == 0 && data[i+2] == 1 {
                if i > lastOffset {
                    nalUnits.append(data.subdata(in: lastOffset..<i))
                }
                lastOffset = i + 3
                i += 2
            }
            i += 1
        }
        
        if lastOffset < count {
            nalUnits.append(data.subdata(in: lastOffset..<count))
        }
        
        return nalUnits
    }
    
    private func updateFormatDescription() {
        guard let sps = sps, let pps = pps else { return }
        
        sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let spsPointer = spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let ppsPointer = ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                
                let parameterSetPointers = [spsPointer, ppsPointer]
                let parameterSetSizes = [sps.count, pps.count]
                
                var formatDesc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                
                if status == noErr {
                    self.formatDescription = formatDesc
                    if let desc = formatDesc {
                        let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(desc, usePixelAspectRatio: true, useCleanAperture: true)
                        self.delegate?.didUpdateDimensions(dimensions)
                    }
                } else {
                    self.logger.error("Failed to create CMVideoFormatDescription: \(status)")
                }
            }
        }
    }
    
    private func createSampleBuffer(slices: [Data], formatDescription: CMVideoFormatDescription) {
        let totalSize = slices.reduce(0) { $0 + 4 + $1.count }
        
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == kCMBlockBufferNoErr, let buffer = blockBuffer else {
            logger.error("Failed to create CMBlockBuffer: \(status)")
            return
        }
        
        var offset = 0
        for slice in slices {
            var length = UInt32(slice.count)
            length = CFSwapInt32HostToBig(length)
            
            withUnsafePointer(to: &length) { lengthPointer in
                _ = CMBlockBufferReplaceDataBytes(
                    with: lengthPointer,
                    blockBuffer: buffer,
                    offsetIntoDestination: offset,
                    dataLength: 4
                )
            }
            
            slice.withUnsafeBytes { sliceBytes in
                _ = CMBlockBufferReplaceDataBytes(
                    with: sliceBytes.baseAddress!,
                    blockBuffer: buffer,
                    offsetIntoDestination: offset + 4,
                    dataLength: slice.count
                )
            }
            
            offset += 4 + slice.count
        }
        
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = totalSize
        
        frameCount += 1
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: frameCount, timescale: 60),
            decodeTimeStamp: CMTime.invalid
        )
        
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        
        if status == noErr, let sBuffer = sampleBuffer {
            if let attachments: CFArray = CMSampleBufferGetSampleAttachmentsArray(sBuffer, createIfNecessary: true) {
                if CFArrayGetCount(attachments) > 0 {
                    let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                    let key = kCMSampleAttachmentKey_DisplayImmediately
                    CFDictionarySetValue(dict, 
                                         Unmanaged.passUnretained(key).toOpaque(), 
                                         Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                }
            }
            delegate?.didDecodeFrame(sampleBuffer: sBuffer)
        } else {
            logger.error("Failed to create CMSampleBuffer: \(status)")
        }
    }
    
    func reset() {
        sps = nil
        pps = nil
        formatDescription = nil
        frameCount = 0
        logger.info("VideoDecoder state reset")
    }
}
