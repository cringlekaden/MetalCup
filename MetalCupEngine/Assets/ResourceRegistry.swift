/// ResourceRegistry.swift
/// Defines the ResourceRegistry types and helpers for the engine.
/// Created by Kaden Cringle.

import Foundation
import MetalKit

public enum ShaderSourceState: Equatable {
    case canonical
    case projectOverride(relativePath: String)
    case overrideFailed(relativePath: String, error: String)

    public var displayText: String {
        switch self {
        case .canonical:
            return "Canonical Engine shaders"
        case .projectOverride(let relativePath):
            return "Project override active: \(relativePath)"
        case .overrideFailed(let relativePath, let error):
            return "Override failed (\(relativePath)): \(error)"
        }
    }
}

public struct ShaderValidationResult: Equatable {
    public let succeeded: Bool
    public let sourceDescription: String
    public let message: String

    public init(succeeded: Bool, sourceDescription: String, message: String) {
        self.succeeded = succeeded
        self.sourceDescription = sourceDescription
        self.message = message
    }
}

enum ShaderSourceValidationError: LocalizedError, Equatable {
    case unavailableCanonicalResources
    case invalidOverridePath(String)
    case unreadableDirectory(String)
    case missingFiles([String])
    case unexpectedFiles([String])
    case duplicateFilenames([String])
    case unreadableSource(String)
    case missingInclude(file: String, include: String)
    case includeCycle([String])
    case compileFailed(String)
    case missingFunctions([String])

    var errorDescription: String? {
        switch self {
        case .unavailableCanonicalResources:
            return "Canonical Engine shader resources are unavailable."
        case .invalidOverridePath(let message):
            return message
        case .unreadableDirectory(let path):
            return "Shader directory is unreadable: \(path)"
        case .missingFiles(let files):
            return "Shader set is incomplete; missing: \(files.joined(separator: ", "))."
        case .unexpectedFiles(let files):
            return "Shader set contains unexpected Metal files: \(files.joined(separator: ", "))."
        case .duplicateFilenames(let files):
            return "Shader set contains duplicate filenames: \(files.joined(separator: ", "))."
        case .unreadableSource(let file):
            return "Shader source is unreadable or not UTF-8: \(file)."
        case .missingInclude(let file, let include):
            return "Shader \(file) includes missing file \(include)."
        case .includeCycle(let files):
            return "Shader include cycle: \(files.joined(separator: " -> "))."
        case .compileFailed(let message):
            return "Metal compilation failed: \(message)"
        case .missingFunctions(let names):
            return "Compiled shader library is missing required functions: \(names.joined(separator: ", "))."
        }
    }
}

