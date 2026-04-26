/// RenderOutputs.swift
/// Describes renderer outputs produced for a frame.
/// Created by Kaden Cringle.

import MetalKit

public struct RenderOutputs {
    public var color: MTLTexture?
    public var depth: MTLTexture?
    public var pickingId: MTLTexture?
    public var sceneColor: MTLTexture?
    public var sceneDepth: MTLTexture?
    public var sceneNormals: MTLTexture?
    public var ssaoNormals: MTLTexture?
    public var sceneColorFogged: MTLTexture?
    public var finalColor: MTLTexture?
    public var sceneColorResolved: MTLTexture?
    public var sceneColorMSAA: MTLTexture?
    public var sceneDepthMSAA: MTLTexture?
    public var ssaoRaw: MTLTexture?
    public var ssaoFiltered: MTLTexture?
    public var ssaoPing: MTLTexture?

    public init(color: MTLTexture? = nil,
                depth: MTLTexture? = nil,
                pickingId: MTLTexture? = nil,
                sceneColor: MTLTexture? = nil,
                sceneDepth: MTLTexture? = nil,
                sceneNormals: MTLTexture? = nil,
                ssaoNormals: MTLTexture? = nil,
                sceneColorFogged: MTLTexture? = nil,
                finalColor: MTLTexture? = nil,
                sceneColorResolved: MTLTexture? = nil,
                sceneColorMSAA: MTLTexture? = nil,
                sceneDepthMSAA: MTLTexture? = nil,
                ssaoRaw: MTLTexture? = nil,
                ssaoFiltered: MTLTexture? = nil,
                ssaoPing: MTLTexture? = nil) {
        self.color = color
        self.depth = depth
        self.pickingId = pickingId
        self.sceneColor = sceneColor ?? sceneColorResolved
        self.sceneDepth = sceneDepth ?? depth
        self.sceneNormals = sceneNormals
        self.ssaoNormals = ssaoNormals
        self.sceneColorFogged = sceneColorFogged
        self.finalColor = finalColor ?? color
        self.sceneColorResolved = sceneColor ?? sceneColorResolved
        self.sceneColorMSAA = sceneColorMSAA
        self.sceneDepthMSAA = sceneDepthMSAA
        self.ssaoRaw = ssaoRaw
        self.ssaoFiltered = ssaoFiltered
        self.ssaoPing = ssaoPing
    }
}
