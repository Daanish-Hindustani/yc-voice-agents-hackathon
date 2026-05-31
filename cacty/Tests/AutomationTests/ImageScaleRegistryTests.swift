import Testing
@testable import Automation

/// Lock in the scaled-image-pixel → window-local-point math for
/// `ImageScaleRegistry`. The math is load-bearing for every
/// pixel-coord tool (`click(x:y:)`, `right_click`, `double_click`,
/// `drag`, `zoom`) — wrong ratios mean wrong-coordinate output.
@Suite("ImageScaleRegistry")
struct ImageScaleRegistryTests {

    @Test("no resize, no Retina → ratios are 1:1")
    func ratiosOneToOneWhenNoResizeNoRetina() {
        let scale = ImageScaleRegistry.Scale(
            originalWidth: 800,
            originalHeight: 600,
            scaledWidth: 800,
            scaledHeight: 600,
            scaleFactor: 1.0
        )
        #expect(scale.xRatio == 1.0)
        #expect(scale.yRatio == 1.0)
    }

    @Test("Retina capture, no resize → ratios divide by 2")
    func retinaUnresizedHalvesPixels() {
        // 800×600-point window on Retina captures as 1600×1200 px.
        let scale = ImageScaleRegistry.Scale(
            originalWidth: 1600,
            originalHeight: 1200,
            scaledWidth: 1600,
            scaledHeight: 1200,
            scaleFactor: 2.0
        )
        #expect(scale.xRatio == 0.5)
        #expect(scale.yRatio == 0.5)
        // A click at scaled-image-pixel (200, 100) becomes
        // window-local (100, 50) in point space.
        #expect(200.0 * scale.xRatio == 100.0)
        #expect(100.0 * scale.yRatio == 50.0)
    }

    @Test("Retina capture downscaled to fit 1600 → combined ratio")
    func retinaResizedScalesBoth() {
        // 2000×1500-pixel native capture, resized so the longest
        // edge is 1600 → 1600×1200. Backing scale 2.0.
        // To recover points: scaled-pixel × (2000/1600) / 2.0 =
        //                    scaled-pixel × 1.25 / 2.0 = × 0.625.
        let scale = ImageScaleRegistry.Scale(
            originalWidth: 2000,
            originalHeight: 1500,
            scaledWidth: 1600,
            scaledHeight: 1200,
            scaleFactor: 2.0
        )
        #expect(abs(scale.xRatio - 0.625) < 1e-9)
        #expect(abs(scale.yRatio - 0.625) < 1e-9)
    }

    @Test("record and lookup round-trip")
    func recordAndLookup() async {
        let registry = ImageScaleRegistry()
        await registry.record(
            pid: 42, windowId: 7,
            capturedWidth: 1600, capturedHeight: 1200,
            originalWidth: 2000, originalHeight: 1500,
            scaleFactor: 2.0
        )
        let scale = await registry.lookup(pid: 42, windowId: 7)
        #expect(scale != nil)
        #expect(scale?.scaledWidth == 1600)
        #expect(scale?.originalWidth == 2000)
        #expect(scale?.scaleFactor == 2.0)

        let missing = await registry.lookup(pid: 42, windowId: 999)
        #expect(missing == nil)
    }

    @Test("record with nil originals fills from captured dims")
    func nilOriginalsFallback() async {
        let registry = ImageScaleRegistry()
        await registry.record(
            pid: 1, windowId: 1,
            capturedWidth: 800, capturedHeight: 600,
            originalWidth: nil, originalHeight: nil,
            scaleFactor: 1.0
        )
        let scale = await registry.lookup(pid: 1, windowId: 1)
        #expect(scale?.originalWidth == 800)
        #expect(scale?.originalHeight == 600)
        #expect(scale?.xRatio == 1.0)
    }

    @Test("clear() drops all entries")
    func clearWipesEntries() async {
        let registry = ImageScaleRegistry()
        await registry.record(
            pid: 1, windowId: 1,
            capturedWidth: 100, capturedHeight: 100,
            originalWidth: 100, originalHeight: 100,
            scaleFactor: 1.0
        )
        #expect(await registry.lookup(pid: 1, windowId: 1) != nil)
        await registry.clear()
        #expect(await registry.lookup(pid: 1, windowId: 1) == nil)
    }
}
