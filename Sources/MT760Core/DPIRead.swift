import Foundation

public enum DPIReadError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public struct DPISnapshot: Codable, Equatable {
    /// All seven storage slots. Only activeCount slots are currently enabled.
    public let levels: [Int]
    public let activeCount: Int
    /// Protocol/model gear numbering is 1-based, not a Swift array index.
    public let currentGear: Int
    public var currentDPI: Int { levels[currentGear - 1] }

    private init(levels: [Int], activeCount: Int, currentGear: Int) {
        self.levels = levels; self.activeCount = activeCount; self.currentGear = currentGear
    }

    private enum CodingKeys: String, CodingKey { case levels, activeCount, currentGear }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let levels = try values.decode([Int].self, forKey: .levels)
        let count = try values.decode(Int.self, forKey: .activeCount)
        let gear = try values.decode(Int.self, forKey: .currentGear)
        guard levels.count == 7, (1...7).contains(count), (1...count).contains(gear),
              levels.prefix(count).allSatisfy({ (50...4000).contains($0) && $0 % 50 == 0 }) else {
            throw DPIReadError.invalid(L("读取结果 JSON 的 DPI 模型无效。", "Invalid DPI model in the read result JSON."))
        }
        self.init(levels: levels, activeCount: count, currentGear: gear)
    }

    /// This version deliberately accepts only the observed 28-byte API response.
    /// Does not remove a Report ID or guess a shifted offset. Not a general HID parser.
    public static func decode(_ response: [UInt8]) throws -> Self {
        guard response.count == 28 else {
            throw DPIReadError.invalid(L("响应长度为 \(response.count)，当前测试版仅接受已观察到的 28 字节；未尝试剥头或补零。", "Response length is \(response.count); this version accepts only the observed 28 bytes. No header stripping or zero padding was attempted."))
        }
        guard response[0] == 1 else {
            throw DPIReadError.invalid(response[0] == 2 ? L("设备忙；本版不轮询或重试。", "Device busy; this version does not poll or retry.") : L("响应状态未知：\(hex(UInt32(response[0])))。", "Unknown response status: \(hex(UInt32(response[0])))."))
        }
        let count = Int(response[18]) + 1
        let gear = Int(response[20]) + 1
        guard (1...7).contains(count), (1...count).contains(gear) else {
            throw DPIReadError.invalid(L("响应中的档位数量或当前档位无效。", "Invalid level count or current level in the response."))
        }
        let levels = (0..<7).map { i in
            (Int(response[4 + i * 2]) | (Int(response[5 + i * 2]) << 8)) * 50
        }
        guard levels.prefix(count).allSatisfy({ (50...4000).contains($0) && $0 % 50 == 0 }) else {
            throw DPIReadError.invalid(L("有效档位超出已观察的 MT760 范围 50–4000 DPI。", "Enabled levels are outside the observed MT760 range of 50–4000 DPI."))
        }
        return Self(levels: levels, activeCount: count, currentGear: gear)
    }
}

public enum MT760WarmRead {
    /// One allowlisted read request. There is intentionally no arbitrary command API.
    public static let request: [UInt8] = [0xBA, 0xFF, 0xA4, 0x18, 0x38, 0x06, 0x00, 0x00]
    public static let reportID = 0xBA
    public static let inputCapacity = 32
}

public struct DPIReadOutcome: Codable {
    public var schemaVersion = 1
    public var completedAt = Date()
    public let registryID: String
    public var request = MT760WarmRead.request
    public var response: [UInt8] = []
    public var outputIOReturn: Int32?
    public var inputIOReturn: Int32?
    public var inputActualLength: Int?
    public var snapshot: DPISnapshot?
    public var error: String?
    public var configurationWritten = false
    public var coldStartVerified = false
    public var scope = "Single explicit MT760 V0.1.4.4 warm-read experiment; no configuration writes, retries, or automatic initialization."

    public init(registryID: String) { self.registryID = registryID }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
