//
//  H264.swift
//  Avios
//
//  Created by Josh Baker on 6/29/15.
//  Copyright © 2015 ONcast, LLC. All rights reserved.
//

import Foundation
import AVFoundation
import VideoToolbox


public enum H264Error : Error, CustomStringConvertible {
    case invalidDecoderData
    case invalidDecoderImage
    case invalidNALUType
    case videoSessionNotReady
    case memory
    case cmBlockBufferCreateWithMemoryBlock(OSStatus)
    case cmBlockBufferAppendBufferReference(OSStatus)
    case cmSampleBufferCreateReady(OSStatus)
    case vtDecompressionSessionDecodeFrame(OSStatus)
    case cmVideoFormatDescriptionCreateFromH264ParameterSets(OSStatus)
    case vtDecompressionSessionCreate(OSStatus)
    case invalidCVImageBuffer
    case invalidCVPixelBufferFormat
    public var description : String {
        switch self {
        case .invalidDecoderData: return "H264Error.InvalidDecoderData"
        case .invalidDecoderImage: return "H264Error.InvalidDecoderImage"
        case .invalidNALUType: return "H264Error.InvalidNALUType"
        case .videoSessionNotReady: return "H264Error.VideoSessionNotReady"
        case .memory: return "H264Error.Memory"
        case let .cmBlockBufferCreateWithMemoryBlock(status): return "H264Error.CMBlockBufferCreateWithMemoryBlock(\(status))"
        case let .cmBlockBufferAppendBufferReference(status): return "H264Error.CMBlockBufferAppendBufferReference(\(status))"
        case let .cmSampleBufferCreateReady(status): return "H264Error.CMSampleBufferCreateReady(\(status))"
        case let .vtDecompressionSessionDecodeFrame(status): return "H264Error.VTDecompressionSessionDecodeFrame(\(status))"
        case let .cmVideoFormatDescriptionCreateFromH264ParameterSets(status): return "H264Error.CMVideoFormatDescriptionCreateFromH264ParameterSets(\(status))"
        case let .vtDecompressionSessionCreate(status): return "H264Error.VTDecompressionSessionCreate(\(status))"
        case .invalidCVImageBuffer: return "H264Error.InvalidCVImageBuffer"
        case .invalidCVPixelBufferFormat: return "H264Error.InvalidCVPixelBufferFormat"
        }
    }


}

