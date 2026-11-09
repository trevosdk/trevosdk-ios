import Foundation

/// One experiment as `/v1/config` serves it.
public struct ExperimentConfig: Sendable, Equatable {
    public let experimentKey: String
    /// In list order, which is part of the assignment contract.
    public let variants: [ExperimentVariant]
    public let minAppVersion: MinAppVersion?

    public init(
        experimentKey: String, variants: [ExperimentVariant], minAppVersion: MinAppVersion? = nil
    ) {
        self.experimentKey = experimentKey
        self.variants = variants
        self.minAppVersion = minAppVersion
    }
}

public struct ExperimentVariant: Sendable, Equatable {
    public let name: String
    /// Whole percent of traffic.
    public let trafficSplit: Int
    /// This variant's value for each parameter it sets; the rest serve the app's default.
    public let params: [String: TrevoValue]

    public init(name: String, trafficSplit: Int, params: [String: TrevoValue] = [:]) {
        self.name = name
        self.trafficSplit = trafficSplit
        self.params = params
    }
}

/// Lowest app build that may join an experiment, per store platform.
public struct MinAppVersion: Sendable, Equatable {
    public let ios: String?
    public let android: String?

    public init(ios: String? = nil, android: String? = nil) {
        self.ios = ios
        self.android = android
    }
}

enum ConfigParseError: Error, Equatable {
    case notAnObject
    case missingExperiments
    case invalidExperiment

    var message: String {
        switch self {
        case .notAnObject: return "Response is not an object"
        case .missingExperiments: return "Missing experiments array"
        case .invalidExperiment: return "Invalid experiment config in response"
        }
    }
}

/// Mirrors the JavaScript SDKs' parser: lenient on ranges and sums, strict on shape.
enum ConfigParser {
    static func parse(_ body: TrevoValue) -> Result<[ExperimentConfig], ConfigParseError> {
        guard let object = body.objectValue else { return .failure(.notAnObject) }
        guard let entries = object["experiments"]?.arrayValue else {
            return .failure(.missingExperiments)
        }
        var experiments: [ExperimentConfig] = []
        experiments.reserveCapacity(entries.count)
        for entry in entries {
            guard let experiment = experiment(entry) else { return .failure(.invalidExperiment) }
            experiments.append(experiment)
        }
        return .success(experiments)
    }

    private static func experiment(_ value: TrevoValue) -> ExperimentConfig? {
        guard let object = value.objectValue,
            let key = object["experimentKey"]?.stringValue, !key.isEmpty,
            let entries = object["variants"]?.arrayValue, entries.count >= 2
        else { return nil }
        var variants: [ExperimentVariant] = []
        for entry in entries {
            guard let variant = variant(entry) else { return nil }
            variants.append(variant)
        }
        return ExperimentConfig(
            experimentKey: key, variants: variants,
            minAppVersion: minAppVersion(object["minAppVersion"]))
    }

    private static func variant(_ value: TrevoValue) -> ExperimentVariant? {
        guard let object = value.objectValue,
            let name = object["name"]?.stringValue, !name.isEmpty,
            let split = object["trafficSplit"]?.numberValue,
            split.isFinite, split.rounded() == split,
            abs(split) <= TrevoValue.maxSafeInteger
        else { return nil }
        return ExperimentVariant(
            name: name, trafficSplit: Int(split), params: object["params"]?.objectValue ?? [:])
    }

    private static func minAppVersion(_ value: TrevoValue?) -> MinAppVersion? {
        guard let object = value?.objectValue else { return nil }
        return MinAppVersion(ios: object["ios"]?.stringValue, android: object["android"]?.stringValue)
    }
}

/// Experiments by key. A repeated key keeps its first position and its last config, as a JS Map does.
struct ExperimentRegistry: Sendable {
    private(set) var all: [ExperimentConfig] = []
    private var indexByKey: [String: Int] = [:]

    init(_ experiments: [ExperimentConfig] = []) {
        for experiment in experiments {
            if let index = indexByKey[experiment.experimentKey] {
                all[index] = experiment
            } else {
                indexByKey[experiment.experimentKey] = all.count
                all.append(experiment)
            }
        }
    }

    subscript(key: String) -> ExperimentConfig? {
        indexByKey[key].map { all[$0] }
    }
}
