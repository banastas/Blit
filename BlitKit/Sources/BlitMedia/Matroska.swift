// A Matroska file's header (MKV, WebM), read up to the first cluster: the
// segment's Info (duration) and Tracks (codecs, picture size, colour, Dolby
// Vision mapping, audio), found in order or through the SeekHead. An HEVC
// track's own configuration fills in what the container leaves out (HEVC.swift).

import Foundation

/// An EBML element: its ID (with the length marker, as the spec writes IDs),
/// where its data starts, and its size (nil: unknown, to the parent's end).
struct EBMLElement {
    let id: UInt32
    let dataStart: UInt64
    let size: UInt64?

    var dataEnd: UInt64? { size.map { dataStart + $0 } }
}

struct EBMLReader {
    let source: ByteSource

    func element(at offset: UInt64) throws -> EBMLElement? {
        let head = [UInt8](try source.read(at: offset, count: 12))
        guard let first = head.first, first != 0 else { return nil }
        let idLength = first.leadingZeroBitCount + 1
        guard idLength <= 4, head.count > idLength else { return nil }
        let id = head[0..<idLength].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let sizeByte = head[idLength]
        guard sizeByte != 0 else { return nil }
        let sizeLength = sizeByte.leadingZeroBitCount + 1
        guard head.count >= idLength + sizeLength else { return nil }
        let mask: UInt8 = 0xFF >> sizeLength
        var size = UInt64(sizeByte & mask)
        // All value bits set: the size is unknown.
        var unknown = sizeByte & mask == mask
        for byte in head[(idLength + 1)..<(idLength + sizeLength)] {
            size = size << 8 | UInt64(byte)
            if byte != 0xFF { unknown = false }
        }
        return EBMLElement(id: id, dataStart: offset + UInt64(idLength + sizeLength), size: unknown ? nil : size)
    }

    /// The elements from `start` to `end`, in order, until `body` returns false.
    func children(from start: UInt64, to end: UInt64, _ body: (EBMLElement) throws -> Bool) throws {
        var offset = start
        while offset < min(end, source.size) {
            guard let child = try element(at: offset), try body(child), let size = child.size else { return }
            offset = child.dataStart + size
        }
    }

    func children(of element: EBMLElement, _ body: (EBMLElement) throws -> Bool) throws {
        try children(from: element.dataStart, to: element.dataEnd ?? source.size, body)
    }

    func data(_ element: EBMLElement, limit: Int) throws -> Data? {
        guard let size = element.size, size <= UInt64(limit) else { return nil }
        let data = try source.read(at: element.dataStart, count: Int(size))
        return data.count == Int(size) ? data : nil
    }

