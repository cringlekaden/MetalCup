import Foundation
import Metal
import QuartzCore
import Testing
@testable import MetalCupEngine

struct ContinuousIBLPerformanceTests {
    @Test
    func interactiveTierGPUUpperBoundAndMemoryContract() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let source = try Phase3MetalTestSupport.makeCube(
            device: device,
            size: 256,
            mipmapped: true,
            label: "ContinuousIBL.Performance.Source"
        )
        Phase3MetalTestSupport.fillUniform(source, color: SIMD4<Float>(0.2, 0.3, 0.5, 1))
        try Phase3MetalTestSupport.generateMipmaps(source)

        let diffuseStart = CACurrentMediaTime()
        _ = try Phase3MetalTestSupport.renderIrradiance(
            device: device,
            library: library,
            source: source,
            size: 16,
            sampleCount: 410
        )
        let diffuseSeconds = CACurrentMediaTime() - diffuseStart

        let specularStart = CACurrentMediaTime()
        _ = try Phase3MetalTestSupport.renderPrefilter(
            device: device,
            library: library,
            source: source,
            size: 128,
            sampleCount: 205
        )
        let specularSeconds = CACurrentMediaTime() - specularStart

        // The helper synchronizes per face/mip, so these are deliberately
        // conservative CPU-wall upper bounds, not production command-buffer GPU time.
        print("PHASE3_CONTINUOUS_IBL_PERF device=\(device.name) diffuseUpperMs=\(diffuseSeconds * 1000) specularUpperMs=\(specularSeconds * 1000)")
        #expect(diffuseSeconds.isFinite && diffuseSeconds > 0)
        #expect(specularSeconds.isFinite && specularSeconds > 0)

        let previousCoreBytes = cubemapBytes(size: 2048, mipmapped: true) * 2
            + cubemapBytes(size: 1024, mipmapped: true) * 2
            + cubemapBytes(size: 64, mipmapped: false) * 2
            + cubemapBytes(size: 512, mipmapped: true)
            + cubemapBytes(size: 256, mipmapped: true)
            + cubemapBytes(size: 32, mipmapped: false)
            + 512 * 512 * 8
        let phase3CoreBytes = cubemapBytes(size: 1024, mipmapped: true) * 2
            + cubemapBytes(size: 512, mipmapped: true) * 2
            + cubemapBytes(size: 64, mipmapped: false) * 2
            + cubemapBytes(size: 256, mipmapped: true) * 2
            + cubemapBytes(size: 128, mipmapped: true) * 2
            + cubemapBytes(size: 16, mipmapped: false) * 2
            + 512 * 512 * 8
        #expect(previousCoreBytes == 694_599_584)
        #expect(phase3CoreBytes == 180_772_736)
        #expect(phase3CoreBytes < previousCoreBytes / 3)
    }

    private func cubemapBytes(size: Int, mipmapped: Bool) -> Int {
        var totalTexels = 0
        var levelSize = size
        repeat {
            totalTexels += levelSize * levelSize * 6
            levelSize = max(levelSize / 2, 1)
        } while mipmapped && levelSize > 1
        if mipmapped { totalTexels += 6 }
        return totalTexels * 8
    }
}
