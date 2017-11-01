//
//  NALU.swift
//  Avios
//
//  Created by Josh Baker on 6/29/15.
//  Copyright © 2015 ONcast, LLC. All rights reserved.
//

import CoreMedia

public enum NALUType : UInt8, CustomStringConvertible {
    case undefined = 0
    case codedSlice = 1
    case dataPartitionA = 2
    case dataPartitionB = 3
    case dataPartitionC = 4
    case idr = 5 // (Instantaneous Decoding Refresh) Picture
    case sei = 6 // (Supplemental Enhancement Information)
    case sps = 7 // (Sequence Parameter Set)
    case pps = 8 // (Picture Parameter Set)
    case accessUnitDelimiter = 9
    case endOfSequence = 10
    case endOfStream = 11
    case filterData = 12
    // 13-23 [extended]
    // 24-31 [unspecified]
    
    public var description : String {
        switch self {
        case .codedSlice: return "CodedSlice"
        case .dataPartitionA: return "DataPartitionA"
        case .dataPartitionB: return "DataPartitionB"
        case .dataPartitionC: return "DataPartitionC"
        case .idr: return "IDR"
        case .sei: return "SEI"
        case .sps: return "SPS"
        case .pps: return "PPS"
        case .accessUnitDelimiter: return "AccessUnitDelimiter"
        case .endOfSequence: return "EndOfSequence"
        case .endOfStream: return "EndOfStream"
        case .filterData: return "FilterData"
        default: return "Undefined"
        }
    }
}

open class NALU {
    fileprivate var bbuffer : CMBlockBuffer!
    fileprivate var bbdata : UnsafeMutablePointer<UInt8>? = nil
    fileprivate var bblen  = [UInt8](repeating: 0, count: 8)

    fileprivate var copied = false
    open let buffer : UnsafeBufferPointer<UInt8>
    open let type : NALUType
    open let priority : Int
    public init(_ buffer: UnsafeBufferPointer<UInt8>) {
        var type : NALUType?
        var priority : Int?
        self.buffer = buffer
        if buffer.count > 0 {
            let hb = buffer[0]
            if (((hb >> 7) & 0x01) == 0){ // zerobit
                type = NALUType(rawValue: (hb >> 0) & 0x1F) // type
                priority = Int((hb >> 5) & 0x03) // priority
            }
        }
        self.type = type == nil ? .undefined : type!
        self.priority = priority == nil ? 0 : priority!
    }
    deinit {
        if copied {
            free(UnsafeMutablePointer<UInt8>(mutating: buffer.baseAddress))
        }
        if bbdata != nil {
            free(bbdata)
        }
    }
    public convenience init(){
        self.init(UnsafeBufferPointer<UInt8>(start: UnsafePointer<UInt8>(bitPattern: 0), count: 0))
    }
    public convenience init(_ bytes: UnsafePointer<UInt8>, length: Int) {
        self.init(UnsafeBufferPointer<UInt8>(start: bytes, count: length))
    }
    open var naluTypeName : String {
        return type.description
    }
    open func copy() -> NALU {
        let baseAddress = UnsafeMutablePointer<UInt8>.allocate(capacity: buffer.count)
        memcpy(baseAddress, buffer.baseAddress, buffer.count)
        let nalu = NALU(baseAddress, length: buffer.count)
        nalu.copied = true
        return nalu
    }
    open func equals(_ nalu: NALU) -> Bool {
        if nalu.buffer.count != buffer.count {
            return false
        }
        return memcmp(nalu.buffer.baseAddress, buffer.baseAddress, buffer.count) == 0
    }
    open var nsdata : Data {
        return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: buffer.baseAddress!) , count: buffer.count, deallocator: .none)    }
    
    // returns a non-contiguous CMBlockBuffer.
    open func blockBuffer() throws -> CMBlockBuffer {
        if bbuffer != nil {
            return bbuffer
        }

        var biglen = CFSwapInt32HostToBig(UInt32(buffer.count))
        memcpy(&bblen, &biglen, 4)
        var _buffer : CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(nil, &bblen, 4, kCFAllocatorNull, nil, 0, 4, 0, &_buffer)
        if status != noErr {
            throw H264Error.cmBlockBufferCreateWithMemoryBlock(status)
        }
        var bufferData : CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(nil, UnsafeMutablePointer<UInt8>(mutating: buffer.baseAddress), buffer.count, kCFAllocatorNull, nil, 0, buffer.count, 0, &bufferData)
        if status != noErr {
            throw H264Error.cmBlockBufferCreateWithMemoryBlock(status)
        }

        status = CMBlockBufferAppendBufferReference(_buffer!, bufferData!, 0, buffer.count, 0)
        if status != noErr {
            throw H264Error.cmBlockBufferAppendBufferReference(status)
        }
        bbuffer = _buffer
        
        return bbuffer
    }
    
    open func sampleBuffer(_ fd : CMVideoFormatDescription) throws -> CMSampleBuffer {
        var sampleBuffer : CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo()
        timingInfo.decodeTimeStamp = kCMTimeInvalid
        timingInfo.presentationTimeStamp = kCMTimeZero // pts
        timingInfo.duration = kCMTimeInvalid
        let status = CMSampleBufferCreateReady(kCFAllocatorDefault, try blockBuffer(), fd, 1, 1, &timingInfo, 0, nil, &sampleBuffer)
        if status != noErr {
            throw H264Error.cmSampleBufferCreateReady(status)
        }
        return sampleBuffer!
    }
}
