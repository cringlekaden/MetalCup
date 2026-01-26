import MetalKit

enum MeshType {
    case None
    case Triangle
    case Quad
    case Cube
    case Cruiser
    case Sphere
    case Skysphere
    case Chest
    case Well
    case Terrain
    case Tree1
    case Tree2
    case Tree3
    case Flower1
    case Flower2
    case Flower3
    case Tent
}

class MeshLibrary: Library<MeshType, Mesh> {
    
    private var _library: [MeshType: Mesh] = [:]
    
    override func fillLibrary() {
        _library[.None] = NoMesh()
        _library[.Triangle] = TriangleMesh()
        _library[.Quad] = Mesh(modelName: "quad")
        _library[.Cube] = CubeMesh()
        _library[.Cruiser] = Mesh(modelName: "cruiser")
        _library[.Sphere] = Mesh(modelName: "sphere")
        _library[.Skysphere] = Mesh(modelName: "skysphere")
        _library[.Chest] = Mesh(modelName: "chest")
        _library[.Well] = Mesh(modelName: "well")
        _library[.Terrain] = Mesh(modelName: "ground_grass")
        _library[.Tree1] = Mesh(modelName: "tree_pineTallA_detailed")
        _library[.Tree2] = Mesh(modelName: "tree_pineDefaultB")
        _library[.Tree3] = Mesh(modelName: "tree_pineRoundC")
        _library[.Flower1] = Mesh(modelName: "flower_purpleA")
        _library[.Flower2] = Mesh(modelName: "flower_redA")
        _library[.Flower3] = Mesh(modelName: "flower_yellowA")
        _library[.Tent] = Mesh(modelName: "tent_smallOpen")
    }
    
    override subscript(_ type: MeshType)->Mesh {
        return _library[type]!
    }
}

class Mesh {
    
    private var _vertices: [Vertex] = []
    private var _vertexCount: Int = 0
    private var _vertexBuffer: MTLBuffer! = nil
    private var _instanceCount: Int = 1
    private var _submeshes: [Submesh] = []
    
    init() {
        createMesh()
        createBuffer()
    }
    
    init(modelName: String) {
        createMeshFromModel(modelName)
    }
    
    func createMesh() {}
    
    private func createBuffer() {
        if(_vertices.count > 0){
            _vertexBuffer = Engine.Device.makeBuffer(bytes: _vertices, length: Vertex.stride(_vertices.count), options: [])
        }
    }
    
    private func createMeshFromModel(_ modelName: String, ext: String = "obj") {
        guard let assetURL = Bundle.main.url(forResource: modelName, withExtension: ext) else {
            fatalError("Asset \(modelName) does not exist...")
        }
        let descriptor = MTKModelIOVertexDescriptorFromMetal(Graphics.VertexDescriptors[.Basic])
        (descriptor.attributes[0] as! MDLVertexAttribute).name = MDLVertexAttributePosition
        (descriptor.attributes[1] as! MDLVertexAttribute).name = MDLVertexAttributeColor
        (descriptor.attributes[2] as! MDLVertexAttribute).name = MDLVertexAttributeTextureCoordinate
        (descriptor.attributes[3] as! MDLVertexAttribute).name = MDLVertexAttributeNormal
        (descriptor.attributes[4] as! MDLVertexAttribute).name = MDLVertexAttributeTangent
        (descriptor.attributes[5] as! MDLVertexAttribute).name = MDLVertexAttributeBitangent
        let bufferAllocator = MTKMeshBufferAllocator(device: Engine.Device)
        let asset: MDLAsset = MDLAsset(url: assetURL, vertexDescriptor: descriptor, bufferAllocator: bufferAllocator, preserveTopology: true, error: nil)
        asset.loadTextures()
        var mtkMeshes: [MTKMesh] = []
        var mdlMeshes: [MDLMesh] = []
        do{
            mdlMeshes = try MTKMesh.newMeshes(asset: asset, device: Engine.Device).modelIOMeshes
        } catch {
            print("ERROR::LOADING_MESH::__\(modelName)__::\(error)")
        }
        for mdlMesh in mdlMeshes {
            mdlMesh.addTangentBasis(forTextureCoordinateAttributeNamed: MDLVertexAttributeTextureCoordinate, tangentAttributeNamed: MDLVertexAttributeTangent, bitangentAttributeNamed: MDLVertexAttributeBitangent)
            mdlMesh.vertexDescriptor = descriptor
            do {
                let mtkMesh = try MTKMesh(mesh: mdlMesh, device: Engine.Device)
                mtkMeshes.append(mtkMesh)
            } catch {
                print("ERROR::LOADING_MESH::__\(modelName)__::\(error)")
            }
        }
        let mtkMesh = mtkMeshes[0]
        let mdlMesh = mdlMeshes[0]
        self._vertexBuffer = mtkMesh.vertexBuffers[0].buffer
        self._vertexCount = mtkMesh.vertexCount
        for i in 0..<mtkMesh.submeshes.count {
            let mtkSubmesh = mtkMesh.submeshes[i]
            let mdlSubmesh = mdlMesh.submeshes![i] as! MDLSubmesh
            let submesh = Submesh(mtkSubmesh: mtkSubmesh, mdlSubmesh: mdlSubmesh)
            addSubmesh(submesh)
        }
    }
    
