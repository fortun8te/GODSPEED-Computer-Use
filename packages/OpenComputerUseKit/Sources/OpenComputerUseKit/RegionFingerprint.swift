import CoreGraphics

/// A cheap map of where an image changed.
///
/// The image is split into a grid. Each cell becomes one 64-bit average hash.
/// Two maps of the same window can then show which cells changed,
/// without comparing every pixel again.
public struct RegionFingerprint: Equatable, Sendable {
    /// Cells across the image.
    public let columns: Int
    /// Cells down the image.
    public let rows: Int
    /// One hash per cell, row by row, starting at the top-left cell.
    public let hashes: [UInt64]
    /// Width of the source image in pixels. Fingerprints of different sizes never match.
    public let pixelWidth: Int
    /// Height of the source image in pixels.
    public let pixelHeight: Int

    /// Builds a fingerprint. Returns nil if the grid is empty or a cell is smaller than 8 pixels.
    public static func make(_ image: CGImage, columns: Int = 16, rows: Int = 10) -> RegionFingerprint? {
        guard columns > 0, rows > 0 else { return nil }
        let width = image.width
        let height = image.height
        // Each cell needs at least 8 pixels in each direction, so every sample has a pixel.
        guard width >= columns * 8, height >= rows * 8 else { return nil }

        // Convert the whole image to gray once. Drawing one image is much cheaper than converting per cell.
        guard let whole = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        whole.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let grayImage = whole.makeImage() else { return nil }

        // One 8x8 gray buffer, reused for every cell.
        guard let small = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let raw = small.data else { return nil }
        small.interpolationQuality = .high
        let pixels = raw.bindMemory(to: UInt8.self, capacity: 64)

        var values = [Int](repeating: 0, count: 64)
        var hashes: [UInt64] = []
        hashes.reserveCapacity(columns * rows)
        // `pixels` points into `small`'s buffer, so `small` must stay alive until the last read.
        let completed = withExtendedLifetime(small) { () -> Bool in
            for row in 0..<rows {
                for column in 0..<columns {
                    // Crop the cell first, so neighbouring cells never bleed into its samples.
                    let x0 = column * width / columns
                    let x1 = (column + 1) * width / columns
                    let y0 = row * height / rows
                    let y1 = (row + 1) * height / rows
                    let rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                    guard let cell = grayImage.cropping(to: rect) else { return false }
                    small.draw(cell, in: CGRect(x: 0, y: 0, width: 8, height: 8))
                    for index in 0..<64 {
                        values[index] = Int(pixels[index])
                    }
                    hashes.append(averageHash(values))
                }
            }
            return true
        }
        guard completed else { return nil }
        return RegionFingerprint(
            columns: columns, rows: rows, hashes: hashes, pixelWidth: width, pixelHeight: height
        )
    }

    /// Cell indexes whose hash differs from `other` by more than `threshold` bits.
    /// Different grid sizes or source image sizes count every cell as changed.
    public func changedCells(comparedTo other: RegionFingerprint, threshold: Int = 6) -> [Int] {
        guard other.columns == columns, other.rows == rows, other.hashes.count == hashes.count,
              other.pixelWidth == pixelWidth, other.pixelHeight == pixelHeight else {
            return Array(hashes.indices)
        }
        var changed: [Int] = []
        for index in hashes.indices where (hashes[index] ^ other.hashes[index]).nonzeroBitCount > threshold {
            changed.append(index)
        }
        return changed
    }

    /// The smallest rectangle around all changed cells, in image coordinates.
    /// `size` is the image size in pixels or points. Returns nil if nothing changed.
    public func changedRect(comparedTo other: RegionFingerprint, in size: CGSize, threshold: Int = 6) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let cells = changedCells(comparedTo: other, threshold: threshold)
        guard !cells.isEmpty else { return nil }

        // Find the outer columns and rows that contain a changed cell.
        var firstColumn = Int.max, lastColumn = Int.min
        var firstRow = Int.max, lastRow = Int.min
        for index in cells {
            let column = index % columns
            let row = index / columns
            firstColumn = min(firstColumn, column)
            lastColumn = max(lastColumn, column)
            firstRow = min(firstRow, row)
            lastRow = max(lastRow, row)
        }

        let cellWidth = size.width / CGFloat(columns)
        let cellHeight = size.height / CGFloat(rows)
        return CGRect(
            x: CGFloat(firstColumn) * cellWidth,
            y: CGFloat(firstRow) * cellHeight,
            width: CGFloat(lastColumn - firstColumn + 1) * cellWidth,
            height: CGFloat(lastRow - firstRow + 1) * cellHeight
        )
    }

    /// Average hash of 64 gray values: one bit per sample, set when brighter than the mean.
    private static func averageHash(_ values: [Int]) -> UInt64 {
        var sum = 0
        for value in values {
            sum += value
        }
        let mean = sum / 64
        var hash: UInt64 = 0
        for index in 0..<64 where values[index] > mean {
            hash |= 1 << UInt64(index)
        }
        return hash
    }
}
