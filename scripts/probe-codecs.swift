// Public-API capability probe. Creates empty compression sessions; captures no screen.
import Foundation
import VideoToolbox
import CoreMedia

func probe(_ name: String, codec: CMVideoCodecType, lowLatency: Bool) -> [String: Any] {
    var specification: [String: Any] = [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
    ]
    if lowLatency {
        specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true
    }
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault, width: 3840, height: 2160,
        codecType: codec, encoderSpecification: specification as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &session
    )
    var result: [String: Any] = [
        "codec": name, "requested_low_latency": lowLatency,
        "required_hardware": true, "width": 3840, "height": 2160,
        "creation_status": status
    ]
    guard status == noErr, let session else { return result }
    defer { VTCompressionSessionInvalidate(session) }
    var properties: CFDictionary?
    let propertyStatus = VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &properties)
    result["property_query_status"] = propertyStatus
    if let properties = properties as? [String: Any],
       let profile = properties[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any] {
        result["advertised_profiles"] = profile[kVTPropertySupportedValueListKey as String] ?? []
    }
    result["realtime_status"] = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    result["disable_frame_reordering_status"] = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    return result
}

let report: [String: Any] = [
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "scope": "Public VideoToolbox session capabilities only. No video encoded, no screen captured, no speed measured. Advertised profiles are not an exhaustive proof of chroma-format support.",
    "sessions": [
        probe("H.264", codec: kCMVideoCodecType_H264, lowLatency: false),
        probe("H.264", codec: kCMVideoCodecType_H264, lowLatency: true),
        probe("HEVC", codec: kCMVideoCodecType_HEVC, lowLatency: false),
        probe("HEVC", codec: kCMVideoCodecType_HEVC, lowLatency: true)
    ]
]
let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(bytes)
print("")