    func setInstanceCount(_ count: Int) {
        self._instanceCount = count
    }
    
    func addSubmesh(_ submesh: Submesh) {
        _submeshes.append(submesh)
    }
    
    func addVertex(position: SIMD3<Float>, color: SIMD4<Float> = SIMD4<Float>(1,0,1,1), texCoord: SIMD2<Float> = SIMD2<Float>(0,0), normal: SIMD3<Float> = SIMD3<Float>(0,1,0), tangent: SIMD3<Float> = SIMD3<Float>(1,0,0), bitangent: SIMD3<Float> = SIMD3<Float>(0,0,1)) {
        _vertices.append(Vertex(position: position, color: color, texCoord: texCoord, normal: normal, tangent: tangent, bitangent: bitangent))
    }
    
    func drawPrimitives(_ renderCommandEncoder: MTLRenderCommandEncoder, material: Material? = nil, diffuseMapTextureType: TextureType = .None, normalMapTextureType: TextureType = .None) {
        if(_vertexBuffer != nil) {
            renderCommandEncoder.setVertexBuffer(_vertexBuffer, offset: 0, index: 0)
            if(_submeshes.count > 0) {
                for submesh in _submeshes {
                    submesh.applyTextures(renderCommandEncoder: renderCommandEncoder, diffuseMapTextureType: diffuseMapTextureType, normalMapTextureType: normalMapTextureType)
                    submesh.applyMaterials(renderCommandEncoder: renderCommandEncoder, customMaterial: material)
                    renderCommandEncoder.drawIndexedPrimitives(type: submesh.primitiveType, indexCount: submesh.indexCount, indexType: submesh.indexType, indexBuffer: submesh.indexBuffer, indexBufferOffset: submesh.indexBufferOffset, instanceCount: _instanceCount)
                }
            } else {
                renderCommandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: _vertices.count, instanceCount: _instanceCount)
            }
        }
    }
}

class Submesh {
    
    private var _indices: [UInt32] = []
    private var _indexCount: Int = 0
    public var indexCount: Int { return _indexCount }
    
    private var _indexBuffer: MTLBuffer!
    public var indexBuffer: MTLBuffer { return _indexBuffer }

    private var _primitiveType: MTLPrimitiveType = .triangle
    public var primitiveType: MTLPrimitiveType { return _primitiveType }
    
    private var _indexType: MTLIndexType = .uint32
    public var indexType: MTLIndexType { return _indexType }
    
    private var _indexBufferOffset: Int = 0
    public var indexBufferOffset: Int { return _indexBufferOffset }
    
    private var _material = Material()
    private var _diffuseMapTexture: MTLTexture!
    private var _normalMapTexture: MTLTexture!
    
