import AppKit
import CryptoKit
import Foundation
import PounceKit
import Synchronization

/// Icons for result rows, loaded lazily off the main thread.
///
/// Memory cache for every icon; app bundles are also cached as PNG files under `<caches>/icons/`,
/// keyed by path and modification date, so the first panel of a session does not ask LaunchServices for
/// every app again. The files are rebuildable at any time.
///
/// This lives in the shell rather than in `AppsPlugin` (spec deviation): rows are drawn by the shell
/// from a plugin-agnostic `IconRef`, so every plugin's icons share one loader.
final class IconCache {
    /// 28 pt at 2x.
    nonisolated static let pixelSize = 56

    typealias Loader = @Sendable (PounceKit.IconRef) -> CGImage?

    private let memory = NSCache<NSString, NSImage>()
    private let loader: Loader

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    /// The live loader with a PNG disk cache in `directory`.
    convenience init(diskDirectory: URL?) {
        self.init(loader: { ref in IconLoader.load(ref, diskDirectory: diskDirectory) })
    }

    func cached(_ ref: PounceKit.IconRef) -> NSImage? {
        memory.object(forKey: Self.key(ref))
    }

    /// Returns the icon, loading it on a background thread on a miss.
    func image(for ref: PounceKit.IconRef) async -> NSImage? {
        if let cached = cached(ref) {
            return cached
        }
        let loader = loader
        let cgImage = await Task.detached(priority: .userInitiated) { loader(ref) }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: 28, height: 28))
        memory.setObject(image, forKey: Self.key(ref))
        return image
    }

    private static func key(_ ref: PounceKit.IconRef) -> NSString {
        switch ref {
        case .file(let url): "file:\(url.path)" as NSString
        case .bundleIdentifier(let id): "bundle:\(id)" as NSString
        case .symbol(let name): "symbol:\(name)" as NSString
        }
    }
}

/// The work behind `IconCache`; never runs on the main thread.
nonisolated enum IconLoader {
    /// Counts loads that ran on the main thread (tests assert it stays zero). Release builds still load
    /// correctly; the debug assertion below makes the mistake loud during development.
    static let mainThreadLoads = Mutex(0)

    static func load(_ ref: PounceKit.IconRef, diskDirectory: URL?) -> CGImage? {
        if Thread.isMainThread {
            mainThreadLoads.withLock { $0 += 1 }
            assertionFailure("Icons must load off the main thread")
        }
        switch ref {
        case .symbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil).flatMap(render)
        case .bundleIdentifier(let id):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return fileIcon(url, diskDirectory: diskDirectory)
        case .file(let url):
            return fileIcon(url, diskDirectory: diskDirectory)
        }
    }

    private static func fileIcon(_ url: URL, diskDirectory: URL?) -> CGImage? {
        let cacheFile = url.pathExtension == "app" ? diskDirectory.flatMap { diskCacheURL(for: url, in: $0) } : nil
        if let cacheFile, let data = try? Data(contentsOf: cacheFile),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        {
            return image
        }
        guard let image = render(NSWorkspace.shared.icon(forFile: url.path)) else { return nil }
        if let cacheFile {
            writePNG(image, to: cacheFile)
        }
        return image
    }

    /// `<directory>/<sha256(path|mtime)>.png`; `nil` when the bundle has no modification date.
    static func diskCacheURL(for url: URL, in directory: URL) -> URL? {
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return nil }
        let key = "\(url.path)|\(modified.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).png")
    }

    private static func render(_ image: NSImage) -> CGImage? {
        let size = CGFloat(IconCache.pixelSize)
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        guard let best = image.bestRepresentation(for: rect, context: nil, hints: nil) else { return nil }
        guard
            let context = CGContext(
                data: nil,
                width: IconCache.pixelSize,
                height: IconCache.pixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        best.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
