import Foundation

struct TrevoEvent: Codable, Sendable, Equatable {
    var event: String
    var userId: String?
    var anonymousId: String?
    var properties: [String: TrevoValue]?
    var timestamp: String
    var sdkVersion: String?
    var appVersion: String?
    var insertId: String?
    var preview: Bool?
}

/// Normative slugs from the conformance corpus.
enum BuildEventRejection: String, Error {
    case emptyName = "empty-name"
    case nameTooLong = "name-too-long"
    case nameCharset = "name-charset"
    case propertiesUnserializable = "properties-unserializable"
    case propertiesTooLarge = "properties-too-large"
    case noIdentity = "no-identity"
}

struct EventInput {
    var eventName: String
    var properties: [String: TrevoValue]?
    var userId: String?
    var anonymousId: String?
    var timestamp: String
    var sdkVersion: String?
    var appVersion: String?
    var insertId: String?
    var preview = false
}

enum EventBuilder {
    /// Rejects exactly what every other SDK rejects, so ingestion never sees a shape it would drop.
    static func build(_ input: EventInput) -> Result<TrevoEvent, BuildEventRejection> {
        let name = input.eventName
        if JSString.isBlank(name) { return .failure(.emptyName) }
        if name.utf16.count > Constants.maxEventNameLength { return .failure(.nameTooLong) }
        if !name.utf16.allSatisfy(isEventNameUnit) { return .failure(.nameCharset) }

        if let properties = input.properties {
            guard let serialized = try? JSON.encode(TrevoValue.object(properties)) else {
                return .failure(.propertiesUnserializable)
            }
            if serialized.count > Constants.maxPropertiesBytes {
                return .failure(.propertiesTooLarge)
            }
        }

        if (input.userId ?? "").isEmpty && (input.anonymousId ?? "").isEmpty {
            return .failure(.noIdentity)
        }

        return .success(
            TrevoEvent(
                event: name,
                userId: input.userId,
                anonymousId: input.anonymousId,
                properties: input.properties,
                timestamp: input.timestamp,
                sdkVersion: input.sdkVersion,
                appVersion: input.appVersion,
                insertId: input.insertId,
                preview: input.preview ? true : nil))
    }

    /// `^[A-Za-z0-9_.$-]+$`, one UTF-16 unit at a time.
    private static func isEventNameUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        case 0x5F, 0x2E, 0x24, 0x2D: return true
        default: return false
        }
    }
}

enum Timestamp {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// ISO 8601 in UTC with milliseconds, as JavaScript's Date#toISOString writes it.
    static func iso(_ date: Date) -> String {
        let millis = milliseconds(date)
        let (seconds, fraction) = millis.quotientAndRemainder(dividingBy: 1000)
        let wholeSeconds = fraction < 0 ? seconds - 1 : seconds
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: TimeInterval(wholeSeconds)))
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
            Int((fraction + 1000) % 1000))
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}
