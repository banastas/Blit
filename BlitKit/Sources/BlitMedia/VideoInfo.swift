// What a video file's header says about it, for the file list's Video column
// (PRD R2.6): the picture (resolution, HDR or Dolby Vision, codec), the main
// audio track and the running time. VideoProbe reads it.

import Foundation

public struct VideoInfo: Codable, Hashable, Sendable {
    public enum HDR: Codable, Hashable, Sendable {
        /// PQ (SMPTE ST 2084): HDR10, or HDR10+ (whose dynamic metadata is
        /// in the frames, not the header).
        case hdr10
        case hlg
        /// Dolby Vision. `compatibility` is the base layer's fallback: 1 HDR10,
        /// 2 SDR, 4 HLG, 6 UHD Blu-ray (HDR10), 0 none.
        case dolbyVision(profile: Int, compatibility: Int)
    }

    public struct Audio: Codable, Hashable, Sendable {
        /// "TrueHD", "DD+", "DTS-HD MA", "AAC"…
        public var codec: String
        public var channels: Int?
        public var atmos = false
        /// The track's language, if it says (ISO 639-2 or BCP 47).
        public var language: String?
        public var isDefault = true

        public init(codec: String, channels: Int? = nil, atmos: Bool = false, language: String? = nil, isDefault: Bool = true) {
            self.codec = codec
            self.channels = channels
            self.atmos = atmos
            self.language = language
            self.isDefault = isDefault
        }
    }

    public var width: Int?
    public var height: Int?
    public var interlaced = false
    /// "HEVC", "H.264", "AV1", "VP9"…
    public var codec: String?
    /// "Main 10", "High"…
    public var profile: String?
    public var bitDepth: Int?
    public var frameRate: Double?
    public var hdr: HDR?
    public var audio: [Audio] = []
    public var subtitles = 0
    /// Seconds.
    public var duration: Double?

    public init() {}
}

extension VideoInfo {
    /// "2160p", "1080i", "576p": by width as much as height, so a 3840 × 1600
    /// scope film is 2160p as its release calls it.
    public var resolution: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let lines = if width >= 7600 || height >= 4300 { 4320 }
            else if width >= 3800 || height >= 2100 { 2160 }
            else if width >= 2500 || height >= 1400 { 1440 }
            else if width >= 1900 || height >= 1000 { 1080 }
            else if width >= 1200 || height >= 700 { 720 }
            else { height }
        return "\(lines)\(interlaced ? "i" : "p")"
    }

    /// "DV", "HDR10" or "HLG"; nil for SDR.
    public var hdrLabel: String? {
        switch hdr {
        case .hdr10: "HDR10"
        case .hlg: "HLG"
        case .dolbyVision: "DV"
        case nil: nil
        }
    }

    /// The track a player starts with: the default one, else the first.
    public var mainAudio: Audio? { audio.first(where: \.isDefault) ?? audio.first }

    /// "TrueHD Atmos 7.1".
    public var audioLabel: String? {
        guard let audio = mainAudio else { return nil }
        return [audio.codec, audio.atmos ? "Atmos" : nil, audio.channels.map(Self.channelLabel)]
            .compactMap { $0 }.joined(separator: " ")
    }

    static func channelLabel(_ channels: Int) -> String {
        switch channels {
        case 1: "1.0"
        case 2: "2.0"
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        default: "\(channels) ch"
        }
    }

    /// "2:14:05", "42:10".
    public var durationLabel: String? {
        guard let duration, duration.isFinite, duration >= 0.5 else { return nil }
        let total = Int(duration.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }

    /// The column's forms, longest first: all of it, then without the audio,
    /// without the codec, and the picture alone.
    public var forms: [String] {
        let picture = [resolution, hdrLabel].compactMap { $0 }.joined(separator: " ")
        // With no picture size known, the codec leads instead.
        let lead = picture.isEmpty ? codec : picture, format = picture.isEmpty ? nil : codec
        func line(_ parts: String?...) -> String { parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
        return [line(lead, format, audioLabel, durationLabel), line(lead, format, durationLabel), line(lead, durationLabel), line(lead)]
    }

    /// The widest each form gets, so a column shows the same form on every row.
    public static let widestForms = ["2160p HDR10 · HEVC · TrueHD Atmos 7.1 · 2:14:05", "2160p HDR10 · HEVC · 2:14:05",
                                     "2160p HDR10 · 2:14:05", "2160p HDR10"]

    /// "Dolby Vision profile 8.1 (HDR10 compatible)".
    public var hdrDescription: String {
        switch hdr {
        case .hdr10: return "HDR10 (PQ)"
        case .hlg: return "HLG"
        case .dolbyVision(let profile, let compatibility):
            let fallback = switch compatibility {
            case 1, 6: " (HDR10 compatible)"
            case 2: " (SDR compatible)"
            case 4: " (HLG compatible)"
            default: profile == 5 ? " (no fallback)" : ""
            }
            guard profile > 0 else { return "Dolby Vision" }
            return "Dolby Vision profile \(profile)\(compatibility > 0 ? ".\(compatibility)" : "")\(fallback)"
        case nil: return "SDR"
        }
    }

    /// The tooltip: everything known, a line each.
    public var details: String {
        var lines: [String] = []
        let size = [width.flatMap { width in height.map { "\(width) × \($0)\(interlaced ? " interlaced" : "")" } },
                    frameRate.map { Self.frameRateLabel($0) + " fps" }].compactMap { $0 }
        if !size.isEmpty { lines.append(size.joined(separator: " · ")) }
        let format = [codec, profile].compactMap { $0 }.joined(separator: " ")
        if !format.isEmpty { lines.append(format + (bitDepth.map { ", \($0)-bit" } ?? "")) }
        if codec != nil { lines.append(hdrDescription) }
        if let main = mainAudio, let label = audioLabel {
            let others = audio.count - 1
            lines.append("Audio: \(label)\(main.language.map { " (\($0))" } ?? "")"
                         + (others > 0 ? "; \(others) more track\(others == 1 ? "" : "s")" : ""))
        }
        if subtitles > 0 { lines.append("Subtitles: \(subtitles) track\(subtitles == 1 ? "" : "s")") }
        if let durationLabel { lines.append("Duration: \(durationLabel)") }
        return lines.joined(separator: "\n")
    }

    /// "23.976", "25", "59.94".
    static func frameRateLabel(_ rate: Double) -> String {
        let rounded = (rate * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
    }
}
