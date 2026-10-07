// The video header readers (PRD R2.6, the Video column). Fixtures, made with
// ffmpeg and cut short where only the header matters:
//   hdr10-vui-head.mkv     x265 HDR10 3840×1600, PQ only in the SPS's VUI, DD+ 5.1
//   hdr10-colour-head.mkv  the same at 3840×2160, audio named "English Atmos"
//   hevc-vt-1080p-head.mkv VideoToolbox HEVC: 4 short-term reference sets, scaling lists
//   hevc-scaling-720p-head.mkv x265 with default scaling lists, BT.709
//   sdr-1080p.mp4, hdr10-2160p.mp4, vp9-720p.webm  whole (tiny) files
// Dolby Vision, TrueHD and the odd layouts are written here as EBML.

import Foundation
import Testing

@testable import BlitMedia

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

private func matroska(_ name: String) throws -> VideoInfo? {
    try Matroska.read(FileSource(url: fixture(name)))
}

// MARK: Writing EBML

private enum EBML {
    static func id(_ id: UInt32) -> Data {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: id >> $0) }
        return Data(bytes.drop { $0 == 0 })
    }

    /// An element, its size written in 8 bytes (or as unknown).
    static func element(_ id: UInt32, _ payload: Data, unknownSize: Bool = false) -> Data {
        var size: [UInt8] = [0x01] + (0..<7).reversed().map { UInt8(truncatingIfNeeded: UInt64(payload.count) >> ($0 * 8)) }
        if unknownSize { size = [0x01] + Array(repeating: 0xFF, count: 7) }
        return self.id(id) + Data(size) + payload
    }

    static func master(_ id: UInt32, unknownSize: Bool = false, _ children: Data...) -> Data {
        element(id, children.reduce(Data(), +), unknownSize: unknownSize)
    }

    static func uint(_ id: UInt32, _ value: UInt64) -> Data {
        let bytes = (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        return element(id, Data(bytes.drop { $0 == 0 }))
    }

    static func string(_ id: UInt32, _ value: String) -> Data { element(id, Data(value.utf8)) }

    static func float(_ id: UInt32, _ value: Double) -> Data {
        let bits = value.bitPattern
        return element(id, Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }))
    }

    static func header(_ docType: String = "matroska") -> Data {
        master(Matroska.ebmlHeader, string(Matroska.docType, docType))
    }

    static func info(seconds: Double) -> Data {
        master(Matroska.info, uint(Matroska.timestampScale, 1_000_000), float(Matroska.duration, seconds * 1000))
    }

    static func videoTrack(codec: String = "V_MPEGH/ISO/HEVC", width: UInt64 = 3840, height: UInt64 = 1608, transfer: UInt64? = nil,
                           interlaced: Bool = false, extra: Data = Data()) -> Data {
        let colour = transfer.map { master(Matroska.colour, uint(Matroska.transferCharacteristics, $0)) } ?? Data()
        return master(Matroska.trackEntry, uint(Matroska.trackType, 1), string(Matroska.codecID, codec),
                      uint(Matroska.defaultDuration, 41_708_333),
                      master(Matroska.video, uint(Matroska.pixelWidth, width), uint(Matroska.pixelHeight, height),
                             uint(Matroska.flagInterlaced, interlaced ? 1 : 2), colour),
                      extra)
    }

    static func audioTrack(_ codec: String, channels: UInt64, name: String? = nil, language: String? = nil, isDefault: Bool? = nil) -> Data {
        master(Matroska.trackEntry, uint(Matroska.trackType, 2), string(Matroska.codecID, codec),
               name.map { string(Matroska.name, $0) } ?? Data(), language.map { string(Matroska.language, $0) } ?? Data(),
               isDefault.map { uint(Matroska.flagDefault, $0 ? 1 : 0) } ?? Data(),
               master(Matroska.audio, uint(Matroska.channels, channels)))
    }

    static func subtitleTrack() -> Data {
        master(Matroska.trackEntry, uint(Matroska.trackType, 17), string(Matroska.codecID, "S_TEXT/UTF8"))
    }

    /// A BlockAdditionMapping with a Dolby Vision configuration record.
    static func dolbyVision(profile: UInt8, compatibility: UInt8) -> Data {
        let record = Data([1, 0, profile << 1, 0x10 | 0x04 | 0x01, compatibility << 4] + Array(repeating: 0, count: 19))
        return master(Matroska.blockAdditionMapping, uint(Matroska.blockAddIDType, 0x6476_7643), element(Matroska.blockAddIDExtraData, record))
    }
}

