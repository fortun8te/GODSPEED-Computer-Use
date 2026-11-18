import Foundation

/// Other spellings apps use for a label a model writes. Inputs are already lower-cased with spaces removed.
enum LabelSpellings {
    private static let digits = ["0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
                                 "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine"]
    private static let symbols: [String: [String]] = [
        "+": ["add", "plus"], "-": ["subtract", "minus"], "−": ["subtract", "minus"],
        "*": ["multiply", "times"], "×": ["multiply", "times"],
        "/": ["divide"], "÷": ["divide"], "=": ["equals", "equal"], ".": ["decimal", "point"],
        "%": ["percent"], "(": ["openparenthesis"], ")": ["closeparenthesis"],
        "±": ["negate", "changesign"], "+/-": ["negate", "changesign"],
        "ac": ["allclear"], "c": ["clear"], "plus": ["add"], "minus": ["subtract"], "times": ["multiply"],
        "add": ["plus"], "subtract": ["minus"], "multiply": ["times"],
        "openparenthesis": ["("], "closeparenthesis": [")"],
    ]

    /// Menu bar titles a model may try to click as if they were window buttons.
    static let menuBarTitles: Set<String> = ["file", "edit", "view", "format", "window", "help", "insert", "go", "history",
                                              "bookmarks", "tools", "image", "arrange", "share", "table", "mailbox", "message"]

    /// A keypad (a calculator, a dialer): at least five of its buttons are named by digits or digit words.
    static func isKeypad(buttonNames: [String]) -> Bool {
        let names = Set(buttonNames)
        return digits.filter { names.contains($0.key) || names.contains($0.value) }.count >= 5
    }

    /// Other spellings of `label`, in both directions: "add" finds a "+" button and "+" finds an "Add" one,
    /// "one" finds "1" and "1" finds "one".
    static func alternatives(_ label: String) -> [String] {
        var out: [String] = []
        if let word = digits[label] { out.append(word) }
        if let digit = digits.first(where: { $0.value == label })?.key { out.append(digit) }
        out += symbols[label] ?? []
        for (key, spellings) in symbols where spellings.contains(label) && key != label {
            out.append(key)
        }
        return out
    }
}
