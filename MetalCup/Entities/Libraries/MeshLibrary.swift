//
//  MeshLibrary.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import MetalKit

enum MeshType {
    case TriangleCustom
    case QuadCustom
    case CubeCustom
}

class MeshLibrary: Library<MeshType, Mesh> {
    
    private var _library: [MeshType: Mesh] = [:]
    
    override func fillLibrary() {
        _library[.TriangleCustom] = TriangleCustomMesh()
        _library[.QuadCustom] = QuadCustomMesh()
        _library[.CubeCustom] = CubeCustomMesh()
    }
    
    override subscript(_ type: MeshType)->Mesh {
        return _library[type]!
    }
}

protocol Mesh {
    var vertexCount: Int! { get }
    func setInstanceCount(_ count: Int)
    func drawPrimitives(_ renderCommandEncoder: MTLRenderCommandEncoder)
}

class CustomMesh: Mesh {
    private var _vertices: [Vertex] = []
    private var _vertexBuffer: MTLBuffer!
    private var _instanceCount: Int = 1
    var vertexCount: Int! {
        return _vertices.count
    }
    
    init() {
        createVertices()
        createBuffers()
    }
    
    func createVertices() {}
    
    func createBuffers() {
        _vertexBuffer = Engine.Device.makeBuffer(bytes: _vertices, length: Vertex.stride(vertexCount), options: [])
    }
    
    func addVertex(position: SIMD3<Float>, color: SIMD4<Float> = SIMD4<Float>(1,0,1,1), texCoord: SIMD2<Float> = .zero) {
        _vertices.append(Vertex(position: position, color: color, texCoord: texCoord))
    }
    
    func setInstanceCount(_ count: Int) {
        _instanceCount = count
    }
    
    func drawPrimitives(_ renderCommandEncoder: MTLRenderCommandEncoder) {
        renderCommandEncoder.setVertexBuffer(_vertexBuffer, offset: 0, index: 0)
        renderCommandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: _instanceCount)
    }
}

class TriangleCustomMesh: CustomMesh {
    
    override func createVertices() {
            addVertex(position: SIMD3<Float>(0,1,0), color: SIMD4<Float>(1,0,0,1))
            addVertex(position: SIMD3<Float>(-1,-1,0), color: SIMD4<Float>(0,1,0,1))
            addVertex(position: SIMD3<Float>(1,-1,0), color: SIMD4<Float>(0,0,1,1))
    }
}

class QuadCustomMesh: CustomMesh {
    
    override func createVertices() {
        addVertex(position: SIMD3<Float>(1,1,0), color: SIMD4<Float>(1,0,0,1), texCoord: SIMD2<Float>(1,0))
        addVertex(position: SIMD3<Float>(-1,1,0), color: SIMD4<Float>(0,1,0,1), texCoord: SIMD2<Float>(0,0))
        addVertex(position: SIMD3<Float>(-1,-1,0), color: SIMD4<Float>(0,0,1,1), texCoord: SIMD2<Float>(0,1))
        addVertex(position: SIMD3<Float>(1,1,0), color: SIMD4<Float>(1,0,0,1), texCoord: SIMD2<Float>(1,0))
        addVertex(position: SIMD3<Float>(-1,-1,0), color: SIMD4<Float>(0,0,1,1), texCoord: SIMD2<Float>(0,1))
        addVertex(position: SIMD3<Float>(1,-1,0), color: SIMD4<Float>(1,0,1,1), texCoord: SIMD2<Float>(1,1))
    }
}

class CubeCustomMesh: CustomMesh {
    override func createVertices() {
            addVertex(position: SIMD3<Float>(-1.0,-1.0,-1.0), color: SIMD4<Float>(1.0, 0.5, 0.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0,-1.0, 1.0), color: SIMD4<Float>(0.0, 1.0, 0.5, 1.0))
            addVertex(position: SIMD3<Float>(-1.0, 1.0, 1.0), color: SIMD4<Float>(0.0, 0.5, 1.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0,-1.0,-1.0), color: SIMD4<Float>(1.0, 1.0, 0.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0, 1.0, 1.0), color: SIMD4<Float>(0.0, 1.0, 1.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0, 1.0,-1.0), color: SIMD4<Float>(1.0, 0.0, 1.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0, 1.0, 1.0), color: SIMD4<Float>(1.0, 0.0, 0.5, 1.0))
            addVertex(position: SIMD3<Float>( 1.0,-1.0,-1.0), color: SIMD4<Float>(0.0, 1.0, 0.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0, 1.0,-1.0), color: SIMD4<Float>(0.0, 0.5, 1.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0,-1.0,-1.0), color: SIMD4<Float>(1.0, 1.0, 0.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0, 1.0, 1.0), color: SIMD4<Float>(0.0, 1.0, 1.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0,-1.0, 1.0), color: SIMD4<Float>(1.0, 0.5, 1.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0, 1.0, 1.0), color: SIMD4<Float>(1.0, 0.0, 0.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0, 1.0,-1.0), color: SIMD4<Float>(0.0, 1.0, 0.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0, 1.0,-1.0), color: SIMD4<Float>(0.0, 0.0, 1.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0, 1.0, 1.0), color: SIMD4<Float>(1.0, 1.0, 0.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0, 1.0,-1.0), color: SIMD4<Float>(0.5, 1.0, 1.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0, 1.0, 1.0), color: SIMD4<Float>(1.0, 0.0, 1.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0,-1.0, 1.0), color: SIMD4<Float>(1.0, 0.5, 0.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0,-1.0,-1.0), color: SIMD4<Float>(0.5, 1.0, 0.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0,-1.0,-1.0), color: SIMD4<Float>(0.0, 0.0, 1.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0,-1.0, 1.0), color: SIMD4<Float>(1.0, 1.0, 0.5, 1.0))
            addVertex(position: SIMD3<Float>(-1.0,-1.0, 1.0), color: SIMD4<Float>(0.0, 1.0, 1.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0,-1.0,-1.0), color: SIMD4<Float>(1.0, 0.5, 1.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0, 1.0,-1.0), color: SIMD4<Float>(1.0, 0.5, 0.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0,-1.0,-1.0), color: SIMD4<Float>(0.5, 1.0, 0.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0, 1.0,-1.0), color: SIMD4<Float>(0.0, 0.0, 1.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0, 1.0,-1.0), color: SIMD4<Float>(1.0, 1.0, 0.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0,-1.0,-1.0), color: SIMD4<Float>(0.0, 1.0, 1.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0,-1.0,-1.0), color: SIMD4<Float>(1.0, 0.5, 1.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0, 1.0, 1.0), color: SIMD4<Float>(1.0, 0.5, 0.0, 1.0))
            addVertex(position: SIMD3<Float>(-1.0,-1.0, 1.0), color: SIMD4<Float>(0.0, 1.0, 0.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0,-1.0, 1.0), color: SIMD4<Float>(0.5, 0.0, 1.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0, 1.0, 1.0), color: SIMD4<Float>(1.0, 1.0, 0.5, 1.0))
            addVertex(position: SIMD3<Float>(-1.0, 1.0, 1.0), color: SIMD4<Float>(0.0, 1.0, 1.0, 1.0))
            addVertex(position: SIMD3<Float>( 1.0,-1.0, 1.0), color: SIMD4<Float>(1.0, 0.0, 1.0, 1.0))
    }
}