open class H264Decoder {
    fileprivate var dirtySPS : NALU?
    fileprivate var dirtyPPS : NALU?
    fileprivate var sps : NALU?
    fileprivate var pps : NALU?
    fileprivate var videoSession : VTDecompressionSession!
    fileprivate var formatDescription : CMVideoFormatDescription!
    fileprivate var mutex = pthread_mutex_t()
    fileprivate var cond = pthread_cond_t()
    fileprivate var processing = false
    fileprivate var processingError : Error?
    fileprivate var processingImage : AviosImage?
    fileprivate var buffer : UnsafeMutablePointer<UInt8>? = nil
    fileprivate var bufsize : Int = 0
    public init() throws{
        pthread_mutex_init(&mutex, nil)
        pthread_cond_init(&cond, nil)
        bufsize = 1024 * 16
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity:bufsize)
    }
    deinit{
        invalidateVideo()
        pthread_cond_destroy(&cond)
        pthread_mutex_destroy(&mutex)
        buffer?.deallocate(capacity: bufsize)
    }
    
    open func decode(_ data: UnsafePointer<UInt8>, length: Int) throws -> AviosImage {
        let nalu = NALU(data, length: length)
        if nalu.type == .undefined {
            throw H264Error.invalidNALUType
        }
        if nalu.type == .sps || nalu.type == .pps {
            if nalu.type == .sps {
                dirtySPS = nalu.copy()
            } else if nalu.type == .pps {
                dirtyPPS = nalu.copy()
            }
            if dirtySPS != nil && dirtyPPS != nil {
                if sps == nil || pps == nil || sps!.equals(dirtySPS!) || pps!.equals(dirtyPPS!) {
                    invalidateVideo()
                    sps = dirtySPS!.copy()
                    pps = dirtyPPS!.copy()
                    do {
                        try initVideoSession()
                    } catch {
                        sps = nil
                        pps = nil
                        throw error
                    }
                }
                dirtySPS = nil
                dirtyPPS = nil
            }
            throw AviosError.noImage
        }
        if videoSession == nil {
            throw H264Error.videoSessionNotReady
        }
        if nalu.type == .sei {
            throw AviosError.noImage
        }
        if nalu.type != .idr && nalu.type != .codedSlice {
            throw H264Error.invalidNALUType
        }
        let sampleBuffer = try nalu.sampleBuffer(formatDescription)
        defer {
            CMSampleBufferInvalidate(sampleBuffer)
        }
        
        var infoFlags = VTDecodeInfoFlags(rawValue: 0)
        pthread_mutex_lock(&mutex)
        processing = true
        processingImage = nil
        processingError = nil
        pthread_mutex_unlock(&mutex)
        let status = VTDecompressionSessionDecodeFrame(videoSession, sampleBuffer, [._EnableAsynchronousDecompression], nil, &infoFlags)
        if status != noErr {
            throw H264Error.vtDecompressionSessionDecodeFrame(status)
        }
        
        pthread_mutex_lock(&mutex)
        while processing {
            pthread_cond_wait(&cond, &mutex)
        }
        let error = processingError
        let image = processingImage
        pthread_mutex_unlock(&mutex)
        if error != nil {
            throw error!
        }
        if let image = image {
            return image
        }
        throw AviosError.noImage
    }
    
    fileprivate func decompressionOutputCallback(_ sourceFrameRefCon: UnsafeMutableRawPointer, status: OSStatus, infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, presentationTimeStamp: CMTime, presentationDuration: CMTime){
        pthread_mutex_lock(&mutex)
        defer {
            processing = false
            pthread_cond_broadcast(&cond)
            pthread_mutex_unlock(&mutex)
        }
        if status != noErr {
            processingError = H264Error.vtDecompressionSessionDecodeFrame(status)
            return
        }
        if imageBuffer == nil {
            processingError = H264Error.invalidCVImageBuffer
            return
        }
        let pixelBuffer = unsafeBitCast(Unmanaged.passUnretained(imageBuffer!).toOpaque(), to: CVPixelBuffer.self)
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        }

        if CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_32BGRA {
            processingError = H264Error.invalidCVPixelBufferFormat
            return
        }
        
        let image = AviosImage()
        image.width = CVPixelBufferGetWidth(pixelBuffer)
        image.height = CVPixelBufferGetHeight(pixelBuffer)
        image.stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        if image.stride * image.height > bufsize {
            while image.stride * image.height > bufsize {
                bufsize *= 2
            }
            buffer?.deallocate(capacity: bufsize)
            buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufsize)
        }
        memcpy(buffer, CVPixelBufferGetBaseAddress(pixelBuffer), image.stride * image.height)
        image.rgba = UnsafeBufferPointer<UInt8>(start: buffer, count: image.stride * image.height)
        processingImage = image
    }
    
    fileprivate func invalidateVideo() {
        formatDescription = nil
        if videoSession != nil {
            VTDecompressionSessionInvalidate(videoSession)
            videoSession = nil
        }
        sps = nil
        pps = nil
    }
    fileprivate func initVideoSession() throws {
        formatDescription = nil
        var _formatDescription : CMFormatDescription?
        let parameterSetPointers : [UnsafePointer<UInt8>] = [ pps!.buffer.baseAddress!, sps!.buffer.baseAddress! ]
        let parameterSetSizes : [Int] = [ pps!.buffer.count, sps!.buffer.count ]
        var status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, parameterSetPointers, parameterSetSizes, 4, &_formatDescription);
        if status != noErr {
            throw H264Error.cmVideoFormatDescriptionCreateFromH264ParameterSets(status)
        }
        formatDescription = _formatDescription!

        if videoSession != nil {
            VTDecompressionSessionInvalidate(videoSession)
            videoSession = nil
        }
        var videoSessionM : VTDecompressionSession?

        let decoderParameters = NSMutableDictionary()
        let destinationPixelBufferAttributes = NSMutableDictionary()
        destinationPixelBufferAttributes.setValue(NSNumber(value: kCVPixelFormatType_32BGRA as UInt32), forKey: kCVPixelBufferPixelFormatTypeKey as String)

        var outputCallback = VTDecompressionOutputCallbackRecord()
        outputCallback.decompressionOutputCallback = callback as? VTDecompressionOutputCallback
        outputCallback.decompressionOutputRefCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
       
        status = VTDecompressionSessionCreate(nil, formatDescription, decoderParameters, destinationPixelBufferAttributes, &outputCallback, &videoSessionM)
        if status != noErr {
            throw H264Error.vtDecompressionSessionCreate(status)
        }
        self.videoSession = videoSessionM;
    }
    open func decode(_ data: [UInt8]) throws -> AviosImage {
        return try decode(data, length: data.count)
    }
    open func decode(_ data: UnsafeBufferPointer<UInt8>) throws -> AviosImage {
        return try decode(data.baseAddress!, length: data.count)
    }
    open func decode(_ data: Data) throws -> AviosImage {
        return try decode((data as NSData).bytes.bindMemory(to: UInt8.self, capacity: data.count), length: data.count)
    }
}

private func callback(_ decompressionOutputRefCon: UnsafeMutableRawPointer, sourceFrameRefCon: UnsafeMutableRawPointer, status: OSStatus, infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, presentationTimeStamp: CMTime, presentationDuration: CMTime){
    unsafeBitCast(decompressionOutputRefCon, to: H264Decoder.self).decompressionOutputCallback(sourceFrameRefCon, status: status, infoFlags: infoFlags, imageBuffer: imageBuffer, presentationTimeStamp: presentationTimeStamp, presentationDuration: presentationDuration)
}

