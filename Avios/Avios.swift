//
//  Avios.swift
//  Avios
//
//  Created by Josh Baker on 7/5/15.
//  Copyright © 2015 ONcast, LLC. All rights reserved.
//

import Foundation

open class AviosImage {
    open var width: Int = 0
    open var height: Int = 0
    open var stride: Int = 0
    open var yStride: Int = 0
    open var uvStride: Int = 0
    open var rgba : UnsafeBufferPointer<UInt8>
    open var y : UnsafeBufferPointer<UInt8>
    open var u : UnsafeBufferPointer<UInt8>
    open var v : UnsafeBufferPointer<UInt8>
    internal init() {
        rgba = UnsafeBufferPointer<UInt8>(start: UnsafePointer<UInt8>(bitPattern: 0), count: 0)
        y = UnsafeBufferPointer<UInt8>(start: UnsafePointer<UInt8>(bitPattern: 0), count: 0)
        u = UnsafeBufferPointer<UInt8>(start: UnsafePointer<UInt8>(bitPattern: 0), count: 0)
        v = UnsafeBufferPointer<UInt8>(start: UnsafePointer<UInt8>(bitPattern: 0), count: 0)
    }
}

public enum AviosError : Error {
    case noImage
}
