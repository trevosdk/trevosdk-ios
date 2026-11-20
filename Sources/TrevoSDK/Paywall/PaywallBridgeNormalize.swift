/// What the page receives, whatever the app's code handed over. A port of the reference
/// `normalize.ts`; `PaywallBridgeHost` checks every answer through it.
enum PaywallBridgeNormalize {
    static let maxProducts = 20
    static let maxProductIdLength = 200
    static let maxPriceLength = 100
    static let maxTitleLength = 300
    static let maxDescriptionLength = 1000
    static let maxLocaleLength = 100

    /// Entries without an id or price are dropped, so are unknown fields and fields of the wrong
    /// shape; a repeated id keeps its first entry. Nil when it isn't a list.
    static func products(_ raw: TrevoValue) -> [TrevoValue]? {
        guard let entries = raw.arrayValue else { return nil }
        var products: [TrevoValue] = []
        var seen: Set<String> = []
        for entry in entries {
            guard let (id, product) = product(entry), !seen.contains(id) else { continue }
            seen.insert(id)
            products.append(product)
            if products.count == maxProducts { break }
        }
        return products
    }

    static func context(_ raw: TrevoValue?) -> TrevoValue {
        let context = raw?.objectValue ?? [:]
        let locale = context["locale"]?.stringValue.map(trimmingAsciiWhitespace) ?? []
        let safeArea = context["safeArea"]?.objectValue ?? [:]
        let fontScale = context["fontScale"]?.numberValue.flatMap {
            $0.isFinite && $0 > 0 && $0 <= 10 ? $0 : nil
        }
        let platform = context["platform"]?.stringValue.flatMap {
            ["ios", "android", "web"].contains($0) ? $0 : nil
        }
        return .object([
            "locale": .string(
                (1...maxLocaleLength).contains(locale.count)
                    ? String(decoding: locale, as: UTF16.self) : "en"),
            "colorScheme": .string(context["colorScheme"] == .string("dark") ? "dark" : "light"),
            "fontScale": .number(fontScale ?? 1),
            "safeArea": .object(
                Dictionary(
                    uniqueKeysWithValues: ["top", "right", "bottom", "left"].map {
                        ($0, TrevoValue.number(inset(safeArea[$0])))
                    })),
            "platform": .string(platform ?? "web"),
        ])
    }

    private static func product(_ raw: TrevoValue) -> (String, TrevoValue)? {
        guard let object = raw.objectValue,
            let id = bounded(object["id"], maxProductIdLength),
            let price = bounded(object["price"], maxPriceLength),
            !id.utf16.contains(where: isControl)
        else { return nil }
        var product: [String: TrevoValue] = ["id": .string(id), "price": .string(price)]
        if let title = bounded(object["title"], maxTitleLength) { product["title"] = .string(title) }
        if let description = bounded(object["description"], maxDescriptionLength) {
            product["description"] = .string(description)
        }
        if let amount = object["amount"]?.numberValue, amount.isFinite, amount >= 0 {
            product["amount"] = .number(amount)
        }
        if let currency = object["currency"]?.stringValue, isCurrency(currency) {
            product["currency"] = .string(currency)
        }
        for key in ["period", "trialPeriod"] {
            if let value = object[key]?.stringValue, isDuration(value) { product[key] = .string(value) }
        }
        return (id, .object(product))
    }

    private static func bounded(_ value: TrevoValue?, _ max: Int) -> String? {
        guard let text = value?.stringValue, (1...max).contains(text.utf16.count) else { return nil }
        return text
    }

    private static func isControl(_ unit: UInt16) -> Bool {
        unit <= 0x1F || unit == 0x7F
    }

    private static func isCurrency(_ value: String) -> Bool {
        value.utf16.count == 3 && value.utf16.allSatisfy { (0x41...0x5A).contains($0) }
    }

    /// `^P(?=\d)(?:\d+Y)?(?:\d+M)?(?:\d+W)?(?:\d+D)?$`: date durations only.
    static func isDuration(_ value: String) -> Bool {
        let units = Array(value.utf16)
        guard units.count >= 3, units[0] == 0x50 else { return false }
        let designators: [UInt16] = [0x59, 0x4D, 0x57, 0x44]  // Y M W D
        var next = 0
        var index = 1
        while index < units.count {
            let start = index
            while index < units.count, (0x30...0x39).contains(units[index]) { index += 1 }
            guard index > start, index < units.count,
                let position = designators[next...].firstIndex(of: units[index])
            else { return false }
            next = position + 1
            index += 1
        }
        return true
    }

    private static func inset(_ value: TrevoValue?) -> Double {
        guard let number = value?.numberValue, number.isFinite, number >= 0, number <= 1000 else { return 0 }
        return number
    }

    /// ASCII whitespace only: `String.trim`'s Unicode set differs between languages.
    private static func trimmingAsciiWhitespace(_ text: String) -> [UInt16] {
        let units = Array(text.utf16)
        let isSpace: (UInt16) -> Bool = { (0x09...0x0D).contains($0) || $0 == 0x20 }
        guard let start = units.firstIndex(where: { !isSpace($0) }),
            let end = units.lastIndex(where: { !isSpace($0) })
        else { return [] }
        return Array(units[start...end])
    }
}