// MARK: Fixtures

@Suite struct MatroskaFixtureTests {
    @Test func hdr10SignalledOnlyInTheVUI() throws {
        let info = try #require(try matroska("hdr10-vui-head.mkv"))
        #expect(info.codec == "HEVC")
        #expect(info.profile == "Main 10")
        #expect(info.bitDepth == 10)
        #expect(info.width == 3840 && info.height == 1600)
        #expect(info.resolution == "2160p")
        #expect(info.hdr == .hdr10)
        #expect(info.frameRate.map { abs($0 - 23.976) < 0.001 } == true)
        #expect(info.audioLabel == "DD+ 5.1")
        #expect(info.mainAudio?.language == "eng")
        #expect(info.forms.last == "2160p HDR10")
    }

    @Test func atmosFromTheTrackName() throws {
        let info = try #require(try matroska("hdr10-colour-head.mkv"))
        #expect(info.resolution == "2160p")
        #expect(info.hdr == .hdr10)
        #expect(info.audioLabel == "DD+ Atmos 5.1")
    }

    @Test func spsWithReferenceSetsAndScalingLists() throws {
        let info = try #require(try matroska("hevc-vt-1080p-head.mkv"))
        #expect(info.codec == "HEVC" && info.profile == "Main 10")
        #expect(info.resolution == "1080p")
        #expect(info.hdr == nil)
        // The walk through the SPS reached the VUI: VideoToolbox leaves the transfer unspecified.
        #expect(try codecPrivateConfiguration("hevc-vt-1080p-head.mkv")?.transfer == 2)
        #expect(try codecPrivateConfiguration("hevc-scaling-720p-head.mkv")?.transfer == 1)
        #expect(try codecPrivateConfiguration("hdr10-vui-head.mkv")?.transfer == 16)
        #expect(try codecPrivateConfiguration("hdr10-vui-head.mkv")?.hasMasteringDisplay == true)
    }

    @Test func webm() throws {
        let info = try #require(try matroska("vp9-720p.webm"))
        #expect(info.codec == "VP9")
        #expect(info.resolution == "720p")
        #expect(info.audioLabel == "Opus 2.0")
    }

    @Test func mp4Files() async throws {
        let sdr = try #require(await VideoProbe.probe(try fixture("sdr-1080p.mp4")))
        #expect(sdr.codec == "H.264")
        #expect(sdr.resolution == "1080p")
        #expect(sdr.hdr == nil)
        #expect(sdr.audioLabel == "AAC 2.0")
        let hdr = try #require(await VideoProbe.probe(try fixture("hdr10-2160p.mp4")))
        #expect(hdr.codec == "HEVC" && hdr.profile == "Main 10" && hdr.bitDepth == 10)
        #expect(hdr.resolution == "2160p")
        #expect(hdr.hdr == .hdr10)
        #expect(hdr.audioLabel == "DD 5.1")
    }

    @Test func probeByExtension() async throws {
        #expect(VideoProbe.handles(URL(fileURLWithPath: "/x/Movie (2024).MKV")))
        #expect(!VideoProbe.handles(URL(fileURLWithPath: "/x/movie.mkv.blitpart")))
        let info = try #require(await VideoProbe.probe(try fixture("hdr10-vui-head.mkv")))
        #expect(info.hdr == .hdr10)
    }

    /// The first track's CodecPrivate, as an HEVC configuration.
    private func codecPrivateConfiguration(_ name: String) throws -> HEVCConfiguration? {
        let reader = EBMLReader(source: try FileSource(url: fixture(name)))
        var found: Data?
        func search(_ start: UInt64, _ end: UInt64) throws {
            try reader.children(from: start, to: end) { element in
                switch element.id {
                case Matroska.segment, Matroska.tracks, Matroska.trackEntry:
                    try search(element.dataStart, element.dataEnd ?? reader.source.size)
                case Matroska.codecPrivate where found == nil:
                    found = try reader.data(element, limit: 1 << 20)
                default: break
                }
                return found == nil
            }
        }
        try search(0, reader.source.size)
        return found.flatMap(HEVCConfiguration.init)
    }
}

// MARK: Written headers

