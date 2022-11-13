//
//  HTTPFLVMuxer.swift
//  HaishinKit
//
//  Created by Nix Wang on 2022/11/8.
//

import AVFoundation

protocol HTTPFLVMuxerDelegate: AnyObject {

    func muxer(_ muxer: HTTPFLVMuxer, didSetMetadata: ASObject)

    func muxer(_ muxer: HTTPFLVMuxer, didOutputAudio buffer: Data, withTimestamp: Double)

    func muxer(_ muxer: HTTPFLVMuxer, didOutputVideoFormatDescription buffer: Data, withTimestamp: Double)
    
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
        guard
            let formatDescription = formatDescription,
            let avcC = AVCConfigurationRecord.getData(formatDescription) else {
            return
        }
        
        print("video codec did set formatDescription")
        
        var buffer = Data([FLVFrameType.key.rawValue << 4 | FLVVideoCodec.avc.rawValue, FLVAVCPacketType.seq.rawValue, 0, 0, 0])
        buffer.append(avcC)
        delegate?.muxer(self, didOutputVideoFormatDescription: buffer, withTimestamp: 0)
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
