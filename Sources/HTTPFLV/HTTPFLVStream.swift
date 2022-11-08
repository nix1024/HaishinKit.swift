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
    
    public weak var delegate: HTTPFLVStreamDelegate?
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
            0x00, 0x00, 0x00, 0x09, // header size
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
        print("reset httpflv stream")
        previousTagSize = 0
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

        let timestampData = UInt32(withTimestamp).bigEndian.data
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
        print("httpflv stream start")

        lockQueue.async {
            self.isRunning.mutate { $0 = true }

            self.videoIO.startEncoding(self.muxer)
            self.resetStream()
            self.delegate?.stream(self, didOutput: self.flvHeader + self.scriptTag)
            self.muxer.videoCodec(self.videoIO.codec, didSet: self.videoIO.codec.formatDescription)
        }
    }

    public func stopRunning() {
        print("httpflv stream stop")

        lockQueue.async {
            self.videoIO.stopEncoding()
            self.resetStream()

            self.isRunning.mutate { $0 = false }
        }
    }
}
