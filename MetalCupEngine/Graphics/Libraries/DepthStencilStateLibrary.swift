/// DepthStencilStateLibrary.swift
/// Defines the DepthStencilStateLibrary types and helpers for the engine.
/// Created by Kaden Cringle.

import MetalKit

public enum DepthStencilStateType {
    case Less
    case LessEqual
    case LessNoWrite
    case LessEqualNoWrite
    case EqualNoWrite
    case AlwaysNoWrite
}

public class DepthStencilStateLibrary: Library<DepthStencilStateType, MTLDepthStencilState> {
    private var _library: [DepthStencilStateType: DepthStencilState] = [:]
    private let device: MTLDevice

    public init(device: MTLDevice) {
        self.device = device
        super.init()
    }

    override func fillLibrary() {
        _library[.Less] = LessDepthStencilState(device: device)
        _library[.LessEqual] = LessEqualDepthStencilState(device: device)
        _library[.LessNoWrite] = LessNoWriteDepthStencilState(device: device)
        _library[.LessEqualNoWrite] = LessEqualNoWriteDepthStencilState(device: device)
        _library[.EqualNoWrite] = EqualNoWriteDepthStencilState(device: device)
        _library[.AlwaysNoWrite] = AlwaysNoWriteDepthStencilState(device: device)
    }

    override subscript(_ type: DepthStencilStateType)->MTLDepthStencilState {
        return _library[type]!.depthStencilState
    }
}

protocol DepthStencilState {
    var depthStencilState: MTLDepthStencilState! { get }
}

class LessDepthStencilState: DepthStencilState {
    var depthStencilState: MTLDepthStencilState!
    init(device: MTLDevice) {
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = true
        depthStencilDescriptor.depthCompareFunction = .less
        depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)
    }
}

class LessEqualDepthStencilState: DepthStencilState {
    var depthStencilState: MTLDepthStencilState!
    init(device: MTLDevice) {
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = true
        depthStencilDescriptor.depthCompareFunction = .lessEqual
        depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)
    }
}

class LessEqualNoWriteDepthStencilState: DepthStencilState {
    var depthStencilState: MTLDepthStencilState!
    init(device: MTLDevice) {
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = false
        depthStencilDescriptor.depthCompareFunction = .lessEqual
        depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)
    }
}

class LessNoWriteDepthStencilState: DepthStencilState {
    var depthStencilState: MTLDepthStencilState!
    init(device: MTLDevice) {
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = false
        depthStencilDescriptor.depthCompareFunction = .less
        depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)
    }
}

class EqualNoWriteDepthStencilState: DepthStencilState {
    var depthStencilState: MTLDepthStencilState!
    init(device: MTLDevice) {
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = false
        depthStencilDescriptor.depthCompareFunction = .equal
        depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)
    }
}

class AlwaysNoWriteDepthStencilState: DepthStencilState {
    var depthStencilState: MTLDepthStencilState!
    init(device: MTLDevice) {
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = false
        depthStencilDescriptor.depthCompareFunction = .always
        depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)
    }
}