    func uint(_ element: EBMLElement) throws -> UInt64? {
        try data(element, limit: 8).map { $0.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
    }

    func float(_ element: EBMLElement) throws -> Double? {
        guard let data = try data(element, limit: 8) else { return nil }
        let bits = data.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        switch data.count {
        case 4: return Double(Float(bitPattern: UInt32(bits)))
        case 8: return Double(bitPattern: bits)
        case 0: return 0
        default: return nil
        }
    }

    func string(_ element: EBMLElement) throws -> String? {
        guard var data = try data(element, limit: 4096) else { return nil }
        while data.last == 0 { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum Matroska {
    // Element IDs (Matroska specification, RFC 9559).
    static let ebmlHeader: UInt32 = 0x1A45DFA3, docType: UInt32 = 0x4282
    static let segment: UInt32 = 0x18538067, cluster: UInt32 = 0x1F43B675
    static let seekHead: UInt32 = 0x114D9B74, seek: UInt32 = 0x4DBB, seekID: UInt32 = 0x53AB, seekPosition: UInt32 = 0x53AC
    static let info: UInt32 = 0x1549A966, timestampScale: UInt32 = 0x2AD7B1, duration: UInt32 = 0x4489
    static let tracks: UInt32 = 0x1654AE6B, trackEntry: UInt32 = 0xAE
    static let trackType: UInt32 = 0x83, codecID: UInt32 = 0x86, codecPrivate: UInt32 = 0x63A2, name: UInt32 = 0x536E
    static let language: UInt32 = 0x22B59C, languageBCP47: UInt32 = 0x22B59D, flagDefault: UInt32 = 0x88
    static let defaultDuration: UInt32 = 0x23E383
    static let video: UInt32 = 0xE0, pixelWidth: UInt32 = 0xB0, pixelHeight: UInt32 = 0xBA, flagInterlaced: UInt32 = 0x9A
    static let colour: UInt32 = 0x55B0, transferCharacteristics: UInt32 = 0x55BA, bitsPerChannel: UInt32 = 0x55B2
    static let audio: UInt32 = 0xE1, channels: UInt32 = 0x9F
    static let blockAdditionMapping: UInt32 = 0x41E4, blockAddIDType: UInt32 = 0x41E7, blockAddIDExtraData: UInt32 = 0x41ED

    /// Dolby Vision configuration records, as BlockAddIDType values.
    static let dolbyVisionTypes: Set<UInt64> = [0x6476_6343, 0x6476_7643, 0x6476_7743]   // dvcC, dvvC, dvwC

    /// What `source`'s header says; nil if it isn't Matroska or has no tracks.
    public static func read(_ source: ByteSource) throws -> VideoInfo? {
        let reader = EBMLReader(source: source)
        guard let header = try reader.element(at: 0), header.id == ebmlHeader, let headerEnd = header.dataEnd else { return nil }
        var kind = "matroska"
        try reader.children(of: header) { element in
            if element.id == docType { kind = try reader.string(element) ?? kind }
            return true
        }
        guard kind == "matroska" || kind == "webm",
              let segment = try reader.element(at: headerEnd), segment.id == Self.segment else { return nil }
        var infoElement: EBMLElement?, tracksElement: EBMLElement?
        var seeks: [UInt32: UInt64] = [:]
        try reader.children(of: segment) { element in
            switch element.id {
            case seekHead: try readSeeks(element, reader, into: &seeks)
            case info: infoElement = element
            case tracks: tracksElement = element
            case cluster: return false
            default: break
            }
            return infoElement == nil || tracksElement == nil
        }
        // After the clusters (or past an element too large to step over): where the SeekHead says.
        func sought(_ id: UInt32) throws -> EBMLElement? {
            // The position is the file's own claim: an offset past the end (or one
            // that overflows) means the element isn't there.
            guard let position = seeks[id] else { return nil }
            let (offset, overflow) = segment.dataStart.addingReportingOverflow(position)
            guard !overflow, offset < source.size, let element = try reader.element(at: offset), element.id == id else { return nil }
            return element
        }
        if tracksElement == nil { tracksElement = try sought(tracks) }
        if infoElement == nil { infoElement = try sought(info) }
        guard let tracksElement else { return nil }
        var result = VideoInfo()
        if let infoElement { result.duration = try readDuration(infoElement, reader) }
        try readTracks(tracksElement, reader, into: &result)
        return result.codec == nil && result.audio.isEmpty ? nil : result
    }

    private static func readSeeks(_ head: EBMLElement, _ reader: EBMLReader, into seeks: inout [UInt32: UInt64]) throws {
        try reader.children(of: head) { seek in
            guard seek.id == Self.seek else { return true }
            var id: UInt32?, position: UInt64?
            try reader.children(of: seek) { field in
                switch field.id {
                case seekID: id = try reader.data(field, limit: 4).map { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
                case seekPosition: position = try reader.uint(field)
                default: break
                }
                return true
            }
            if let id, let position, seeks[id] == nil { seeks[id] = position }
            return true
        }
    }

    private static func readDuration(_ info: EBMLElement, _ reader: EBMLReader) throws -> Double? {
        var scale: UInt64 = 1_000_000, duration: Double?
        try reader.children(of: info) { field in
            switch field.id {
            case timestampScale: scale = try reader.uint(field) ?? scale
            case Self.duration: duration = try reader.float(field)
            default: break
            }
            return true
        }
        return duration.map { $0 * Double(scale) / 1_000_000_000 }
    }

    /// One TrackEntry, as read.
    private struct Track {
        var type: UInt64 = 0
        var codecID = ""
        var codecPrivate: Data?
        var name: String?
        var language = "eng"   // the spec's default
        var languageBCP47: String?
        var isDefault = true
        var defaultDuration: UInt64?
        var width: Int?
        var height: Int?
        var interlaced = false
        var transfer: Int?
        var bitsPerChannel: Int?
        var channels: Int?
        var dolbyVision: (profile: Int, compatibility: Int)?
    }

    private static func readTracks(_ tracks: EBMLElement, _ reader: EBMLReader, into result: inout VideoInfo) throws {
        var entries: [Track] = []
        try reader.children(of: tracks) { entry in
            if entry.id == trackEntry { entries.append(try readTrack(entry, reader)) }
            return true
        }
        let videos = entries.filter { $0.type == 1 }
        if let video = videos.first {
            result.width = video.width
            result.height = video.height
            result.interlaced = video.interlaced
            result.frameRate = video.defaultDuration.flatMap { $0 > 0 ? 1_000_000_000 / Double($0) : nil }
            result.bitDepth = video.bitsPerChannel.flatMap { $0 > 0 ? $0 : nil }
            var vuiTransfer: Int?, masteringDisplay = false
            switch video.codecID {
            case "V_MPEGH/ISO/HEVC":
                result.codec = "HEVC"
                if let configuration = video.codecPrivate.flatMap(HEVCConfiguration.init) {
                    result.profile = configuration.profileName
                    result.bitDepth = configuration.bitDepth
                    vuiTransfer = configuration.transfer
                    masteringDisplay = configuration.hasMasteringDisplay
                }
            case "V_MPEG4/ISO/AVC":
                result.codec = "H.264"
                if let configuration = video.codecPrivate.flatMap(AVCConfiguration.init) {
                    result.profile = configuration.profileName
                    result.bitDepth = configuration.bitDepth ?? result.bitDepth
                }
            default:
                result.codec = codecName(video.codecID, codecPrivate: video.codecPrivate)
            }
            // Dolby Vision's mapping can sit on an enhancement-layer track.
            if let dolbyVision = videos.lazy.compactMap(\.dolbyVision).first {
                result.hdr = .dolbyVision(profile: dolbyVision.profile, compatibility: dolbyVision.compatibility)
            } else {
                // The container's colour first, unless it leaves the transfer unspecified (2).
                let transfer = [video.transfer, vuiTransfer].compactMap { $0 }.first { $0 != 0 && $0 != 2 }
                switch transfer {
                case 16: result.hdr = .hdr10
                case 18: result.hdr = .hlg
                case nil where masteringDisplay: result.hdr = .hdr10
                default: break
                }
            }
        }
        for track in entries where track.type == 2 {
            result.audio.append(audioTrack(track))
        }
        // A file whose tracks all say "not default" plays its first audio track.
        if !result.audio.isEmpty, !result.audio.contains(where: \.isDefault) { result.audio[0].isDefault = true }
        result.subtitles = entries.filter { $0.type == 17 }.count
    }

    private static func readTrack(_ entry: EBMLElement, _ reader: EBMLReader) throws -> Track {
        var track = Track()
        try reader.children(of: entry) { field in
            switch field.id {
            case trackType: track.type = try reader.uint(field) ?? 0
            case codecID: track.codecID = try reader.string(field) ?? ""
            case codecPrivate: track.codecPrivate = try reader.data(field, limit: 1 << 20)
            case name: track.name = try reader.string(field)
            case language: track.language = try reader.string(field) ?? track.language
            case languageBCP47: track.languageBCP47 = try reader.string(field)
            case flagDefault: track.isDefault = try reader.uint(field) != 0
            case defaultDuration: track.defaultDuration = try reader.uint(field)
            case video:
                try reader.children(of: field) { video in
                    switch video.id {
                    case pixelWidth: track.width = try reader.uint(video).map { Int(clamping: $0) }
                    case pixelHeight: track.height = try reader.uint(video).map { Int(clamping: $0) }
                    case flagInterlaced: track.interlaced = try reader.uint(video) == 1
                    case colour:
                        try reader.children(of: video) { colour in
                            switch colour.id {
                            case transferCharacteristics: track.transfer = try reader.uint(colour).map { Int(clamping: $0) }
                            case bitsPerChannel: track.bitsPerChannel = try reader.uint(colour).map { Int(clamping: $0) }
                            default: break
                            }
                            return true
                        }
                    default: break
                    }
                    return true
                }
            case audio:
                try reader.children(of: field) { audio in
                    if audio.id == channels { track.channels = try reader.uint(audio).map { Int(clamping: $0) } }
                    return true
                }
            case blockAdditionMapping:
                var type: UInt64?, extra: Data?
                try reader.children(of: field) { mapping in
                    switch mapping.id {
                    case blockAddIDType: type = try reader.uint(mapping)
                    case blockAddIDExtraData: extra = try reader.data(mapping, limit: 256)
                    default: break
                    }
                    return true
                }
                if let type, dolbyVisionTypes.contains(type), let extra, extra.count >= 5 {
                    let bytes = [UInt8](extra)
                    // DOVIDecoderConfigurationRecord: version (2 bytes), then
                    // profile (7 bits), level, flags; the compatibility id leads byte 4.
                    track.dolbyVision = (Int(bytes[2] >> 1), Int(bytes[4] >> 4))
                }
            default: break
            }
            return true
        }
        return track
    }

    /// The name the column shows for a video CodecID that isn't HEVC or H.264.
    static func codecName(_ id: String, codecPrivate: Data?) -> String {
        switch id {
        case "V_AV1": return "AV1"
        case "V_VP9": return "VP9"
        case "V_VP8": return "VP8"
        case "V_MPEG2": return "MPEG-2"
        case "V_MPEG1": return "MPEG-1"
        case "V_MPEGI/ISO/VVC": return "VVC"
        case "V_PRORES": return "ProRes"
        case "V_THEORA": return "Theora"
        case "V_MS/VFW/FOURCC":
            // A BITMAPINFOHEADER: the compression FourCC at byte 16.
            guard let codecPrivate, codecPrivate.count >= 20 else { return "VfW" }
            let start = codecPrivate.startIndex + 16
            let fourCC = String(decoding: codecPrivate[start..<(start + 4)], as: UTF8.self).uppercased()
            switch fourCC {
            case "WVC1", "WMV3": return "VC-1"
            case "XVID", "DIVX", "DX50", "FMP4", "MP4V": return "MPEG-4"
            case "H264", "AVC1", "X264": return "H.264"
            default: return fourCC.trimmingCharacters(in: .whitespaces)
            }
        default:
            if id.hasPrefix("V_MPEG4/ISO/") { return "MPEG-4" }
            return id.hasPrefix("V_") ? String(id.dropFirst(2)) : id
        }
    }

    private static func audioTrack(_ track: Track) -> VideoInfo.Audio {
        let name = track.name ?? ""
        func named(_ words: String...) -> Bool { words.contains { name.localizedCaseInsensitiveContains($0) } }
        var codec: String
        switch track.codecID {
        case "A_TRUEHD": codec = "TrueHD"
        case "A_MLP": codec = "MLP"
        case "A_EAC3": codec = "DD+"
        case "A_AC3", "A_AC3/BSID9", "A_AC3/BSID10": codec = "DD"
        case "A_DTS/EXPRESS": codec = "DTS Express"
        case "A_DTS/LOSSLESS": codec = "DTS-HD MA"
        case "A_DTS":
            // Which DTS is in the frames, not the header; track names usually say.
            codec = named("DTS:X", "DTS-X") ? "DTS:X" : named("DTS-HD MA", "DTS-HD Master", "DTS-MA") ? "DTS-HD MA"
                : named("DTS-HD HRA", "High Res") ? "DTS-HD HRA" : "DTS"
        case "A_OPUS": codec = "Opus"
        case "A_VORBIS": codec = "Vorbis"
        case "A_FLAC": codec = "FLAC"
        case "A_ALAC": codec = "ALAC"
        case "A_MPEG/L3": codec = "MP3"
        case "A_MPEG/L2": codec = "MP2"
        default:
            if track.codecID.hasPrefix("A_AAC") { codec = "AAC" }
            else if track.codecID.hasPrefix("A_PCM") { codec = "PCM" }
            else { codec = track.codecID.hasPrefix("A_") ? String(track.codecID.dropFirst(2)) : track.codecID }
        }
        // Atmos rides in TrueHD and DD+ frames; the header can't tell, the name can.
        let atmos = (codec == "TrueHD" || codec == "DD+") && named("Atmos")
        let language = track.languageBCP47 ?? track.language
        return VideoInfo.Audio(codec: codec, channels: track.channels, atmos: atmos,
                               language: language == "und" || language.isEmpty ? nil : language, isDefault: track.isDefault)
    }
}