@Suite struct MatroskaLayoutTests {
    @Test func dolbyVisionWithTrueHDAtmos() throws {
        let file = EBML.header() + EBML.master(Matroska.segment,
            EBML.info(seconds: 8045.3),
            EBML.master(Matroska.tracks,
                        EBML.videoTrack(transfer: 16, extra: EBML.dolbyVision(profile: 8, compatibility: 1)),
                        EBML.audioTrack("A_TRUEHD", channels: 8, name: "TrueHD Atmos 7.1", language: "eng"),
                        EBML.audioTrack("A_AC3", channels: 6, language: "fre"),
                        EBML.subtitleTrack(), EBML.subtitleTrack(), EBML.subtitleTrack()))
        let info = try #require(try Matroska.read(DataSource(file)))
        #expect(info.hdr == .dolbyVision(profile: 8, compatibility: 1))
        #expect(info.forms == ["2160p DV · HEVC · TrueHD Atmos 7.1 · 2:14:05", "2160p DV · HEVC · 2:14:05", "2160p DV · 2:14:05", "2160p DV"])
        #expect(info.subtitles == 3)
        #expect(info.details.contains("Dolby Vision profile 8.1 (HDR10 compatible)"))
        #expect(info.details.contains("Audio: TrueHD Atmos 7.1 (eng); 1 more track"))
        #expect(info.details.contains("Subtitles: 3 tracks"))
    }

    @Test func hlgAndInterlaced() throws {
        let hlg = EBML.header() + EBML.master(Matroska.segment, EBML.master(Matroska.tracks, EBML.videoTrack(transfer: 18)))
        #expect(try Matroska.read(DataSource(hlg))?.hdrLabel == "HLG")
        let tv = EBML.header() + EBML.master(Matroska.segment,
            EBML.master(Matroska.tracks, EBML.videoTrack(codec: "V_MPEG2", width: 1920, height: 1080, interlaced: true)))
        let info = try #require(try Matroska.read(DataSource(tv)))
        #expect(info.resolution == "1080i")
        #expect(info.codec == "MPEG-2")
        #expect(info.hdr == nil)
    }

    @Test func tracksFoundThroughTheSeekHeadAfterTheClusters() throws {
        // SeekHead, Info, a cluster, then Tracks: positions are from the segment's data.
        let info = EBML.info(seconds: 2700)
        let cluster = EBML.master(Matroska.cluster, EBML.uint(0xE7, 0))
        let tracks = EBML.master(Matroska.tracks, EBML.videoTrack(codec: "V_AV1", width: 1920, height: 800))
        func seekHead(_ tracksAt: UInt64) -> Data {
            // The position in 8 bytes, so the head's size doesn't depend on it.
            let position = Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: tracksAt >> ($0 * 8)) })
            return EBML.master(Matroska.seekHead, EBML.master(Matroska.seek, EBML.element(Matroska.seekID, EBML.id(Matroska.tracks)),
                                                              EBML.element(Matroska.seekPosition, position)))
        }
        let headSize = UInt64(seekHead(0).count)
        let file = EBML.header() + EBML.master(Matroska.segment, seekHead(headSize + UInt64(info.count + cluster.count)), info, cluster, tracks)
        let read = try #require(try Matroska.read(DataSource(file)))
        #expect(read.codec == "AV1")
        #expect(read.resolution == "1080p")
        #expect(read.durationLabel == "45:00")
    }

    @Test func unknownSizedSegment() throws {
        let file = EBML.header() + EBML.master(Matroska.segment, unknownSize: true,
                                              EBML.master(Matroska.tracks, EBML.videoTrack(codec: "V_MPEG4/ISO/AVC", width: 1280, height: 720)))
        #expect(try Matroska.read(DataSource(file))?.forms.last == "720p")
    }

    @Test func audioChoicesAndNames() throws {
        let file = EBML.header() + EBML.master(Matroska.segment, EBML.master(Matroska.tracks,
            EBML.videoTrack(),
            EBML.audioTrack("A_DTS", channels: 6, name: "Commentary", language: "und", isDefault: false),
            EBML.audioTrack("A_DTS", channels: 8, name: "DTS-HD MA 7.1", isDefault: true)))
        let info = try #require(try Matroska.read(DataSource(file)))
        #expect(info.audioLabel == "DTS-HD MA 7.1")
        #expect(info.mainAudio?.language == "eng")   // Matroska's default language
        #expect(info.audio.first?.language == nil)   // "und"
    }

    @Test func notMatroskaOrCutShort() throws {
        #expect(try Matroska.read(DataSource(Data("not a video at all".utf8))) == nil)
        #expect(try Matroska.read(DataSource(EBML.header("other") + EBML.master(Matroska.segment))) == nil)
        let whole = EBML.header() + EBML.master(Matroska.segment, EBML.info(seconds: 60),
                                               EBML.master(Matroska.tracks, EBML.videoTrack(), EBML.audioTrack("A_EAC3", channels: 6)))
        // Every cut reads without throwing past the bytes there are.
        for length in stride(from: 0, to: whole.count, by: 7) {
            _ = try Matroska.read(DataSource(whole.prefix(length)))
        }
    }

    @Test func videoForWindowsFourCC() throws {
        var header = Data(count: 40)
        header.replaceSubrange(16..<20, with: Data("XVID".utf8))
        let track = EBML.master(Matroska.trackEntry, EBML.uint(Matroska.trackType, 1), EBML.string(Matroska.codecID, "V_MS/VFW/FOURCC"),
                                EBML.element(Matroska.codecPrivate, header),
                                EBML.master(Matroska.video, EBML.uint(Matroska.pixelWidth, 720), EBML.uint(Matroska.pixelHeight, 576)))
        let info = try #require(try Matroska.read(DataSource(EBML.header() + EBML.master(Matroska.segment, EBML.master(Matroska.tracks, track)))))
        #expect(info.codec == "MPEG-4")
        #expect(info.resolution == "576p")
    }
}

