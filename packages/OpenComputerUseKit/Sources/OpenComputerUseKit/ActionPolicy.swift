import AppKit
import Foundation

/// Only local configuration grants permission. Tool arguments and UI content can identify an
/// action or add risk evidence, but cannot change a decision.
struct ActionPolicy: Decodable, Sendable {
    enum Decision: String, Decodable, Sendable {
        case allow, ask, deny
    }

    enum Risk: String, CaseIterable, Sendable {
        case send, submit, purchase, delete
        case credentialEntry = "credential_entry"
        case fileOverwrite = "file_overwrite"
        case systemSettings = "system_settings"
    }

    private let apps: [String: Decision]
    private let origins: [String: Decision]
    private let risks: [Risk: Decision]

    var checksApps: Bool { apps.values.contains { $0 != .allow } }
    var checksOrigins: Bool { origins.values.contains { $0 != .allow } }
    var checksRisks: Bool { risks.values.contains { $0 != .allow } }

    private struct PolicyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case apps, origins, risks }

    init() {
        apps = [:]
        origins = [:]
        risks = [:]
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: PolicyKey.self)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        guard fields.allKeys.allSatisfy({ known.contains($0.stringValue) }) else {
            throw ComputerUseError.actionDenied("Unrecognized section in the action policy.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let appRules = try values.decodeIfPresent([String: Decision].self, forKey: .apps) ?? [:]
        let originRules = try values.decodeIfPresent([String: Decision].self, forKey: .origins) ?? [:]
        let riskRules = try values.decodeIfPresent([String: Decision].self, forKey: .risks) ?? [:]
        var appDecisions: [String: Decision] = [:]
        for (id, decision) in appRules {
            let key = id.lowercased()
            guard key.contains("."), key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }),
                  appDecisions.updateValue(decision, forKey: key) == nil else {
                throw ComputerUseError.actionDenied("Invalid or duplicate bundle ID in the action policy.")
            }
        }
        var siteDecisions: [String: Decision] = [:]
        for (address, decision) in originRules {
            guard let url = URLComponents(string: address), url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, ["", "/"].contains(url.path),
                  let key = Self.origin(address), siteDecisions.updateValue(decision, forKey: key) == nil else {
                throw ComputerUseError.actionDenied("Invalid or duplicate origin in the action policy.")
            }
        }
        var riskDecisions: [Risk: Decision] = [:]
        for (name, decision) in riskRules {
            guard let risk = Risk(rawValue: name) else {
                throw ComputerUseError.actionDenied("Unrecognized risk class in the action policy.")
            }
            riskDecisions[risk] = decision
        }
        apps = appDecisions
        origins = siteDecisions
        risks = riskDecisions
    }

    static var fileURL: URL {
        if let path = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_ACTION_POLICY"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".godspeed/action-policy.json")
    }

    static func load(from url: URL) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Self()
        } catch let error as ComputerUseError {
            throw error
        } catch {
            throw ComputerUseError.actionDenied("The local action policy could not be read or decoded.")
        }
    }

    static func origin(_ address: String) -> String? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    func authorize(bundleIDs: [String] = [], addresses: [String] = [], risks observed: Set<Risk> = []) throws {
        let scopes = bundleIDs.map { (apps[$0.lowercased()], "app \($0)") }
            + addresses.compactMap(Self.origin).map { (origins[$0], "site \($0)") }
        let decisions = scopes + Risk.allCases.filter { observed.contains($0) }
            .map { (risks[$0], "risk \($0.rawValue)") }
        if let rejected = decisions.first(where: { $0.0 == .deny }) {
            throw ComputerUseError.actionDenied("The local action policy denies \(rejected.1).")
        }
        if let pending = decisions.first(where: { $0.0 == .ask }) {
            throw ComputerUseError.approvalRequired("The local action policy requires approval for \(pending.1).")
        }
    }

    static func finderMayOpenDifferentApp(tool: String, arguments: [String: Any], bundleID: String?) -> Bool {
        guard bundleID?.lowercased() == "com.apple.finder" else { return false }
        switch tool {
        case "click":
            return (arguments["click_count"] as? Int ?? 1) > 1
        case "press_key":
            let key = (arguments["key"] as? String).map(ComputerUseService.canonicalKey) ?? ""
            return key == "cmd+o" || key == "cmd+down"
        case "press_menu":
            let path = (arguments["path"] as? [String]) ?? (arguments["path"] as? String)?.components(separatedBy: ">") ?? []
            return path.last?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("open") == true
        case "open":
            return arguments["label"] != nil
        default:
            return false
        }
    }

    static let browserBundleID = "com.google.Chrome"

    static func isBrowser(bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return id.hasPrefix("com.google.chrome") || id.hasPrefix("com.apple.safari")
            || id.hasPrefix("org.mozilla.firefox") || id.hasPrefix("com.microsoft.edgemac")
            || id.hasPrefix("com.brave.browser") || id == "company.thebrowser.browser"
            || id.hasPrefix("com.operasoftware.opera") || id == "org.chromium.chromium"
            || id.hasPrefix("com.vivaldi.vivaldi")
    }

    /// Context the driver can verify without input. Secure fields and HTML form semantics
    /// apply even to controls with an empty or innocuous display label.
    struct Target {
        var title: String? = nil
        var identifier: String? = nil
        var role: String? = nil
        var secureField = false
        var submitsForm = false
        var inDialog = false
    }

    static func nativeRisks(tool: String, arguments: [String: Any], bundleID: String?, target: Target?) -> Set<Risk> {
        let key = (arguments["key"] as? String).map(ComputerUseService.canonicalKey) ?? ""
        let path = arguments["path"] as? String
        let menuTitle = (arguments["path"] as? [String])?.last ?? path?.components(separatedBy: ">").last
        let app = arguments["app"] as? String ?? ""
        if tool == "get_app_state" || tool == "query" {
            // The dispatcher can route a Settings pane observation through its opener.
            return SettingsPanes.isSettings(app) && SettingsPanes.paneName(in: arguments) != nil ? [.systemSettings] : []
        }
        var result: Set<Risk> = []
        if SettingsPanes.isSettings(app) || bundleID == "com.apple.systempreferences"
            || (tool == "open" && [path, arguments["url"] as? String].compactMap { $0 }
                .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("x-apple.systempreferences:") }) {
            result.insert(.systemSettings)
        }
        switch tool {
        case "save_as":
            // A new path can also become occupied while the save dialog is opening.
            result.insert(.fileOverwrite)
        case "press_menu", "press_key", "click", "perform_secondary_action":
            result.formUnion(namedRisks([target?.title, target?.identifier,
                                         tool == "press_menu" ? menuTitle : nil,
                                         arguments["action"] as? String,
                                         arguments["label"] as? String]))
            if key == "cmd+s" || key == "cmd+shift+s" { result.insert(.fileOverwrite) }
            if ["click", "perform_secondary_action"].contains(tool),
               target?.role.map(SmartSteps.roleKey).map({ ["textfield", "textarea", "searchfield"].contains($0) }) != true {
                // AX has no effect metadata for an opaque button, custom action or pixel target.
                result.formUnion([.send, .submit, .purchase, .delete, .fileOverwrite, .systemSettings])
            }
            if bundleID?.lowercased() == "com.apple.finder" {
                if ["cmd+backspace", "cmd+delete", "alt+cmd+backspace", "alt+cmd+delete",
                    "cmd+option+backspace", "cmd+option+delete"].contains(key) {
                    result.insert(.delete)
                }
                if ["cmd+v", "alt+cmd+v", "cmd+option+v"].contains(key), case .files = PrivateClipboard.current.payload {
                    result.insert(.fileOverwrite)
                }
            }
            if ["return", "enter", "cmd+return", "cmd+enter"].contains(key) {
                if target?.inDialog == true { result.insert(.submit) }
                if let bundleID, ["com.apple.mail", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord"]
                    .contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
                    result.insert(.send)
                }
            }
            if target?.secureField == true, !key.isEmpty, !["tab", "escape", "esc", "cmd+c"].contains(key) {
                result.insert(.credentialEntry)
            }
        case "type_text", "set_value":
            // An unreadable field cannot establish that a configured credential rule is safe to skip.
            if target?.secureField != false { result.insert(.credentialEntry) }
        default:
            break
        }
        return result
    }

    static func browserRisks(action: String, arguments: [String: Any], target: Target?) -> Set<Risk> {
        let key = (arguments["key"] as? String).map(ComputerUseService.canonicalKey) ?? ""
        switch action {
        case "click", "press", "tap":
            var result = namedRisks([target?.title, target?.identifier, ComputerUseToolDispatcher.browserLabel(arguments)])
            if target?.submitsForm == true { result.insert(.submit) }
            return result
        case "upload", "files":
            return [.submit]
        case "key", "press_key":
            var result: Set<Risk> = []
            if ["enter", "return", "cmd+enter", "cmd+return"].contains(key), target?.submitsForm == true {
                result.insert(.submit)
            }
            if target?.secureField == true, !["tab", "escape", "esc", "cmd+c"].contains(key) {
                result.insert(.credentialEntry)
            }
            return result
        case "type", "type_text", "fill", "fill_field", "paste":
            if action == "paste", case .files = PrivateClipboard.current.payload { return [.submit] }
            return target?.secureField == true ? [.credentialEntry] : []
        default:
            return []
        }
    }

    static func namedRisks(_ names: [String?]) -> Set<Risk> {
        let names = names.compactMap { $0 }.map {
            $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        }
        let prefixes: [Risk: [String]] = [
            .send: ["send", "post", "publish", "sendmessage"],
            .submit: ["submit", "upload", "sign in", "log in"],
            .purchase: ["buy", "pay", "purchase", "place order", "checkout", "buy now"],
            .delete: ["delete", "remove", "erase", "move to trash", "empty trash", "axdelete"],
            .fileOverwrite: ["save", "replace", "overwrite"],
            .systemSettings: ["allow access", "grant permission"],
        ]
        return Set(prefixes.compactMap { risk, words in
            names.contains { name in words.contains { name == $0 || name.hasPrefix($0 + " ") } } ? risk : nil
        })
    }
}