    init(indices: [UInt32]) {
        self._indices = indices
        self._indexCount = indices.count
        createIndexBuffer()
    }
    
    init(mtkSubmesh: MTKSubmesh, mdlSubmesh: MDLSubmesh) {
        _indexBuffer = mtkSubmesh.indexBuffer.buffer
        _indexBufferOffset = mtkSubmesh.indexBuffer.offset
        _indexCount = mtkSubmesh.indexCount
        _indexType = mtkSubmesh.indexType
        _primitiveType = mtkSubmesh.primitiveType
        createTexture(mdlSubmesh.material!)
        createMaterial(mdlSubmesh.material!)
    }
    
    func applyTextures(renderCommandEncoder: MTLRenderCommandEncoder, diffuseMapTextureType: TextureType, normalMapTextureType: TextureType) {
        renderCommandEncoder.setFragmentSamplerState(Graphics.SamplerStates[.Linear], index: 0)
        let diffuseMapTexture = diffuseMapTextureType == .None ? _diffuseMapTexture : Assets.Textures[diffuseMapTextureType]
        renderCommandEncoder.setFragmentTexture(diffuseMapTexture, index: 0)
        let normalMapTexture = normalMapTextureType == .None ? _normalMapTexture : Assets.Textures[normalMapTextureType]
        renderCommandEncoder.setFragmentTexture(normalMapTexture, index: 1)
    }
    
    func applyMaterials(renderCommandEncoder: MTLRenderCommandEncoder, customMaterial: Material?) {
        var material = customMaterial == nil ? _material : customMaterial
        renderCommandEncoder.setFragmentBytes(&material, length: Material.stride, index: 1)
    }
    
    private func createTexture(_ mdlMaterial: MDLMaterial) {
        _diffuseMapTexture = texture(for: .baseColor, in: mdlMaterial, textureOrigin: .bottomLeft)
        _normalMapTexture = texture(for: .tangentSpaceNormal, in: mdlMaterial, textureOrigin: .bottomLeft)
    }
    
    private func createMaterial(_ mdlMaterial: MDLMaterial) {
        if let ambient = mdlMaterial.property(with: .emission)?.float3Value {
            _material.ambient = ambient
        }
        if let diffuse = mdlMaterial.property(with: .baseColor)?.float3Value {
            _material.diffuse = diffuse
        }
        if let specular = mdlMaterial.property(with: .specular)?.float3Value {
            _material.specular = specular
        }
        if let shininess = mdlMaterial.property(with: .specularExponent)?.floatValue {
            _material.shininess = shininess
        }
    }
    
    private func texture(for semantic: MDLMaterialSemantic, in material: MDLMaterial?, textureOrigin: MTKTextureLoader.Origin) -> MTLTexture? {
        let textureLoader = MTKTextureLoader(device: Engine.Device)
        guard let materialProperty = material?.property(with: semantic) else { return nil }
        guard let sourceTexture = materialProperty.textureSamplerValue?.texture else { return nil }
        let options: [MTKTextureLoader.Option : Any] = [.origin : textureOrigin as Any, .generateMipmaps : true]
        let tex = try? textureLoader.newTexture(texture: sourceTexture, options: options)
        return tex
    }
    
    private func createIndexBuffer() {
        if(_indices.count > 0) {
            _indexBuffer = Engine.Device.makeBuffer(bytes: _indices, length: UInt32.stride(_indices.count), options: [])
        }
    }
}

class NoMesh: Mesh {}

class TriangleMesh: Mesh {
    override func createMesh() {
        addVertex(position: SIMD3<Float>( 0, 1,0), color: SIMD4<Float>(1,0,0,1), texCoord: SIMD2<Float>(0.5,0.0))
        addVertex(position: SIMD3<Float>(-1,-1,0), color: SIMD4<Float>(0,1,0,1), texCoord: SIMD2<Float>(0.0,1.0))
        addVertex(position: SIMD3<Float>( 1,-1,0), color: SIMD4<Float>(0,0,1,1), texCoord: SIMD2<Float>(1.0,1.0))
    }
}

