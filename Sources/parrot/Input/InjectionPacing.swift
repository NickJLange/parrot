import AppKit

/// Picks injection pacing based on the frontmost app. Citrix's synthetic-
/// keyboard virtual channel corrupts full-speed 20-char bursts (character
/// scrambling, drops, out-of-order interleaving observed empirically across
/// several live sessions) -- confirmed fixed with 10-char chunks paced 10ms
/// apart. Every other app keeps the original fast, unpaced behavior.
enum InjectionPacing {
    static let defaultChunkSize = 20
    static let defaultDelayMs = 0

    private static let citrixChunkSize = 10
    private static let citrixDelayMs = 10

    /// Bundle IDs that get paced injection automatically. Both are parts of
    /// Citrix Workspace: the active ICA session window is "Citrix
    /// Viewer.app" (a bundled helper), and "nomas" is the Workspace
    /// launcher/store, which can also host a text-entry UI.
    private static let pacedBundleIDs: Set<String> = [
        "com.citrix.receiver.icaviewer.mac",
        "com.citrix.receiver.nomas",
    ]

    @MainActor
    static func forFrontmostApp() -> (chunkSize: Int, delayMs: Int) {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              pacedBundleIDs.contains(bundleID)
        else {
            return (defaultChunkSize, defaultDelayMs)
        }
        return (citrixChunkSize, citrixDelayMs)
    }
}