// MARK: HEVC parameter sets

/// Writes an RBSP bit by bit, for parameter sets the encoders here don't make.
private struct BitWriter {
    var bits: [Int] = []

    mutating func put(_ value: Int, _ count: Int) { for shift in (0..<count).reversed() { bits.append(value >> shift & 1) } }

    mutating func ue(_ value: Int) {
        let code = value + 1
        let length = Int.bitWidth - code.leadingZeroBitCount
        put(0, length - 1)
        put(code, length)
    }

    mutating func se(_ value: Int) { ue(value > 0 ? 2 * value - 1 : -2 * value) }

    /// The NAL unit: header, the bits with a stop bit, emulation prevention.
    func unit(type: Int) -> [UInt8] {
        var all = bits + [1]
        while all.count % 8 != 0 { all.append(0) }
        let rbsp = stride(from: 0, to: all.count, by: 8).map { start in all[start..<(start + 8)].reduce(0) { UInt8($0 << 1) | UInt8($1) } }
        var out: [UInt8] = [UInt8(type << 1), 1]
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}

@Suite struct HEVCParameterSetTests {
    /// An SPS through every branch the reader steps over, ending in a VUI with HLG.
    private func sps(vui: Bool) -> [UInt8] {
        var w = BitWriter()
        w.put(0, 4); w.put(1, 3); w.put(1, 1)          // VPS 0, two sub-layers, nesting
        w.put(2, 8); w.put(0x6000_0000, 32); w.put(0, 48); w.put(150, 8)   // general profile (Main 10), level 5
        w.put(1, 1); w.put(1, 1)                       // sub-layer 0: profile and level present
        w.put(0, 2 * 7)                                // reserved, for the other 7 slots
        w.put(0, 88); w.put(120, 8)                    // sub-layer 0's profile and level
        w.ue(0); w.ue(1)                               // SPS 0, 4:2:0
        w.ue(3840); w.ue(2160)
        w.put(1, 1); w.ue(0); w.ue(0); w.ue(0); w.ue(4)   // conformance window
        w.ue(2); w.ue(2)                               // 10-bit
        w.ue(4)                                        // POC LSBs: 8 bits
        w.put(0, 1); w.ue(4); w.ue(2); w.ue(5)         // ordering info for the top layer only
        for value in [0, 3, 0, 3, 1, 1] { w.ue(value) }
        w.put(1, 1); w.put(1, 1)                       // scaling lists, sent:
        for size in 0..<4 {
            for matrix in stride(from: 0, to: 6, by: size == 3 ? 3 : 1) {
                if matrix % 2 == 0 {
                    w.put(1, 1)
                    if size > 1 { w.se(-3) }
                    for index in 0..<min(64, 1 << (4 + (size << 1))) { w.se(index % 3 - 1) }
                } else {
                    w.put(0, 1); w.ue(1)
                }
            }
        }
        w.put(1, 1); w.put(1, 1)                       // AMP, SAO
        w.put(1, 1); w.put(0x77, 8); w.ue(0); w.ue(1); w.put(1, 1)   // PCM
        w.ue(3)                                        // three short-term reference sets:
        w.ue(2); w.ue(1)                               // 0: two before, one after
        for delta in [0, 1, 0] { w.ue(delta); w.put(1, 1) }
        w.put(1, 1); w.put(0, 1); w.ue(0)              // 1: predicted from 0 (4 entries)
        w.put(1, 1); w.put(0, 1); w.put(1, 1); w.put(0, 1); w.put(0, 1); w.put(1, 1)   // keeps 3
        w.put(1, 1); w.put(1, 1); w.ue(1)              // 2: predicted from 1 (4 entries)
        for _ in 0..<4 { w.put(1, 1) }
        w.put(1, 1); w.ue(2)                           // two long-term pictures
        for _ in 0..<2 { w.put(0xAB, 8); w.put(1, 1) }
        w.put(1, 1); w.put(1, 1)                       // temporal MVP, strong intra smoothing
        w.put(vui ? 1 : 0, 1)
        if vui {
            w.put(1, 1); w.put(255, 8); w.put(1, 16); w.put(1, 16)   // explicit SAR
            w.put(1, 1); w.put(0, 1)                   // overscan
            w.put(1, 1); w.put(5, 3); w.put(0, 1)      // video signal type
            w.put(1, 1); w.put(9, 8); w.put(18, 8); w.put(9, 8)      // BT.2020, HLG, BT.2020 NCL
        }
        return w.unit(type: 33)
    }

