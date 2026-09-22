import Foundation
import CoreGraphics

/// One crop of a large image, carrying where it came from so detections can be
/// mapped back to original-image coordinates.
public struct Tile: Sendable {
    /// Pixel rect inside the original image, using CoreGraphics' top-left origin.
    public let rect: CGRect
    public let image: CGImage
}

public enum Tiler {
    /// Slice an image into overlapping square tiles.
    ///
    /// Only worth doing for very large images: a distant figure that occupies
    /// 1% of an 8K panorama disappears when the whole frame is resized to the
    /// model's input size, but survives inside a 1280 px tile.
    public static func tiles(for image: LoadedImage, tileSize: Int, overlap: Double) -> [Tile] {
        let width = image.pixelWidth
        let height = image.pixelHeight
        let overlap = min(max(overlap, 0), 0.5)
        let stride = max(1, Int(Double(tileSize) * (1.0 - overlap)))

        var xOffsets: [Int] = []
        var x = 0
        while x < width {
            xOffsets.append(x)
            if x + tileSize >= width { break }
            x += stride
        }
        // Ensure the final column reaches the right edge.
        if let last = xOffsets.last, last + tileSize < width {
            xOffsets.append(max(0, width - tileSize))
        }

        var yOffsets: [Int] = []
        var y = 0
        while y < height {
            yOffsets.append(y)
            if y + tileSize >= height { break }
            y += stride
        }
        if let last = yOffsets.last, last + tileSize < height {
            yOffsets.append(max(0, height - tileSize))
        }

        var result: [Tile] = []
        for oy in yOffsets {
            for ox in xOffsets {
                let w = min(tileSize, width - ox)
                let h = min(tileSize, height - oy)
                let rect = CGRect(x: ox, y: oy, width: w, height: h)
                if let cropped = image.cgImage.cropping(to: rect) {
                    result.append(Tile(rect: rect, image: cropped))
                }
            }
        }
        return result
    }

    /// Map a Vision-normalized box inside a tile back to the original image.
    ///
    /// Vision boxes use a bottom-left origin; tile rects use top-left, so the
    /// y axis is flipped once on the way through.
    public static func mapToOriginal(
        box: BoundingBox,
        tileRect: CGRect,
        originalSize: CGSize
    ) -> BoundingBox {
        let ow = Double(originalSize.width)
        let oh = Double(originalSize.height)
        guard ow > 0, oh > 0 else { return box }

        let tx = Double(tileRect.origin.x)
        let ty = Double(tileRect.origin.y)
        let tw = Double(tileRect.width)
        let th = Double(tileRect.height)

        // Vision bottom-left y of the tile's bottom edge within the original.
        let tileBottomVision = (oh - ty - th) / oh

        let mappedX = (tx + box.x * tw) / ow
        let mappedW = box.width * tw / ow
        let mappedH = box.height * th / oh
        let mappedY = tileBottomVision + box.y * th / oh

        return BoundingBox(x: mappedX, y: mappedY, width: mappedW, height: mappedH)
    }
}