class CubeMesh: Mesh {
    override func createMesh() {
        addVertex(position: SIMD3<Float>(-1.0,-1.0,-1.0), color: SIMD4<Float>(1.0, 0.5, 0.0, 1.0), normal: SIMD3<Float>(-1, 0, 0))
        addVertex(position: SIMD3<Float>(-1.0,-1.0, 1.0), color: SIMD4<Float>(0.0, 1.0, 0.5, 1.0), normal: SIMD3<Float>(-1, 0, 0))
        addVertex(position: SIMD3<Float>(-1.0, 1.0, 1.0), color: SIMD4<Float>(0.0, 0.5, 1.0, 1.0), normal: SIMD3<Float>(-1, 0, 0))
        addVertex(position: SIMD3<Float>(-1.0,-1.0,-1.0), color: SIMD4<Float>(1.0, 1.0, 0.0, 1.0), normal: SIMD3<Float>(-1, 0, 0))
        addVertex(position: SIMD3<Float>(-1.0, 1.0, 1.0), color: SIMD4<Float>(0.0, 1.0, 1.0, 1.0), normal: SIMD3<Float>(-1, 0, 0))
        addVertex(position: SIMD3<Float>(-1.0, 1.0,-1.0), color: SIMD4<Float>(1.0, 0.0, 1.0, 1.0), normal: SIMD3<Float>(-1, 0, 0))
        addVertex(position: SIMD3<Float>( 1.0, 1.0, 1.0), color: SIMD4<Float>(1.0, 0.0, 0.5, 1.0), normal: SIMD3<Float>( 1, 0, 0))
        addVertex(position: SIMD3<Float>( 1.0,-1.0,-1.0), color: SIMD4<Float>(0.0, 1.0, 0.0, 1.0), normal: SIMD3<Float>( 1, 0, 0))
        addVertex(position: SIMD3<Float>( 1.0, 1.0,-1.0), color: SIMD4<Float>(0.0, 0.5, 1.0, 1.0), normal: SIMD3<Float>( 1, 0, 0))
        addVertex(position: SIMD3<Float>( 1.0,-1.0,-1.0), color: SIMD4<Float>(1.0, 1.0, 0.0, 1.0), normal: SIMD3<Float>( 1, 0, 0))
        addVertex(position: SIMD3<Float>( 1.0, 1.0, 1.0), color: SIMD4<Float>(0.0, 1.0, 1.0, 1.0), normal: SIMD3<Float>( 1, 0, 0))
        addVertex(position: SIMD3<Float>( 1.0,-1.0, 1.0), color: SIMD4<Float>(1.0, 0.5, 1.0, 1.0), normal: SIMD3<Float>( 1, 0, 0))
        addVertex(position: SIMD3<Float>( 1.0, 1.0, 1.0), color: SIMD4<Float>(1.0, 0.0, 0.0, 1.0), normal: SIMD3<Float>( 0, 1, 0))
        addVertex(position: SIMD3<Float>( 1.0, 1.0,-1.0), color: SIMD4<Float>(0.0, 1.0, 0.0, 1.0), normal: SIMD3<Float>( 0, 1, 0))
        addVertex(position: SIMD3<Float>(-1.0, 1.0,-1.0), color: SIMD4<Float>(0.0, 0.0, 1.0, 1.0), normal: SIMD3<Float>( 0, 1, 0))
        addVertex(position: SIMD3<Float>( 1.0, 1.0, 1.0), color: SIMD4<Float>(1.0, 1.0, 0.0, 1.0), normal: SIMD3<Float>( 0, 1, 0))
        addVertex(position: SIMD3<Float>(-1.0, 1.0,-1.0), color: SIMD4<Float>(0.5, 1.0, 1.0, 1.0), normal: SIMD3<Float>( 0, 1, 0))
        addVertex(position: SIMD3<Float>(-1.0, 1.0, 1.0), color: SIMD4<Float>(1.0, 0.0, 1.0, 1.0), normal: SIMD3<Float>( 0, 1, 0))
        addVertex(position: SIMD3<Float>( 1.0,-1.0, 1.0), color: SIMD4<Float>(1.0, 0.5, 0.0, 1.0), normal: SIMD3<Float>( 0,-1, 0))
        addVertex(position: SIMD3<Float>(-1.0,-1.0,-1.0), color: SIMD4<Float>(0.5, 1.0, 0.0, 1.0), normal: SIMD3<Float>( 0,-1, 0))
        addVertex(position: SIMD3<Float>( 1.0,-1.0,-1.0), color: SIMD4<Float>(0.0, 0.0, 1.0, 1.0), normal: SIMD3<Float>( 0,-1, 0))
        addVertex(position: SIMD3<Float>( 1.0,-1.0, 1.0), color: SIMD4<Float>(1.0, 1.0, 0.5, 1.0), normal: SIMD3<Float>( 0,-1, 0))
        addVertex(position: SIMD3<Float>(-1.0,-1.0, 1.0), color: SIMD4<Float>(0.0, 1.0, 1.0, 1.0), normal: SIMD3<Float>( 0,-1, 0))
        addVertex(position: SIMD3<Float>(-1.0,-1.0,-1.0), color: SIMD4<Float>(1.0, 0.5, 1.0, 1.0), normal: SIMD3<Float>( 0,-1, 0))
        addVertex(position: SIMD3<Float>( 1.0, 1.0,-1.0), color: SIMD4<Float>(1.0, 0.5, 0.0, 1.0), normal: SIMD3<Float>( 0, 0,-1))
        addVertex(position: SIMD3<Float>(-1.0,-1.0,-1.0), color: SIMD4<Float>(0.5, 1.0, 0.0, 1.0), normal: SIMD3<Float>( 0, 0,-1))
        addVertex(position: SIMD3<Float>(-1.0, 1.0,-1.0), color: SIMD4<Float>(0.0, 0.0, 1.0, 1.0), normal: SIMD3<Float>( 0, 0,-1))
        addVertex(position: SIMD3<Float>( 1.0, 1.0,-1.0), color: SIMD4<Float>(1.0, 1.0, 0.0, 1.0), normal: SIMD3<Float>( 0, 0,-1))
        addVertex(position: SIMD3<Float>( 1.0,-1.0,-1.0), color: SIMD4<Float>(0.0, 1.0, 1.0, 1.0), normal: SIMD3<Float>( 0, 0,-1))
        addVertex(position: SIMD3<Float>(-1.0,-1.0,-1.0), color: SIMD4<Float>(1.0, 0.5, 1.0, 1.0), normal: SIMD3<Float>( 0, 0,-1))
        addVertex(position: SIMD3<Float>(-1.0, 1.0, 1.0), color: SIMD4<Float>(1.0, 0.5, 0.0, 1.0), normal: SIMD3<Float>( 0, 0, 1))
        addVertex(position: SIMD3<Float>(-1.0,-1.0, 1.0), color: SIMD4<Float>(0.0, 1.0, 0.0, 1.0), normal: SIMD3<Float>( 0, 0, 1))
        addVertex(position: SIMD3<Float>( 1.0,-1.0, 1.0), color: SIMD4<Float>(0.5, 0.0, 1.0, 1.0), normal: SIMD3<Float>( 0, 0, 1))
        addVertex(position: SIMD3<Float>( 1.0, 1.0, 1.0), color: SIMD4<Float>(1.0, 1.0, 0.5, 1.0), normal: SIMD3<Float>( 0, 0, 1))
        addVertex(position: SIMD3<Float>(-1.0, 1.0, 1.0), color: SIMD4<Float>(0.0, 1.0, 1.0, 1.0), normal: SIMD3<Float>( 0, 0, 1))
        addVertex(position: SIMD3<Float>( 1.0,-1.0, 1.0), color: SIMD4<Float>(1.0, 0.0, 1.0, 1.0), normal: SIMD3<Float>( 0, 0, 1))
    }
}
