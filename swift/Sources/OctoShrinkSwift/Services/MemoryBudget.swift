import Foundation
import ImageIO

/// Conservative estimate used to limit concurrent image work. This is a scheduling
/// heuristic; ImageIO/codec allocations vary, so it is not a hard RSS ceiling.
enum ImageMemoryBudget {
    static let mebibyte: UInt64 = 1_048_576
    static let minimumBudget: UInt64 = 256 * mebibyte
    static let unknownMemoryBudget: UInt64 = 512 * mebibyte

    static var systemLimit: UInt64 {
        limit(totalPhysicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    static func limit(totalPhysicalMemory: UInt64?) -> UInt64 {
        guard let totalPhysicalMemory, totalPhysicalMemory > 0 else {
            return unknownMemoryBudget
        }
        return max(minimumBudget, totalPhysicalMemory / 4)
    }

    /// `width * height * 16 + encodedSize * 2 + 64 MiB`, saturating on overflow.
    /// Missing dimensions use the conservative encoded-size fallback.
    static func estimate(encodedSize: UInt64, width: UInt64?, height: UInt64?) -> UInt64 {
        guard let width, let height, width > 0, height > 0 else {
            return saturatingAdd(saturatingMultiply(encodedSize, 4), 256 * mebibyte)
        }
        let pixels = saturatingMultiply(saturatingMultiply(width, height), 16)
        return saturatingAdd(
            saturatingAdd(pixels, saturatingMultiply(encodedSize, 2)),
            64 * mebibyte
        )
    }

    /// Reads only file metadata and image headers; it never asks ImageIO to decode pixels.
    static func estimate(fileAtPath path: String) -> UInt64 {
        autoreleasepool {
            let url = URL(fileURLWithPath: path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let encodedSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
            guard let source,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else {
                return estimate(encodedSize: encodedSize, width: nil, height: nil)
            }
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value
            return estimate(encodedSize: encodedSize, width: width, height: height)
        }
    }

    private static func saturatingMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? .max : value
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}