public final class ResourceRegistry {
    public static let canonicalShaderFilenames: [String] = [
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

    public private(set) var defaultLibrary: MTLLibrary?
    public private(set) var canonicalShaderRootURL: URL?
    public private(set) var activeShaderSource: ShaderSourceState = .canonical
    public private(set) var lastShaderValidationResult: ShaderValidationResult?
    public private(set) var lastShaderCompileError: String?

    // General application resources remain separate from Engine-owned shaders.
    public var resourcesRootURL: URL?

    private var canonicalLibrary: MTLLibrary?

    public init(canonicalShaderRootURL: URL? = nil) {
        self.canonicalShaderRootURL = canonicalShaderRootURL?.standardizedFileURL
    }

    public static func bundledCanonicalShaderRootURL() -> URL? {
        Bundle(for: Renderer.self)
            .url(forResource: "Shaders", withExtension: nil)?
            .standardizedFileURL
    }

    public func configureCanonicalShaderRoot(_ url: URL) {
        canonicalShaderRootURL = url.standardizedFileURL
    }

    // Resolve a general resource by name. Shader discovery never uses this path.
    public func url(forResource name: String, withExtension ext: String?) -> URL? {
        if let root = resourcesRootURL {
            let url = ext != nil
                ? root.appendingPathComponent("\(name).\(ext!)")
                : root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    @discardableResult
    public func activateCanonicalShaders(device: MTLDevice,
                                         requiredFunctions: [String]) -> Bool {
        guard let root = canonicalShaderRootURL else {
            recordCanonicalFailure(.unavailableCanonicalResources)
            return false
        }

        switch compileShaderLibrary(at: root, device: device, requiredFunctions: requiredFunctions) {
        case .success(let library):
            canonicalLibrary = library
            defaultLibrary = library
            activeShaderSource = .canonical
            lastShaderCompileError = nil
            lastShaderValidationResult = ShaderValidationResult(
                succeeded: true,
                sourceDescription: "Canonical Engine shaders",
                message: "Compiled and resolved \(requiredFunctions.count) required functions."
            )
            return true
        case .failure(let error):
            recordCanonicalFailure(error)
            return false
        }
    }

    public func useCanonicalShaders() {
        guard let canonicalLibrary else {
            recordCanonicalFailure(.unavailableCanonicalResources)
            return
        }
        defaultLibrary = canonicalLibrary
        activeShaderSource = .canonical
        lastShaderCompileError = nil
        lastShaderValidationResult = ShaderValidationResult(
            succeeded: true,
            sourceDescription: "Canonical Engine shaders",
            message: "Canonical Engine shader library active."
        )
    }

    @discardableResult
    public func activateProjectShaderOverride(at shaderRoot: URL,
                                              relativePath: String,
                                              device: MTLDevice,
                                              requiredFunctions: [String]) -> Bool {
        guard canonicalLibrary != nil else {
            let error = ShaderSourceValidationError.unavailableCanonicalResources
            recordOverrideFailure(relativePath: relativePath, error: error)
            return false
        }

        switch compileShaderLibrary(at: shaderRoot.standardizedFileURL,
                                    device: device,
                                    requiredFunctions: requiredFunctions) {
        case .success(let library):
            defaultLibrary = library
            activeShaderSource = .projectOverride(relativePath: relativePath)
            lastShaderCompileError = nil
            lastShaderValidationResult = ShaderValidationResult(
                succeeded: true,
                sourceDescription: "Project override: \(relativePath)",
                message: "Compiled and resolved \(requiredFunctions.count) required functions."
            )
            return true
        case .failure(let error):
            recordOverrideFailure(relativePath: relativePath, error: error)
            return false
        }
    }

    public func rejectProjectShaderOverride(relativePath: String, message: String) {
        recordOverrideFailure(
            relativePath: relativePath,
            error: .invalidOverridePath(message)
        )
    }

    public var activeShaderSourceStatus: String {
        activeShaderSource.displayText
    }

    public func resolveFunction(_ name: String,
                                device: MTLDevice,
                                fallbackLibrary: MTLLibrary?) -> MTLFunction? {
        resolveFunction(name,
                        device: device,
                        fallbackLibrary: fallbackLibrary,
                        constants: nil)
    }

    public func resolveFunction(_ name: String,
                                device: MTLDevice,
                                fallbackLibrary: MTLLibrary?,
                                constants: MTLFunctionConstantValues?) -> MTLFunction? {
        makeFunction(from: defaultLibrary, name: name, constants: constants)
    }

    private func recordCanonicalFailure(_ error: ShaderSourceValidationError) {
        let message = error.localizedDescription
        defaultLibrary = nil
        canonicalLibrary = nil
        activeShaderSource = .canonical
        lastShaderCompileError = message
        lastShaderValidationResult = ShaderValidationResult(
            succeeded: false,
            sourceDescription: "Canonical Engine shaders",
            message: message
        )
        EngineLoggerContext.log(message, level: .error, category: .renderer)
    }

    private func recordOverrideFailure(relativePath: String,
                                       error: ShaderSourceValidationError) {
        let message = error.localizedDescription
        defaultLibrary = canonicalLibrary
        activeShaderSource = .overrideFailed(relativePath: relativePath, error: message)
        lastShaderCompileError = message
        lastShaderValidationResult = ShaderValidationResult(
            succeeded: false,
            sourceDescription: "Project override: \(relativePath)",
            message: message
        )
        EngineLoggerContext.log(
            "Shader override failed for \(relativePath): \(message)",
            level: .error,
            category: .renderer
        )
    }

    func compileShaderLibrary(at shaderRoot: URL,
                              device: MTLDevice,
                              requiredFunctions: [String]) -> Result<MTLLibrary, ShaderSourceValidationError> {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: shaderRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .failure(.unreadableDirectory(shaderRoot.path))
        }

        var shaderFiles: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "metal" {
            shaderFiles.append(url.standardizedFileURL)
        }

        let grouped = Dictionary(grouping: shaderFiles, by: \.lastPathComponent)
        let duplicates = grouped
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
        if !duplicates.isEmpty {
            return .failure(.duplicateFilenames(duplicates))
        }

        let actualNames = Set(grouped.keys)
        let expectedNames = Set(Self.canonicalShaderFilenames)
        let missing = expectedNames.subtracting(actualNames).sorted()
        if !missing.isEmpty {
            return .failure(.missingFiles(missing))
        }
        let unexpected = actualNames.subtracting(expectedNames).sorted()
        if !unexpected.isEmpty {
            return .failure(.unexpectedFiles(unexpected))
        }

        let fileLookup = grouped.compactMapValues(\.first)
        var combinedSource = ""
        var emittedFiles = Set<String>()
        do {
            for filename in Self.canonicalShaderFilenames {
                guard let url = fileLookup[filename] else {
                    return .failure(.missingFiles([filename]))
                }
                combinedSource.append(
                    try expandIncludes(
                        url: url,
                        fileLookup: fileLookup,
                        emittedFiles: &emittedFiles,
                        includeStack: []
                    )
                )
                combinedSource.append("\n\n")
            }
        } catch let error as ShaderSourceValidationError {
            return .failure(error)
        } catch {
            return .failure(.compileFailed(error.localizedDescription))
        }

        do {
            let options = MTLCompileOptions()
            if #available(macOS 15.0, *) {
                options.mathMode = .fast
            } else {
                options.fastMathEnabled = true
            }
            let library = try device.makeLibrary(source: combinedSource, options: options)
            let missingFunctions = requiredFunctions
                .filter { library.makeFunction(name: $0) == nil }
                .sorted()
            if !missingFunctions.isEmpty {
                return .failure(.missingFunctions(missingFunctions))
            }
            return .success(library)
        } catch {
            return .failure(.compileFailed(error.localizedDescription))
        }
    }

    private func expandIncludes(url: URL,
                                fileLookup: [String: URL],
                                emittedFiles: inout Set<String>,
                                includeStack: [String]) throws -> String {
        let filename = url.lastPathComponent
        if includeStack.contains(filename) {
            throw ShaderSourceValidationError.includeCycle(includeStack + [filename])
        }
        if emittedFiles.contains(url.path) { return "" }

        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            throw ShaderSourceValidationError.unreadableSource(filename)
        }

        emittedFiles.insert(url.path)
        var output = "// \(filename)\n"
        let nextStack = includeStack + [filename]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let includeName = parseInclude(from: String(line)) {
                guard let includeURL = fileLookup[includeName] else {
                    throw ShaderSourceValidationError.missingInclude(file: filename, include: includeName)
                }
                output.append(
                    try expandIncludes(
                        url: includeURL,
                        fileLookup: fileLookup,
                        emittedFiles: &emittedFiles,
                        includeStack: nextStack
                    )
                )
            } else {
                output.append(String(line))
                output.append("\n")
            }
        }
        return output
    }

    private func parseInclude(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#include") else { return nil }
        guard let quoteStart = trimmed.firstIndex(of: "\""),
              let quoteEnd = trimmed[trimmed.index(after: quoteStart)...].firstIndex(of: "\"") else {
            return nil
        }
        let name = trimmed[trimmed.index(after: quoteStart)..<quoteEnd]
        return name.isEmpty ? nil : String(name)
    }

    private func makeFunction(from library: MTLLibrary?,
                              name: String,
                              constants: MTLFunctionConstantValues?) -> MTLFunction? {
        guard let library else { return nil }
        if let constants {
            return try? library.makeFunction(name: name, constantValues: constants)
        }
        return library.makeFunction(name: name)
    }
}
