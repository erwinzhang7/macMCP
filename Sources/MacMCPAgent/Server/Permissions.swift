import Foundation
import MacMCPCore

/// Two access tiers per app. Default is `.none` (visible only); `.full` unlocks screenshot,
/// AX read, input, and network for that app.
enum Tier: String {
    case none
    case full
}

/// One persisted grant record.
struct Grant {
    var tier: Tier
    var signingTeamID: String?
    var name: String
    var grantedAt: String  // ISO-8601

    func toJSON() -> JSONValue {
        var o: [String: JSONValue] = [
            "tier": .string(tier.rawValue),
            "name": .string(name),
            "grantedAt": .string(grantedAt),
        ]
        if let signingTeamID { o["signingTeamID"] = .string(signingTeamID) }
        return .object(o)
    }
}

/// Per-app, two-tier allowlist. The agent is authoritative and persists grants to disk, so
/// every shim session shares one view and revocation is instantly effective everywhere.
/// Claude can never self-grant — grants come only from the user (the native dialog at action
/// time, or the menu-bar toggle).
///
/// Mirrors safari-mcp/driver/.../Bridge/Permissions.swift (same NSLock + read-merge-on-mutate
/// + atomic write), upgraded from a flat origin set to a per-bundle-id record map.
final class Permissions {
    private let lock = NSLock()
    private var grants: [String: Grant] = [:]  // keyed by gateKey (bundle id)
    private let fileURL: URL

    /// Called (outside the lock) after any change, so the menu bar / network layer can refresh.
    var onChange: (() -> Void)?

    init() {
        AgentPaths.ensureSupportDir()
        fileURL = AgentPaths.supportDir.appendingPathComponent("permissions.json")
        load()
    }

    func tier(for key: String) -> Tier {
        lock.lock(); defer { lock.unlock() }
        return grants[key]?.tier ?? .none
    }

    func grant(for key: String) -> Grant? {
        lock.lock(); defer { lock.unlock() }
        return grants[key]
    }

    /// All grants as `[gateKey: recordJSON]`.
    func allJSON() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        var o: [String: JSONValue] = [:]
        for (k, g) in grants { o[k] = g.toJSON() }
        return .object(o)
    }

    func grantFull(key: String, name: String, teamID: String?) {
        mutate {
            grants[key] = Grant(
                tier: .full, signingTeamID: teamID, name: name, grantedAt: Self.now())
        }
    }

    func revoke(key: String) {
        mutate { grants.removeValue(forKey: key) }
    }

    private func mutate(_ change: () -> Void) {
        lock.lock()
        // Merge records other sessions persisted since our last write.
        if let disk = readFile() { grants.merge(disk) { _, new in new } }
        change()
        save()
        lock.unlock()
        onChange?()
    }

    // MARK: - Persistence

    private func readFile() -> [String: Grant]? {
        guard let data = try? Data(contentsOf: fileURL),
            let root = try? JSONValue.decode(data), let obj = root.objectValue
        else { return nil }
        var out: [String: Grant] = [:]
        for (k, v) in obj {
            guard let tier = v["tier"]?.stringValue.flatMap(Tier.init(rawValue:)) else { continue }
            out[k] = Grant(
                tier: tier,
                signingTeamID: v["signingTeamID"]?.stringValue,
                name: v["name"]?.stringValue ?? k,
                grantedAt: v["grantedAt"]?.stringValue ?? "")
        }
        return out
    }

    private func load() {
        if let disk = readFile() { grants = disk }
    }

    private func save() {
        var o: [String: JSONValue] = [:]
        for (k, g) in grants { o[k] = g.toJSON() }
        guard let data = try? JSONValue.object(o).encoded() else { return }
        try? data.write(to: fileURL, options: .atomic)  // temp + rename — no torn reads
    }

    private static func now() -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date())
    }
}
