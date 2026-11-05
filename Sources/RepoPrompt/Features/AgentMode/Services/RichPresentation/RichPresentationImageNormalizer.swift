import CoreGraphics
import Foundation
import ImageIO
import RepoPromptAgentCore
import UniformTypeIdentifiers

/// A normalized article image: metadata-free sRGB JPEG on white, longest edge within the limit.
struct RichPresentationNormalizedImage: Equatable {
    let jpegData: Data
    let width: Int
    let height: Int
}

/// Strict ImageIO validation and normalization for downloaded article images (spec A5).
///
/// Accepts only a structurally complete, single-frame JPEG or PNG whose actual format matches a
/// compatible declared MIME type and that ImageIO reports complete. It rejects animation (APNG `acTL`,
/// multi-image sources), structural truncation or framing damage, and sources above the
/// overflow-checked pixel ceiling before any pixel decode. "Complete" means structural framing plus
/// ImageIO acceptance, not a pixel-level check: damaged entropy-coded (JPEG) or compressed (PNG IDAT)
/// data inside a well-framed stream can still decode to a visibly corrupt image. The accepted image is
/// downsampled with ImageIO, composited on white in sRGB and re-encoded as JPEG without the
/// source's metadata; the original bytes are discarded. There is no fallback decoder.
/// Synchronous and CPU-bound: callers run it off the main actor under the decode permit.
enum RichPresentationImageNormalizer {
    enum Format: Equatable {
        case jpeg
        case png

        var typeIdentifier: String {
            switch self {
            case .jpeg: UTType.jpeg.identifier
            case .png: UTType.png.identifier
            }
        }
    }

    static let outputQuality = 0.85

    static func normalize(
        data: Data,
        mimeType: String?,
        limits: RichPresentationImageLimits
    ) -> Result<RichPresentationNormalizedImage, RichPresentationImageFailureCode> {
        guard let declared = format(forMIMEType: mimeType),
              let actual = completeFormat(of: data),
              declared == actual
        else { return .failure(.invalidImage) }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetType(source) as String? == actual.typeIdentifier,
              CGImageSourceGetCount(source) == 1
        else { return .failure(.invalidImage) }

        // Header dimensions first: the pixel ceiling never depends on decoding the pixels.
        let header = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let width = (header?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (header?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        {
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            guard !overflow, pixels <= limits.maxSourcePixels else { return .failure(.tooLarge) }
        }
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let width = (header?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (header?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return .failure(.invalidImage) }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(limits.maxOutputLongestEdge, max(width, height)),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
              thumbnail.width > 0, thumbnail.height > 0,
              max(thumbnail.width, thumbnail.height) <= limits.maxOutputLongestEdge,
              let flattened = flattenedOnWhiteSRGB(thumbnail),
              let jpeg = encodeJPEG(flattened)
        else { return .failure(.invalidImage) }
        guard jpeg.count <= limits.maxOutputBytes else { return .failure(.tooLarge) }
        return .success(RichPresentationNormalizedImage(jpegData: jpeg, width: flattened.width, height: flattened.height))
    }

    /// Compatible declared MIME types (parameters and case ignored).
    static func format(forMIMEType mimeType: String?) -> Format? {
        guard let essence = mimeType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        else { return nil }
        switch essence {
        case "image/jpeg", "image/jpg": return .jpeg
        case "image/png": return .png
        default: return nil
        }
    }

    /// The actual format when the bytes form a well-framed JPEG ending exactly at its EOI, or a
    /// complete, well-framed, non-animated PNG (signature, IHDR first, IEND last); otherwise `nil`.
    static func completeFormat(of data: Data) -> Format? {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Format? in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let count = bytes.count
            if count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
                return isFramedJPEG(bytes) ? .jpeg : nil
            }
            let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            guard count > signature.count, zip(bytes, signature).allSatisfy({ $0 == $1 }) else { return nil }
            var offset = signature.count
            var isFirstChunk = true
            while count - offset >= 12 {
                let length = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                    | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
                let type = String(decoding: bytes[(offset + 4) ..< (offset + 8)], as: UTF8.self)
                guard length <= Int(Int32.max), count - offset - 12 >= length else { return nil }
                if isFirstChunk, type != "IHDR" { return nil }
                isFirstChunk = false
                if type == "acTL" { return nil }
                let end = offset + 12 + length
                if type == "IEND" {
                    return length == 0 && end == count ? .png : nil
                }
                offset = end
            }
            return nil
        }
    }

    /// Bounded JPEG marker/segment framing walk (not a codec): SOI, then length-checked segments
    /// with known markers only; each scan's entropy data may contain only stuffed `FF 00`, `RSTn`
    /// and fill bytes until the next marker; at least one scan; the first EOI must be the last two
    /// bytes. Rejects trailing payload (including trailing padding, a second stream or a second
    /// EOI), reserved or out-of-place markers, a second SOI, and segments overrunning the data.
    /// Well-framed but damaged entropy data is not detected here. Strict by choice: trailing padding
    /// and MPF / gain-map secondary images after the first EOI are known false rejections.
    private static func isFramedJPEG(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let count = bytes.count
        var index = 2
        var sawScan = false
        while index < count {
            guard bytes[index] == 0xFF else { return false }
            while index < count, bytes[index] == 0xFF {
                index += 1
            }
            guard index < count else { return false }
            let marker = bytes[index]
            index += 1
            switch marker {
            case 0xD9:
                return sawScan && index == count
            case 0x01:
                continue
            case 0xC0 ... 0xCF, 0xDA ... 0xFE:
                guard count - index >= 2 else { return false }
                let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
                guard length >= 2, count - index >= length else { return false }
                index += length
                guard marker == 0xDA else { continue }
                sawScan = true
                while true {
                    guard index < count else { return false }
                    guard bytes[index] == 0xFF else {
                        index += 1
                        continue
                    }
                    guard index + 1 < count else { return false }
                    let next = bytes[index + 1]
                    if next == 0x00 || (0xD0 ... 0xD7).contains(next) {
                        index += 2
                    } else if next == 0xFF {
                        index += 1
                    } else {
                        break
                    }
                }
            default:
                return false
            }
        }
        return false
    }

    private static func flattenedOnWhiteSRGB(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// Encodes only the pixels: the bitmap-context image carries no source EXIF, GPS, IPTC or XMP.
    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: outputQuality] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
