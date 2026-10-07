// MPEG-4 and QuickTime files (MP4, M4V, MOV), through AVFoundation: the
// format descriptions carry the codec, the colour's transfer function and the
// sample entry's own boxes (hvcC, avcC, Dolby Vision's dvcC).

import AVFoundation
import CoreMedia
import Foundation

enum MP4Probe {
    static func probe(_ url: URL) async -> VideoInfo? {
        let asset = AVURLAsset(url: url)
        guard let (duration, tracks) = try? await asset.load(.duration, .tracks) else { return nil }
        var info = VideoInfo()
        if duration.isNumeric, duration.seconds > 0 { info.duration = duration.seconds }
        for track in tracks {
            switch track.mediaType {
            case .video where info.codec == nil:
                guard let (size, transform, rate, descriptions) = try? await track.load(.naturalSize, .preferredTransform,
                                                                                         .nominalFrameRate, .formatDescriptions),
                      let description = descriptions.first else { continue }
                let shown = size.applying(transform)
                info.width = Int(abs(shown.width).rounded())
                info.height = Int(abs(shown.height).rounded())
                if rate > 0 { info.frameRate = Double(rate) }
                describeVideo(description, into: &info)
            case .audio:
                guard let (descriptions, language, enabled) = try? await track.load(.formatDescriptions, .languageCode, .isEnabled),
                      let description = descriptions.first,
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { continue }
                info.audio.append(VideoInfo.Audio(codec: audioCodec(format.mFormatID), channels: Int(format.mChannelsPerFrame),
                                                  language: language == "und" ? nil : language, isDefault: enabled))
            case .subtitle, .closedCaption:
                info.subtitles += 1
            default:
                break
            }
        }
        if !info.audio.isEmpty, !info.audio.contains(where: \.isDefault) { info.audio[0].isDefault = true }
        return info.codec == nil ? nil : info
    }

    private static func describeVideo(_ description: CMFormatDescription, into info: inout VideoInfo) {
        let subtype = fourCC(CMFormatDescriptionGetMediaSubType(description))
        var dolbyVisionEntry = false
        switch subtype {
        case "hvc1", "hev1": info.codec = "HEVC"
        case "dvh1", "dvhe": info.codec = "HEVC"; dolbyVisionEntry = true
        case "avc1", "avc3": info.codec = "H.264"
        case "dva1", "dvav": info.codec = "H.264"; dolbyVisionEntry = true
        case "av01": info.codec = "AV1"
        case "dav1": info.codec = "AV1"; dolbyVisionEntry = true
        case "vp09": info.codec = "VP9"
        case "apch", "apcn", "apcs", "apco", "ap4h", "ap4x": info.codec = "ProRes"
        case "mp4v": info.codec = "MPEG-4"
        default: info.codec = subtype.trimmingCharacters(in: .whitespaces).uppercased()
        }
        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
        var vuiTransfer: Int?, masteringDisplay = false
        if let data = atoms["hvcC"] as? Data, let configuration = HEVCConfiguration(data) {
            info.profile = configuration.profileName
            info.bitDepth = configuration.bitDepth
            vuiTransfer = configuration.transfer
            masteringDisplay = configuration.hasMasteringDisplay
        } else if let data = atoms["avcC"] as? Data, let configuration = AVCConfiguration(data) {
            info.profile = configuration.profileName
            info.bitDepth = configuration.bitDepth
        }
        if info.bitDepth == nil { info.bitDepth = extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int }
        if let record = ["dvcC", "dvvC", "dvwC"].lazy.compactMap({ atoms[$0] as? Data }).first, record.count >= 5 {
            let bytes = [UInt8](record)
            info.hdr = .dolbyVision(profile: Int(bytes[2] >> 1), compatibility: Int(bytes[4] >> 4))
            return
        }
        if dolbyVisionEntry {
            info.hdr = .dolbyVision(profile: 0, compatibility: 0)
            return
        }
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String || vuiTransfer == 16 {
            info.hdr = .hdr10
        } else if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String || vuiTransfer == 18 {
            info.hdr = .hlg
        } else if transfer == nil, vuiTransfer == nil, masteringDisplay {
            info.hdr = .hdr10
        }
    }

    private static func audioCodec(_ format: AudioFormatID) -> String {
        switch format {
        case kAudioFormatEnhancedAC3: "DD+"
        case kAudioFormatAC3: "DD"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD: "AAC"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatLinearPCM: "PCM"
        case kAudioFormatOpus: "Opus"
        case kAudioFormatMPEGLayer3: "MP3"
        default:
            switch fourCC(format) {
            case "dtsc": "DTS"
            case "dtsh", "dtsl": "DTS-HD"
            case "dtse": "DTS Express"
            case "mlpa": "TrueHD"
            default: fourCC(format).trimmingCharacters(in: .whitespaces).uppercased()
            }
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
