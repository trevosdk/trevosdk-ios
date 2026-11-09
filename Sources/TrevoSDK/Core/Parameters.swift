/// Parameter resolution, docs/sdk/bucketing-spec.md section 7.
enum Parameters {
    /// The experiment that decides a parameter. A shipped winner can still be in config beside a
    /// newer test, and the test is what users should get.
    static func experiment(setting name: String, in configs: [ExperimentConfig]) -> ExperimentConfig? {
        let setting = configs.filter { config in
            // A settled config serves only its winning arm, so a name only a losing arm set isn't its to give.
            let winner = Assignment.settledVariant(config)
            let arms = winner.map { name in config.variants.filter { $0.name == name } } ?? config.variants
            return arms.contains { $0.params[name] != nil }
        }
        return setting.first { Assignment.settledVariant($0) == nil } ?? setting.first
    }

    static func value(_ name: String, in config: ExperimentConfig?, variant: String?) -> TrevoValue? {
        config?.variants.first { $0.name == variant }?.params[name]
    }
}
