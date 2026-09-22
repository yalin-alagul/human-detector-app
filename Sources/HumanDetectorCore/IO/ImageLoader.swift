import Foundation
import CoreGraphics
import ImageIO

/// Decoded, EXIF-upright image plus its true pixel dimensions.
public struct LoadedImage: Sendable {
    public let cgImage: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int

    public var longEdge: Int { max(pixelWidth, pixelHeight) }
    public var shortEdge: Int { min(pixelWidth, pixelHeight) }
}

public enum ImageLoadError: Error, LocalizedError {
    case unreadable(String)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "Could not open image at \(path)"
        case .decodeFailed(let path): return "Could not decode image at \(path)"
        }
    }
}

/// One image's lightweight header info, read without decoding pixels.
public struct ImageInfo: Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var orientation: CGImagePropertyOrientation

    public var longEdge: Int { max(pixelWidth, pixelHeight) }
}

public enum ImageLoader {
    /// Read dimensions and orientation without decoding the pixels.
    public static func info(at url: URL) -> ImageInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let rawOrientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return ImageInfo(
            pixelWidth: width,
            pixelHeight: height,
            orientation: CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        )
    }

    /// Decode an upright image whose long edge is at most `maxPixelSize`.
    ///
    /// Using `CGImageSourceCreateThumbnailAtIndex` with
    /// `kCGImageSourceCreateThumbnailWithTransform` applies EXIF orientation and
    /// handles HEIC/HEIF natively, so no external HEIC library is required.
    /// Thumbnails never upscale, so small images come back untouched.
    public static func load(at url: URL, maxPixelSize: Int) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoadError.unreadable(url.path)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLoadError.decodeFailed(url.path)
        }
        return LoadedImage(
            cgImage: cgImage,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
    }

    /// Decode at native resolution (used only for panoramas that need tiling).
    public static func loadFullSize(at url: URL) throws -> LoadedImage {
        let info = info(at: url)
        let maxEdge = max(info?.pixelWidth ?? 4096, info?.pixelHeight ?? 4096)
        return try load(at: url, maxPixelSize: maxEdge)
    }

    /// Small upright thumbnail for the review UI.
    public static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        try? load(at: url, maxPixelSize: maxPixelSize).cgImage
    }
}
