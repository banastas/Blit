// A video track's decoder configuration: HEVC's hvcC (ISO/IEC 14496-15) gives
// the profile and bit depth, the transfer characteristics in its SPS's VUI
// (where an encode says PQ or HLG though its container doesn't) and whether it
// carries HDR10's mastering-display SEI; H.264's avcC gives the profile.

import Foundation

struct HEVCConfiguration {
    var profileIDC: Int
    var bitDepth: Int
    /// The SPS's transfer_characteristics: 16 PQ, 18 HLG, 1 BT.709, 2 unspecified.
    var transfer: Int?
    var hasMasteringDisplay = false

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 23, bytes[0] == 1 else { return nil }
        profileIDC = Int(bytes[1] & 0x1F)
        bitDepth = Int(bytes[17] & 0x07) + 8
        var offset = 23
        arrays: for _ in 0..<Int(bytes[22]) {
            guard offset + 3 <= bytes.count else { break }
            let type = bytes[offset] & 0x3F
            let count = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            offset += 3
            for _ in 0..<count {
                guard offset + 2 <= bytes.count else { break arrays }
                let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard offset + length <= bytes.count else { break arrays }
                let unit = Array(bytes[offset..<(offset + length)])
                offset += length
                switch type {
                case 33 where transfer == nil: transfer = HEVCParameterSets.transfer(sps: unit)
                case 39, 40: if HEVCParameterSets.hasMasteringDisplay(sei: unit) { hasMasteringDisplay = true }
                default: break
                }
            }
        }
    }

    var profileName: String? {
        switch profileIDC {
        case 1: "Main"
        case 2: "Main 10"
        case 3: "Main Still Picture"
        case 4: "Range Extensions"
        default: nil
        }
    }
}

struct AVCConfiguration {
    var profileIDC: Int
    var bitDepth: Int?

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 7, bytes[0] == 1 else { return nil }
        profileIDC = Int(bytes[1])
        // The High profiles add chroma format and bit depths after the parameter sets.
        var offset = 5
        let spsCount = Int(bytes[offset] & 0x1F)
        offset += 1
        for _ in 0..<spsCount {
            guard offset + 2 <= bytes.count else { return }
            offset += 2 + (Int(bytes[offset]) << 8 | Int(bytes[offset + 1]))
        }
        guard offset < bytes.count else { return }
        let ppsCount = Int(bytes[offset])
        offset += 1
        for _ in 0..<ppsCount {
            guard offset + 2 <= bytes.count else { return }
            offset += 2 + (Int(bytes[offset]) << 8 | Int(bytes[offset + 1]))
        }
        if [100, 110, 122, 144].contains(profileIDC), offset + 2 < bytes.count {
            bitDepth = Int(bytes[offset + 1] & 0x07) + 8
        }
    }

    var profileName: String? {
        switch profileIDC {
        case 66: "Baseline"
        case 77: "Main"
        case 88: "Extended"
        case 100: "High"
        case 110: "High 10"
        case 122: "High 4:2:2"
        case 244: "High 4:4:4"
        default: nil
        }
    }
}

/// HEVC's SPS and SEI, as far as the header readers need (ITU-T H.265 §7.3).
enum HEVCParameterSets {
    struct OutOfBits: Error {}

    /// An RBSP's bits, most significant first.
    struct Bits {
        let bytes: [UInt8]
        var position = 0

        mutating func bit() throws -> Int {
            guard position < bytes.count * 8 else { throw OutOfBits() }
            defer { position += 1 }
            return Int(bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1)
        }

        mutating func bits(_ count: Int) throws -> Int {
            var value = 0
            for _ in 0..<count { value = value << 1 | (try bit()) }
            return value
        }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, position + count <= bytes.count * 8 else { throw OutOfBits() }
            position += count
        }

        /// ue(v): Exp-Golomb.
        mutating func ue() throws -> Int {
            var zeros = 0
            while try bit() == 0 {
                zeros += 1
                guard zeros < 32 else { throw OutOfBits() }
            }
            return (1 << zeros) - 1 + (try bits(zeros))
        }

