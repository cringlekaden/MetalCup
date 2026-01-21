//
//  DepthStencilStateLibrary.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import MetalKit

enum DepthStencilStateType {
    case Less
}

class DepthStencilStateLibrary {
    
    private static var depthStencilStates: [DepthStencilStateType: DepthStencilState] = [:]
    
    public static func initialize() {
        depthStencilStates[.Less] = LessDepthStencilState()
    }
    
    public static func DepthStencilState(_ depthStencilStateType: DepthStencilStateType)->MTLDepthStencilState {
        return depthStencilStates[depthStencilStateType]!.depthStencilState
    }
}

protocol DepthStencilState {
    var depthStencilState: MTLDepthStencilState! { get }
}

class LessDepthStencilState: DepthStencilState {
    var depthStencilState: MTLDepthStencilState!
    init() {
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = true
        depthStencilDescriptor.depthCompareFunction = .less
        depthStencilState = Engine.Device.makeDepthStencilState(descriptor: depthStencilDescriptor)
    }
}
