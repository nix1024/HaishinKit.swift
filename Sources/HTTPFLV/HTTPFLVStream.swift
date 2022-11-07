//
//  HTTPFLVStream.swift
//  HaishinKit
//
//  Created by 王昕 on 2022/11/4.
//

import AVFoundation

public protocol HTTPFLVStreamDelegate: AnyObject {
    
    func stream(_ stream: HTTPFLVStream, didOutput data: Data)
    
}

public class HTTPFLVStream {
    
    public weak var delegate: HTTPFLVStreamDelegate? {
        didSet {
            resetStream()
            delegate?.stream(self, didOutput: flvHeader + scriptTag)
        }
    }
    
    public private(set) var isRunning: Atomic<Bool> = .init(false)
    
    private var muxer = HTTPFLVMuxer()
    private var videoIO: AVVideoIOUnit = {
        let videoIO = AVVideoIOUnit()
        videoIO.codec.maxKeyFrameIntervalDuration = 0.2 // GOP 0.2 seconds
        return videoIO
    }()
    private var lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.HTTPFLVStream.lock")
    private var serializer: AMFSerializer = AMF0Serializer()

    private var previousTagSize: UInt32 = 0
    private var firstDecodeTimeStamp: Double?

    public init() {
        muxer.delegate = self
    }
    
    public func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) {
        switch mediaType {
        case .audio:
            break
        case .video:
            videoIO.encodeSampleBuffer(sampleBuffer)
        default:
            break
        }
    }
    
    public var flvHeader: Data {
        return Data([
            0x46,   // F
            0x4C,   // L
            0x56,   // V
            0x01,   // version 1
            0x01,   // video only
            0x00, 0x00, 0x00, 0x09,     // header size
        ])
    }
    
    private var metaData: ASArray {
        return ASArray(data: [
            ["duration" : 0],
            ["width" : videoIO.codec.width],
            ["height" :  videoIO.codec.height],
            ["framerate" : videoIO.fps],
            ["videodatarate" : videoIO.codec.bitrate / 1000],
            ["videocodecid" : FLVVideoCodec.avc.rawValue],
        ])
    }
    
    public var scriptTag: Data {
        let previousTagSizeData = Data([0x00, 0x00, 0x00, 0x00])
        
        serializer.clear()
        serializer.serialize("onMetaData")
        serializer.serialize(metaData)
        let body = serializer.data
        let bodySize = body.count
        
        let header =  Data([
            0x12,   // script data
            UInt8(((bodySize & 0xFF0000) >> 16) % 0xFF),
            UInt8(((bodySize & 0xFF00) >> 8) % 0xFF),
            UInt8(bodySize & 0xFF),
            0x00, 0x00, 0x00,   // timestamp
            0x00,   // timestamp extended
            0x00, 0x00, 0x00,   // stream id
        ])
        
        let tagData = header + body
        previousTagSize = UInt32(tagData.count)
        return previousTagSizeData + tagData
    }

    private func resetStream() {
        previousTagSize = 0
        firstDecodeTimeStamp = nil
    }
}

extension HTTPFLVStream: HTTPFLVMuxerDelegate {
    
    func muxer(_ muxer: HTTPFLVMuxer, didSetMetadata: ASObject) {
        print("muxer didSetMetadata: \(didSetMetadata)")
    }
    
    func muxer(_ muxer: HTTPFLVMuxer, didOutputAudio buffer: Data, withTimestamp: Double) {
        
    }
    
    func muxer(_ muxer: HTTPFLVMuxer, didOutputVideo buffer: Data, withTimestamp: Double) {
        var header = Data([0x09])

        let bodySize = UInt32(buffer.count)
        header.append(bodySize.bigEndian.data[1...3])

        var timestamp: Double = 0
        if let firstDecodeTimeStamp = firstDecodeTimeStamp {
            timestamp = withTimestamp - firstDecodeTimeStamp
        } else {
            firstDecodeTimeStamp = withTimestamp
        }
        let timestampData = UInt32(timestamp).bigEndian.data
        header.append(timestampData[1...3]) // lower 3 bytes for timestamp
        header.append(timestampData[0..<1]) // extended timestamp

        header.append(contentsOf: [0x00, 0x00, 0x00])   // stream id, always 0

        let previousTagSizeData = previousTagSize.bigEndian.data
        let videoTagData = header + buffer
        self.delegate?.stream(self, didOutput: previousTagSizeData + videoTagData)
        
        previousTagSize = UInt32(videoTagData.count)
    }
    
