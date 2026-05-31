import Foundation

/// Per-`(pid, windowId)` resize-ratio registry.
///
/// The model interacts with screenshots in **scaled-image pixel
/// space** — the PNG `get_window_state` / `screenshot` returned to it.
/// Pixel-coord tools (`click(x:y:)`, `right_click`, `double_click`,
/// `drag`, `zoom`) must translate those coordinates back to native
/// window points before posting CGEvents or cropping captures.
///
/// `WindowCapture.captureWindow` already records both `originalWidth`/
/// `originalHeight` (native pixels) and `width`/`height` (post-resize
/// pixels) on the `Screenshot` it returns. This registry caches that
/// mapping under the `(pid, windowId)` key the model uses, so the
/// pixel-coord tools can rescale without having to thread the
/// screenshot through every call.
///
/// Cua's daemon has an equivalent (`ImageResizeRegistry` in
/// `cua-driver/Sources/CuaDriverServer/Tools/ImageResizeRegistry.swift`).
public actor ImageScaleRegistry {
    /// Resize ratio for a captured window. `originalWidth /
    /// scaledWidth` is the multiplier to apply when converting
    /// image pixels → native window points. `scaleFactor` is the
    /// backing-store scale already applied by SCK on Retina
    /// displays — pixel-coord tools want the IMAGE→native point
    /// ratio, which is the ratio of dimensions, not the backing
    /// scale.
    public struct Scale: Sendable, Hashable {
        public let originalWidth: Int
        public let originalHeight: Int
        public let scaledWidth: Int
        public let scaledHeight: Int
        /// Backing-store scale at capture time (2.0 on Retina, 1.0
        /// otherwise). `originalWidth/Height` are in backing-store
        /// pixels; `WindowInfo.bounds` is in points. The ratio
        /// accessors below pre-divide by this so a single multiply
        /// converts a scaled-image pixel directly to a window-local
        /// point.
        public let scaleFactor: Double

        /// Multiplier on an x scaled-image pixel to recover the
        /// native window-local point x.
        ///
        /// `scaled_pixel × originalWidth/scaledWidth` →
        ///   backing-store pixel
        /// `backing_store_pixel / scaleFactor` → point
        public var xRatio: Double {
            (Double(originalWidth) / Double(scaledWidth))
                / max(1.0, scaleFactor)
        }
        /// Multiplier on a y scaled-image pixel. Same shape as `xRatio`.
        public var yRatio: Double {
            (Double(originalHeight) / Double(scaledHeight))
                / max(1.0, scaleFactor)
        }
    }

    private struct Key: Hashable, Sendable {
        let pid: Int32
        let windowId: UInt32
    }

    private var entries: [Key: Scale] = [:]

    public static let shared = ImageScaleRegistry()

    public init() {}

    /// Record (or overwrite) the scale for `(pid, windowId)`. Call
    /// from every code path that returns a `Screenshot` to the
    /// model so subsequent pixel-coord tools see the latest ratio.
    /// Pass `nil` for `originalWidth` / `originalHeight` when the
    /// capture was not resized — the registry stores a 1:1 entry
    /// so callers don't have to special-case the "no resize" path.
    public func record(
        pid: Int32,
        windowId: UInt32,
        capturedWidth: Int,
        capturedHeight: Int,
        originalWidth: Int?,
        originalHeight: Int?,
        scaleFactor: Double
    ) {
        let origW = originalWidth ?? capturedWidth
        let origH = originalHeight ?? capturedHeight
        entries[Key(pid: pid, windowId: windowId)] = Scale(
            originalWidth: origW,
            originalHeight: origH,
            scaledWidth: capturedWidth,
            scaledHeight: capturedHeight,
            scaleFactor: scaleFactor
        )
    }

    /// Look up the most recent scale for `(pid, windowId)`. Returns
    /// `nil` when no screenshot has been captured for that window
    /// yet — pixel-coord tools should treat that as "no remap
    /// needed" (assume the caller is passing native coords) rather
    /// than throwing, so the model can still call them on
    /// app-state.ax workflows that skip the screenshot.
    public func lookup(pid: Int32, windowId: UInt32) -> Scale? {
        entries[Key(pid: pid, windowId: windowId)]
    }

    /// Drop all entries — used in tests.
    public func clear() {
        entries.removeAll()
    }
}
