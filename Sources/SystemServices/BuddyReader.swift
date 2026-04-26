import Combine
import Foundation
import SwiftUI

// MARK: - Color hex extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        default:
            r = 1; g = 1; b = 1
        }
        self.init(red: r, green: g, blue: b)
    }

    // MARK: - System Colors

    /// 系统绿色 (iOS/macOS 风格)
    static let systemGreen = Color(hex: "34C759")

    /// 系统红色 (iOS/macOS 风格)
    static let systemRed = Color(hex: "FF3B30")

    /// 系统蓝色 (iOS/macOS 风格)
    static let systemBlue = Color(hex: "007AFF")

    /// 系统橙色 (iOS/macOS 风格)
    static let systemOrange = Color(hex: "FF9500")
}

// MARK: - Buddy Types

public enum BuddyRarity: String, Sendable {
    case common, uncommon, rare, epic, legendary
    var displayName: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .common: return Color(hex: "9CA3AF")
        case .uncommon: return Color(hex: "4ADE80")
        case .rare: return Color(hex: "60A5FA")
        case .epic: return Color(hex: "A78BFA")
        case .legendary: return Color(hex: "FBBF24")
        }
    }
    var stars: String {
        switch self {
        case .common: return "★"
        case .uncommon: return "★★"
        case .rare: return "★★★"
        case .epic: return "★★★★"
        case .legendary: return "★★★★★"
        }
    }
}

public struct BuddyStats: Sendable {
    public let debugging: Int
    public let patience: Int
    public let chaos: Int
    public let wisdom: Int
    public let snark: Int
}

public enum BuddySpecies: String, CaseIterable, Sendable {
    case duck, goose, blob, cat, dragon, octopus, owl, penguin, turtle, snail
    case ghost, axolotl, capybara, cactus, robot, rabbit, mushroom, chonk
    case unknown

    public var emoji: String {
        switch self {
        case .duck: return "🦆"
        case .goose: return "🪿"
        case .cat: return "🐱"
        case .rabbit: return "🐰"
        case .owl: return "🦉"
        case .penguin: return "🐧"
        case .turtle: return "🐢"
        case .snail: return "🐌"
        case .dragon: return "🐉"
        case .octopus: return "🐙"
        case .axolotl: return "🦎"
        case .ghost: return "👻"
        case .robot: return "🤖"
        case .blob: return "🫧"
        case .cactus: return "🌵"
        case .mushroom: return "🍄"
        case .chonk: return "🐈"
        case .capybara: return "🦫"
        case .unknown: return "🐾"
        }
    }
}

public struct BuddyInfo: Sendable {
    public let name: String
    public let personality: String
    public let species: BuddySpecies
    public let rarity: BuddyRarity
    public let stats: BuddyStats
    public let eye: String
    public let hat: String
    public let isShiny: Bool
    public let hatchedAt: Date?
}

// MARK: - Buddy Reader

public class BuddyReader: ObservableObject {
    public static let shared = BuddyReader()

    @Published public var buddy: BuddyInfo?

    private init() {
        reload()
    }

    public func reload() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let companion = json["companion"] as? [String: Any],
              let name = companion["name"] as? String,
              let personality = companion["personality"] as? String else {
            buddy = nil
            return
        }

        let hatchedAt: Date? = (companion["hatchedAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000.0)
        }

        // Get userId for deterministic bones computation
        let userId: String
        if let oauth = json["oauthAccount"] as? [String: Any],
           let uuid = oauth["accountUuid"] as? String {
            userId = uuid
        } else if let uid = json["userID"] as? String {
            userId = uid
        } else {
            userId = "anon"
        }

        // Use Swift wyhash (matches native Claude Code install)
        let salt = Self.readSalt()
        let bones = Self.computeBonesWyhash(userId: userId, salt: salt)

        buddy = BuddyInfo(
            name: name,
            personality: personality,
            species: bones.species,
            rarity: bones.rarity,
            stats: bones.stats,
            eye: bones.eye,
            hat: bones.hat,
            isShiny: bones.isShiny,
            hatchedAt: hatchedAt
        )
    }

    // MARK: - Salt Detection

    private static let originalSalt = "friend-2026-401"

    private static func readSalt() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // 1. Check cached salt file
        let cachePath = "\(home)/.claude/.meee2-salt"
        if let cached = try? String(contentsOfFile: cachePath, encoding: .utf8),
           cached.count == originalSalt.count,
           cached.allSatisfy({ $0.isASCII && !$0.isNewline }) {
            return cached
        }

