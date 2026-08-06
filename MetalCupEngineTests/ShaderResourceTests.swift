import Foundation
import Metal
import Testing
@testable import MetalCupEngine

struct ShaderResourceTests {
    private let expectedNames: Set<String> = [
        "BasicShaders.metal",
        "CloudImpostor.metal",
        "FinalShaders.metal",
        "ForwardPlusCulling.metal",
        "IBLShaders.metal",
        "InstancedShaders.metal",
        "PBR.metal",
        "PickingShaders.metal",
        "ProceduralSky.metal",
        "Shared.metal",
        "SkyboxShaders.metal"
    ]

    @Test
    func bundledCanonicalSetCompilesAndResolvesRegisteredFunctions() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = try #require(ResourceRegistry.bundledCanonicalShaderRootURL())
        let names = try metalFilenames(at: root)

        #expect(names.count == 11)
        #expect(Set(names) == expectedNames)
        #expect(Set(ResourceRegistry.canonicalShaderFilenames) == expectedNames)

        let registry = ResourceRegistry(canonicalShaderRootURL: root)
        #expect(registry.activateCanonicalShaders(
            device: device,
            requiredFunctions: ShaderLibrary.requiredFunctionNames
        ))
        #expect(registry.activeShaderSource == .canonical)
        #expect(registry.lastShaderValidationResult?.succeeded == true)

        for functionName in ShaderLibrary.requiredFunctionNames {
            #expect(registry.defaultLibrary?.makeFunction(name: functionName) != nil)
        }
    }

    @Test
    func projectShaderFolderDoesNotOverrideWithoutExplicitActivation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let canonicalRoot = try #require(ResourceRegistry.bundledCanonicalShaderRootURL())
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let projectShaderRoot = temporaryRoot
            .appendingPathComponent("Assets/Shaders", isDirectory: true)
        try copyCanonicalShaders(from: canonicalRoot, to: projectShaderRoot)

        let registry = ResourceRegistry(canonicalShaderRootURL: canonicalRoot)
        #expect(registry.activateCanonicalShaders(
            device: device,
            requiredFunctions: ShaderLibrary.requiredFunctionNames
        ))

        #expect(FileManager.default.fileExists(atPath: projectShaderRoot.path))
        #expect(registry.activeShaderSource == .canonical)
    }

    @Test
    func validOverrideActivatesAndIncompleteOverrideFailsBackToCanonical() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let canonicalRoot = try #require(ResourceRegistry.bundledCanonicalShaderRootURL())
        let overrideRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: overrideRoot) }
        try copyCanonicalShaders(from: canonicalRoot, to: overrideRoot)

        let registry = ResourceRegistry(canonicalShaderRootURL: canonicalRoot)
        #expect(registry.activateCanonicalShaders(
            device: device,
            requiredFunctions: ShaderLibrary.requiredFunctionNames
        ))
        #expect(registry.activateProjectShaderOverride(
            at: overrideRoot,
            relativePath: "Assets/Shaders",
            device: device,
            requiredFunctions: ShaderLibrary.requiredFunctionNames
        ))
        #expect(registry.activeShaderSource == .projectOverride(relativePath: "Assets/Shaders"))

        try FileManager.default.removeItem(
            at: overrideRoot.appendingPathComponent("BasicShaders.metal")
        )
        #expect(!registry.activateProjectShaderOverride(
            at: overrideRoot,
            relativePath: "Assets/Shaders",
            device: device,
            requiredFunctions: ShaderLibrary.requiredFunctionNames
        ))
        guard case .overrideFailed(let path, let error) = registry.activeShaderSource else {
            Issue.record("Expected visible override failure state")
            return
        }
        #expect(path == "Assets/Shaders")
        #expect(error.contains("BasicShaders.metal"))
        #expect(registry.defaultLibrary != nil)

        registry.useCanonicalShaders()
        #expect(registry.activeShaderSource == .canonical)
    }

    @Test
    func duplicateFilenameAndMissingIncludeFailClearly() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let canonicalRoot = try #require(ResourceRegistry.bundledCanonicalShaderRootURL())
        let duplicateRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: duplicateRoot) }
        try copyCanonicalShaders(from: canonicalRoot, to: duplicateRoot)

        let nested = duplicateRoot.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: duplicateRoot.appendingPathComponent("BasicShaders.metal"),
            to: nested.appendingPathComponent("BasicShaders.metal")
        )

        let registry = ResourceRegistry(canonicalShaderRootURL: canonicalRoot)
        let duplicateResult = registry.compileShaderLibrary(
            at: duplicateRoot,
            device: device,
            requiredFunctions: ShaderLibrary.requiredFunctionNames
        )
        guard case .failure(let duplicateError) = duplicateResult else {
            Issue.record("Expected duplicate shader filename validation failure")
            return
        }
        #expect(duplicateError == .duplicateFilenames(["BasicShaders.metal"]))

        try FileManager.default.removeItem(at: nested)
        let basicURL = duplicateRoot.appendingPathComponent("BasicShaders.metal")
        let source = try String(contentsOf: basicURL, encoding: .utf8)
        try ("#include \"MissingShaderInclude.metal\"\n" + source)
            .write(to: basicURL, atomically: true, encoding: .utf8)

        let missingIncludeResult = registry.compileShaderLibrary(
            at: duplicateRoot,
            device: device,
            requiredFunctions: ShaderLibrary.requiredFunctionNames
        )
        guard case .failure(let missingIncludeError) = missingIncludeResult else {
            Issue.record("Expected missing include validation failure")
            return
        }
        #expect(missingIncludeError ==
            .missingInclude(file: "BasicShaders.metal", include: "MissingShaderInclude.metal")
        )
    }

    private func metalFilenames(at root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "metal" }
        .map(\.lastPathComponent)
        .sorted()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetalCupShaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func copyCanonicalShaders(from sourceRoot: URL, to destinationRoot: URL) throws {
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        for name in ResourceRegistry.canonicalShaderFilenames {
            try FileManager.default.copyItem(
                at: sourceRoot.appendingPathComponent(name),
                to: destinationRoot.appendingPathComponent(name)
            )
        }
    }
}