        /// se(v).
        mutating func se() throws -> Int {
            let code = try ue()
            return code % 2 == 1 ? (code + 1) / 2 : -(code / 2)
        }
    }

    /// A NAL unit's payload without its 2-byte header and emulation-prevention bytes.
    static func rbsp(_ unit: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(unit.count)
        var zeros = 0
        for byte in unit.dropFirst(2) {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// The VUI's transfer_characteristics, if the SPS has them.
    static func transfer(sps unit: [UInt8]) -> Int? {
        var bits = Bits(bytes: rbsp(unit))
        return try? transfer(&bits)
    }

    private static func transfer(_ r: inout Bits) throws -> Int? {
        try r.skip(4)                                  // sps_video_parameter_set_id
        let subLayers = try r.bits(3)                  // sps_max_sub_layers_minus1
        try r.skip(1)                                  // sps_temporal_id_nesting_flag
        // profile_tier_level(1, subLayers): the general profile (88 bits) and level.
        try r.skip(88 + 8)
        var profilePresent: [Bool] = [], levelPresent: [Bool] = []
        for _ in 0..<subLayers {
            profilePresent.append(try r.bit() == 1)
            levelPresent.append(try r.bit() == 1)
        }
        if subLayers > 0 { try r.skip(2 * (8 - subLayers)) }
        for layer in 0..<subLayers {
            if profilePresent[layer] { try r.skip(88) }
            if levelPresent[layer] { try r.skip(8) }
        }
        _ = try r.ue()                                 // sps_seq_parameter_set_id
        if try r.ue() == 3 { try r.skip(1) }           // chroma_format_idc, separate_colour_plane_flag
        _ = try r.ue()                                 // pic_width_in_luma_samples
        _ = try r.ue()                                 // pic_height_in_luma_samples
        if try r.bit() == 1 { for _ in 0..<4 { _ = try r.ue() } }   // conformance window
        _ = try r.ue()                                 // bit_depth_luma_minus8
        _ = try r.ue()                                 // bit_depth_chroma_minus8
        let pocBits = try r.ue() + 4                   // log2_max_pic_order_cnt_lsb_minus4
        let ordering = try r.bit() == 1                // sps_sub_layer_ordering_info_present_flag
        for _ in (ordering ? 0 : subLayers)...subLayers { for _ in 0..<3 { _ = try r.ue() } }
        for _ in 0..<6 { _ = try r.ue() }              // block sizes and transform hierarchy depths
        if try r.bit() == 1, try r.bit() == 1 {        // scaling lists enabled, and sent
            try skipScalingLists(&r)
        }
        try r.skip(2)                                  // amp, sample_adaptive_offset
        if try r.bit() == 1 {                          // pcm_enabled_flag
            try r.skip(8)
            _ = try r.ue()
            _ = try r.ue()
            try r.skip(1)
        }
        let sets = try r.ue()                          // num_short_term_ref_pic_sets
        guard sets <= 64 else { return nil }
        var deltaPocs: [Int] = []
        for index in 0..<sets { deltaPocs.append(try skipShortTermRefPicSet(&r, index: index, counts: deltaPocs)) }
        if try r.bit() == 1 {                          // long_term_ref_pics_present_flag
            let count = try r.ue()
            guard count <= 32 else { return nil }
            try r.skip(count * (pocBits + 1))
        }
        try r.skip(2)                                  // temporal MVP, strong intra smoothing
        guard try r.bit() == 1 else { return nil }     // vui_parameters_present_flag
        if try r.bit() == 1, try r.bits(8) == 255 {    // aspect ratio: idc 255 is an explicit SAR
            try r.skip(32)
        }
        if try r.bit() == 1 { try r.skip(1) }          // overscan
        guard try r.bit() == 1 else { return nil }     // video_signal_type_present_flag
        try r.skip(4)                                  // video_format, video_full_range_flag
        guard try r.bit() == 1 else { return nil }     // colour_description_present_flag
        try r.skip(8)                                  // colour_primaries
        return try r.bits(8)
    }

    private static func skipScalingLists(_ r: inout Bits) throws {
        for size in 0..<4 {
            for _ in stride(from: 0, to: 6, by: size == 3 ? 3 : 1) {
                if try r.bit() == 0 {
                    _ = try r.ue()                     // scaling_list_pred_matrix_id_delta
                } else {
                    if size > 1 { _ = try r.se() }     // scaling_list_dc_coef_minus8
                    for _ in 0..<min(64, 1 << (4 + (size << 1))) { _ = try r.se() }
                }
            }
        }
    }

    /// Skips st_ref_pic_set(index); returns its NumDeltaPocs, which a later
    /// set predicted from it needs.
    private static func skipShortTermRefPicSet(_ r: inout Bits, index: Int, counts: [Int]) throws -> Int {
        if index > 0, try r.bit() == 1 {               // inter_ref_pic_set_prediction_flag
            try r.skip(1)                              // delta_rps_sign
            _ = try r.ue()                             // abs_delta_rps_minus1
            // In an SPS the reference is always the set before (delta_idx_minus1 is 0).
            var count = 0
            for _ in 0...counts[index - 1] {
                var kept = try r.bit() == 1            // used_by_curr_pic_flag
                if !kept { kept = try r.bit() == 1 }   // use_delta_flag
                if kept { count += 1 }
            }
            return count
        }
        let negative = try r.ue(), positive = try r.ue()
        guard negative <= 16, positive <= 16 else { throw OutOfBits() }
        for _ in 0..<(negative + positive) {
            _ = try r.ue()                             // delta_poc_minus1
            try r.skip(1)                              // used_by_curr_pic_flag
        }
        return negative + positive
    }

    /// Whether an SEI unit carries mastering_display_colour_volume (type 137).
    static func hasMasteringDisplay(sei unit: [UInt8]) -> Bool {
        let payload = rbsp(unit)
        var offset = 0
        func number() -> Int? {
            var value = 0
            while offset < payload.count, payload[offset] == 0xFF {
                value += 255
                offset += 1
            }
            guard offset < payload.count else { return nil }
            defer { offset += 1 }
            return value + Int(payload[offset])
        }
        // Each message: its type, its size, its bytes; then the trailing 0x80.
        while offset < payload.count - 1 {
            guard let type = number(), let size = number() else { return false }
            if type == 137 { return true }
            offset += size
        }
        return false
    }
}
