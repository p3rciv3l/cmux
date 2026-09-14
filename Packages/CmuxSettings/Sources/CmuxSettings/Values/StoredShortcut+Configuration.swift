import Foundation

extension StoredShortcut {
    /// Parses a single stroke or an explicit unbind alias.
    ///
    /// - Parameters:
    ///   - rawValue: A shortcut such as `"cmd+t"`, or `"none"`.
    ///   - allowBareFirstStroke: Whether the action permits unmodified non-Space keys.
    /// - Returns: The decoded binding, or nil when its syntax or first stroke is invalid.
    public static func parseConfig(_ rawValue: String, allowBareFirstStroke: Bool = false) -> StoredShortcut? {
        if isUnboundConfigToken(rawValue) {
            return .unbound
        }
        return parseConfig(strokes: [rawValue], allowBareFirstStroke: allowBareFirstStroke)
    }

    /// Parses one stroke or a two-stroke chord using cmux.json key aliases.
    ///
    /// - Parameters:
    ///   - strokes: One or two modifier-plus-key strings.
    ///   - allowBareFirstStroke: Whether the action permits unmodified non-Space keys.
    /// - Returns: The decoded binding, or nil when either stroke is invalid.
    public static func parseConfig(strokes: [String], allowBareFirstStroke: Bool = false) -> StoredShortcut? {
        guard !strokes.isEmpty, strokes.count <= 2 else { return nil }
        if strokes.count == 1, let rawValue = strokes.first, isUnboundConfigToken(rawValue) {
            return .unbound
        }
        let parsedStrokes = strokes.compactMap(ShortcutStroke.parseConfig(_:))
        guard parsedStrokes.count == strokes.count, let firstStroke = parsedStrokes.first else {
            return nil
        }
        guard allowBareFirstStroke || firstStroke.hasAnyModifier || firstStroke.key == "space" else { return nil }
        let secondStroke = parsedStrokes.count == 2 ? parsedStrokes[1] : nil
        return StoredShortcut(first: firstStroke, second: secondStroke)
    }

    private static func isUnboundConfigToken(_ rawValue: String) -> Bool {
        if rawValue.isEmpty { return true }
        if rawValue == " " { return false }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return normalized == "none" || normalized == "clear" || normalized == "unbound" || normalized == "disabled"
    }

    /// Decodes documented JSON bindings and the recorder's lossless object form.
    ///
    /// Explicit null and empty-array values unbind an action. Unknown action IDs
    /// remain the caller's concern, so Settings can preserve valid future bindings.
    ///
    /// - Parameters:
    ///   - raw: A string, chord array, null, or nested stroke object from JSON.
    ///   - allowBareFirstStroke: Whether the action permits unmodified non-Space keys.
    /// - Returns: The decoded binding, or nil for absent or malformed input.
    public static func decodeConfiguration(_ raw: Any?, allowBareFirstStroke: Bool = false) -> StoredShortcut? {
        guard let raw else { return nil }
        if raw is NSNull { return .unbound }
        if let string = raw as? String {
            return parseConfig(string, allowBareFirstStroke: allowBareFirstStroke)
        }
        if let strokes = raw as? [String] {
            return strokes.isEmpty ? .unbound : parseConfig(strokes: strokes, allowBareFirstStroke: allowBareFirstStroke)
        }
        guard let object = raw as? [String: Any],
              let firstValue = object["first"],
              let first = ShortcutStroke.decodeConfigurationObject(firstValue) else { return nil }
        if first.key.isEmpty { return .unbound }
        guard allowBareFirstStroke || first.hasAnyModifier || first.key == "space" else { return nil }

        let second: ShortcutStroke?
        if let rawSecond = object["second"], !(rawSecond is NSNull) {
            guard let decoded = ShortcutStroke.decodeConfigurationObject(rawSecond) else { return nil }
            second = decoded
        } else {
            second = nil
        }
        return StoredShortcut(first: first, second: second)
    }
}