        // 2. Scan Claude binaries for patched salt
        let versionsDir = "\(home)/.local/share/claude/versions"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: versionsDir) else {
            return originalSalt
        }

        let binaries = versions
            .filter { !$0.contains(".bak") && !$0.contains(".anybuddy") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }

        let origBytes = Data(originalSalt.utf8)

        for binary in binaries {
            let binaryPath = "\(versionsDir)/\(binary)"

            guard let binaryData = try? Data(contentsOf: URL(fileURLWithPath: binaryPath), options: .mappedIfSafe) else { continue }

            if binaryData.range(of: origBytes) != nil {
                return originalSalt
            }

            // Patched — extract from backup
            for suffix in [".anybuddy-bak", ".bak"] {
                let bakPath = binaryPath + suffix
                guard FileManager.default.fileExists(atPath: bakPath),
                      let bakData = try? Data(contentsOf: URL(fileURLWithPath: bakPath), options: .mappedIfSafe),
                      let range = bakData.range(of: origBytes) else { continue }
                let offset = range.lowerBound
                let end = offset + origBytes.count
                guard end <= binaryData.count else { continue }
                let patchedBytes = binaryData[offset..<end]
                if let salt = String(data: Data(patchedBytes), encoding: .utf8),
                   salt.count == originalSalt.count,
                   salt.allSatisfy({ $0.isASCII && !$0.isNewline }) {
                    try? salt.write(toFile: cachePath, atomically: true, encoding: .utf8)
                    return salt
                }
            }
        }

        return originalSalt
    }

    // MARK: - Bones Computation

    private struct Bones {
        let species: BuddySpecies
        let rarity: BuddyRarity
        let stats: BuddyStats
        let eye: String
        let hat: String
        let isShiny: Bool
    }

    /// Mulberry32 PRNG — same as Claude Code's implementation
    private struct Mulberry32 {
        var state: UInt32

        init(seed: UInt32) {
            self.state = seed
        }

        mutating func next() -> Double {
            state &+= 0x6D2B79F5
            var t = state
            t = (t ^ (t >> 15)) &* (t | 1)
            t = (t &+ ((t ^ (t >> 7)) &* (t | 61))) ^ t
            let result = (t ^ (t >> 14))
            return Double(result) / 4294967296.0
        }
    }

    private static func computeBonesWyhash(userId: String, salt: String) -> Bones {
        let key = userId + salt
        let hash = WyHash.hash(key)
        let seed = UInt32(hash & 0xFFFFFFFF)
        return rollBones(seed: seed)
    }

    private static func rollBones(seed: UInt32) -> Bones {
        var rng = Mulberry32(seed: seed)

        // Rarity FIRST (must match Claude Code's rollFrom order)
        let rarityWeights: [(BuddyRarity, Int)] = [(.common, 60), (.uncommon, 25), (.rare, 10), (.epic, 4), (.legendary, 1)]
        var roll = rng.next() * 100.0
        var rarity: BuddyRarity = .common
        for (r, w) in rarityWeights {
            roll -= Double(w)
            if roll < 0 { rarity = r; break }
        }

        // Species SECOND
        let speciesAll: [BuddySpecies] = [.duck, .goose, .blob, .cat, .dragon, .octopus, .owl, .penguin, .turtle, .snail, .ghost, .axolotl, .capybara, .cactus, .robot, .rabbit, .mushroom, .chonk]
        let species = speciesAll[Int(floor(rng.next() * Double(speciesAll.count)))]

        // Eye
        let eyes = ["·", "✦", "×", "◉", "@", "°"]
        let eye = eyes[Int(floor(rng.next() * Double(eyes.count)))]

        // Hat
        let hats = ["none", "crown", "tophat", "propeller", "halo", "wizard", "beanie", "tinyduck"]
        let hat = rarity == .common ? "none" : hats[Int(floor(rng.next() * Double(hats.count)))]

        // Shiny
        let isShiny = rng.next() < 0.01

        // Stats
        let statNames = ["DEBUGGING", "PATIENCE", "CHAOS", "WISDOM", "SNARK"]
        let rarityFloor: [BuddyRarity: Int] = [.common: 5, .uncommon: 15, .rare: 25, .epic: 35, .legendary: 50]
        let statFloor = rarityFloor[rarity] ?? 5

        let peak = statNames[Int(floor(rng.next() * Double(statNames.count)))]
        var dump = statNames[Int(floor(rng.next() * Double(statNames.count)))]
        while dump == peak { dump = statNames[Int(floor(rng.next() * Double(statNames.count)))] }

        var statValues = [String: Int]()
        for name in statNames {
            if name == peak {
                statValues[name] = min(100, statFloor + 50 + Int(floor(rng.next() * 30)))
            } else if name == dump {
                statValues[name] = max(1, statFloor - 10 + Int(floor(rng.next() * 15)))
            } else {
                statValues[name] = statFloor + Int(floor(rng.next() * 40))
            }
        }

        return Bones(
            species: species,
            rarity: rarity,
            stats: BuddyStats(
                debugging: statValues["DEBUGGING"] ?? 0,
                patience: statValues["PATIENCE"] ?? 0,
                chaos: statValues["CHAOS"] ?? 0,
                wisdom: statValues["WISDOM"] ?? 0,
                snark: statValues["SNARK"] ?? 0
            ),
            eye: eye,
            hat: hat,
            isShiny: isShiny
        )
    }
}