    @Test func walksToTheVUI() {
        #expect(HEVCParameterSets.transfer(sps: sps(vui: true)) == 18)
        #expect(HEVCParameterSets.transfer(sps: sps(vui: false)) == nil)
        // Cut anywhere: no answer, no crash.
        let whole = sps(vui: true)
        for length in 0..<whole.count { _ = HEVCParameterSets.transfer(sps: Array(whole.prefix(length))) }
    }

    @Test func masteringDisplayWithoutVUIMeansHDR10() throws {
        var sei = BitWriter()
        sei.put(5, 8); sei.put(2, 8); sei.put(0xABCD, 16)   // user data unregistered, 2 bytes
        sei.put(137, 8); sei.put(24, 8); sei.put(0, 24 * 8) // mastering display, 24 bytes
        let units = [sps(vui: false), sei.unit(type: 39)]
        var hvcC: [UInt8] = [1, 2, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 150, 0xF0, 0, 0xFC, 0xFD, 0xFA, 0xFA, 0, 0, 0x0F, UInt8(units.count)]
        for (type, unit) in zip([33, 39], units) {
            hvcC += [UInt8(0x80 | type), 0, 1, UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)] + unit
        }
        let configuration = try #require(HEVCConfiguration(Data(hvcC)))
        #expect(configuration.transfer == nil)
        #expect(configuration.hasMasteringDisplay)
        #expect(configuration.bitDepth == 10)
        let track = EBML.master(Matroska.trackEntry, EBML.uint(Matroska.trackType, 1), EBML.string(Matroska.codecID, "V_MPEGH/ISO/HEVC"),
                                EBML.element(Matroska.codecPrivate, Data(hvcC)),
                                EBML.master(Matroska.video, EBML.uint(Matroska.pixelWidth, 3840), EBML.uint(Matroska.pixelHeight, 2160)))
        let info = try #require(try Matroska.read(DataSource(EBML.header() + EBML.master(Matroska.segment, EBML.master(Matroska.tracks, track)))))
        #expect(info.hdr == .hdr10)
    }
}

// MARK: Labels

@Suite struct VideoInfoLabelTests {
    @Test func resolutionsByWidthOrHeight() {
        func label(_ width: Int, _ height: Int) -> String? {
            var info = VideoInfo()
            info.width = width
            info.height = height
            return info.resolution
        }
        #expect(label(3840, 1600) == "2160p")
        #expect(label(4096, 1716) == "2160p")
        #expect(label(1920, 800) == "1080p")
        #expect(label(1440, 1080) == "1080p")
        #expect(label(1280, 534) == "720p")
        #expect(label(720, 576) == "576p")
        #expect(label(640, 360) == "360p")
        #expect(label(7680, 4320) == "4320p")
    }

    @Test func durationsAndRates() {
        var info = VideoInfo()
        info.duration = 2580.4
        #expect(info.durationLabel == "43:00")
        info.duration = 0.2
        #expect(info.durationLabel == nil)
        #expect(VideoInfo.frameRateLabel(24000.0 / 1001) == "23.976")
        #expect(VideoInfo.frameRateLabel(25) == "25")
        #expect(VideoInfo.frameRateLabel(60000.0 / 1001) == "59.94")
    }

    @Test func formsWithLittleKnown() {
        var info = VideoInfo()
        info.codec = "VC-1"
        #expect(info.forms == ["VC-1", "VC-1", "VC-1", "VC-1"])
    }
}