    func muxer(_ muxer: HTTPFLVMuxer, videoCodecErrorOccurred error: VideoCodec.Error) {
        
    }

}

extension HTTPFLVStream: Running {
    public func startRunning() {
        lockQueue.async {
            self.isRunning.mutate { $0 = true }
            self.videoIO.startEncoding(self.muxer)
        }
    }

    public func stopRunning() {
        lockQueue.async {
            self.videoIO.stopEncoding()
        }
    }
}


protocol HTTPFLVMuxerDelegate: AnyObject {
    
    func muxer(_ muxer: HTTPFLVMuxer, didSetMetadata: ASObject)
    
    func muxer(_ muxer: HTTPFLVMuxer, didOutputAudio buffer: Data, withTimestamp: Double)
    
    func muxer(_ muxer: HTTPFLVMuxer, didOutputVideo buffer: Data, withTimestamp: Double)
    
    func muxer(_ muxer: HTTPFLVMuxer, videoCodecErrorOccurred error: VideoCodec.Error)

}

class HTTPFLVMuxer {
    
    weak var delegate: HTTPFLVMuxerDelegate?
    
    private var videoTimeStamp = CMTime.zero
    
    init() {
        
    }
    
    func dispose() {
        videoTimeStamp = CMTime.zero
    }
    
}

extension HTTPFLVMuxer: AVCodecDelegate {
    
    func audioCodec(_ codec: AudioCodec, didSet formatDescription: CMFormatDescription?) {
        
    }
    
    func audioCodec(_ codec: AudioCodec, didOutput sample: UnsafeMutableAudioBufferListPointer, presentationTimeStamp: CMTime) {
        
    }
    
    func videoCodec(_ codec: VideoCodec, didSet formatDescription: CMFormatDescription?) {

    }
    
    func videoCodec(_ codec: VideoCodec, didOutput sampleBuffer: CMSampleBuffer) {
        let keyframe: Bool = !sampleBuffer.isNotSync
        var compositionTime: Int32 = 0  // compositionTime = pts - dts
        let presentationTimeStamp: CMTime = sampleBuffer.presentationTimeStamp  // ts for display
        var decodeTimeStamp: CMTime = sampleBuffer.decodeTimeStamp  // ts for decoding, may smaller than pts for P/B frames
        
        if decodeTimeStamp == CMTime.invalid {
            decodeTimeStamp = presentationTimeStamp
        } else {
            compositionTime = (videoTimeStamp == .zero) ? 0 : Int32((sampleBuffer.presentationTimeStamp.seconds - videoTimeStamp.seconds) * 1000)
        }
        let delta = (videoTimeStamp == CMTime.zero ? 0 : decodeTimeStamp.seconds - videoTimeStamp.seconds) * 1000
        guard let data = sampleBuffer.dataBuffer?.data, 0 <= delta else {
            return
        }
        var buffer = Data([
            ((keyframe ? FLVFrameType.key.rawValue : FLVFrameType.inter.rawValue) << 4) | FLVVideoCodec.avc.rawValue,
            FLVAVCPacketType.nal.rawValue
        ])
        buffer.append(contentsOf: compositionTime.bigEndian.data[1..<4])
        buffer.append(data)
        delegate?.muxer(self, didOutputVideo: buffer, withTimestamp: presentationTimeStamp.seconds * 1000)
        videoTimeStamp = decodeTimeStamp
        
    }
    
    func videoCodec(_ codec: VideoCodec, errorOccurred error: VideoCodec.Error) {
        delegate?.muxer(self, videoCodecErrorOccurred: error)
    }
    
}
