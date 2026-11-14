/// Text per language, `{"locales": {"de": "...", "pt-BR": "..."}}`. The app's language picks one text
/// by RFC 4647 lookup (`pt-BR` falls back to `pt`); no match leaves the app on its own text.
enum TranslatedText {
    private static let dot: UInt16 = 0x2E
    private static let at: UInt16 = 0x40
    private static let underscore: UInt16 = 0x5F
    private static let hyphen: UInt16 = 0x2D

    /// The text for `locale`, or nil when the value isn't text per language or lacks that language.
    static func text(_ value: TrevoValue, locale: String?) -> String? {
        guard let locale, let locales = value.objectValue?["locales"]?.objectValue else { return nil }
        var byTag: [String: String] = [:]
        for (tag, text) in locales {
            if let text = text.stringValue, !text.isEmpty { byTag[normalized(tag)] = text }
        }
        var tag = normalized(locale)
        while !tag.isEmpty {
            if let text = byTag[tag] { return text }
            guard let cut = tag.unicodeScalars.lastIndex(of: "-") else { return nil }
            tag = String(tag.unicodeScalars[..<cut])
            // A singleton such as the `x` in `en-x-private` never stands alone.
            if endsInSingleton(tag) { tag = String(tag.unicodeScalars.dropLast(2)) }
        }
        return nil
    }

    // `de_DE.UTF-8` and `sr@latin` are how a POSIX environment names a locale.
    static func normalized(_ tag: String) -> String {
        let name = String(decoding: tag.utf16.prefix { $0 != dot && $0 != at }, as: UTF16.self)
        let units = JSString.trimmed(name).map { $0 == underscore ? hyphen : $0 }
        return String(decoding: units, as: UTF16.self).lowercased()
    }

    private static func endsInSingleton(_ tag: String) -> Bool {
        let tail = tag.unicodeScalars.suffix(2)
        guard tail.count == 2, tail.first == "-", let last = tail.last else { return false }
        return ("a"..."z").contains(last) || ("0"..."9").contains(last)
    }
}
