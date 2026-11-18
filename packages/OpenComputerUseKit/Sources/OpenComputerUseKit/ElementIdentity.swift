import ApplicationServices
import Foundation

/// Which control a snapshot showed at an index: its role, subrole, name (title, else description) and identifier,
/// and its value only where the value is what names it (static text, a pop-up's shown choice). A field's value is
/// what was typed into it and a checkbox's is its state; they change every time the control is used, so they are
/// left out.
struct ElementIdentity: Equatable {
    let role: String?
    let subrole: String?
    let name: String?
    let identifier: String?
    let value: String?

    static let valueIsName: Set<String> = [kAXStaticTextRole as String, kAXPopUpButtonRole as String]

    init(role: String?, subrole: String?, title: String?, description: String?, identifier: String?, value: String?) {
        func text(_ string: String?) -> String? {
            string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        self.role = text(role)
        self.subrole = text(subrole)
        name = text(title) ?? text(description)
        self.identifier = text(identifier)
        self.value = role.map(Self.valueIsName.contains) == true ? text(value) : nil
    }

    var described: String {
        [role, name.map { "\"\($0)\"" }].compactMap { $0 }.joined(separator: " ")
    }

    static func validate(index: String, recorded: ElementIdentity, now: ElementIdentity?) throws {
        guard recorded.role != nil, now == recorded else {
            throw ComputerUseError.stateUnavailable(
                "element \(index) no longer has the identity the snapshot showed, or could not be checked; call get_app_state again (nothing was sent)"
            )
        }
    }

    /// Read identity without walking or rebinding to a different, same-named control.
    /// Read the current role/subrole before requesting any value, preserving password protection.
    static func read(_ element: AXUIElement) throws -> ElementIdentity? {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute] as [String]
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &values)
        var read: [String: String] = [:]
        // Read the same way the snapshot did: a string attribute counts, anything else (an error for one
        // attribute, a non-string value) is absent. Treating those as "unreadable" refused every edit of
        // TextEdit's text view by number.
        if result == .success, let list = values as? [AnyObject], list.count == names.count {
            for (name, value) in zip(names, list) {
                if CFGetTypeID(value) == CFStringGetTypeID(), let text = value as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    read[name] = text
                }
            }
        } else {
            for name in names {
                var raw: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success, let raw,
                   CFGetTypeID(raw) == CFStringGetTypeID(), let text = raw as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    read[name] = text
                }
            }
        }
        let role = read[kAXRoleAttribute], subrole = read[kAXSubroleAttribute]
        guard role != nil else { return nil }
        var value: String?
        if valueIsName.contains(role!), !isSecureTextField(subrole: subrole) {
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw)
            guard error == .success || error == .attributeUnsupported || error == .noValue else { return nil }
            value = raw as? String
        }
        return ElementIdentity(role: role, subrole: subrole, title: read[kAXTitleAttribute],
                               description: read[kAXDescriptionAttribute], identifier: read[kAXIdentifierAttribute], value: value)
    }
}
