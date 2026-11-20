/// A plan the paywall page may show and buy, supplied by the app's own billing code.
public struct TrevoPaywallProduct: Sendable, Equatable {
    public var id: String
    /// Formatted by the store for the user's region, such as `$9.99`.
    public var price: String
    public var title: String?
    public var description: String?
    /// The price as a number, in `currency`.
    public var amount: Double?
    /// ISO 4217, such as `USD`.
    public var currency: String?
    /// ISO 8601 duration of one billing period, such as `P1M`. Nil for a one-time purchase.
    public var period: String?
    /// ISO 8601 duration of a free trial, such as `P7D`.
    public var trialPeriod: String?

    public init(
        id: String, price: String, title: String? = nil, description: String? = nil, amount: Double? = nil,
        currency: String? = nil, period: String? = nil, trialPeriod: String? = nil
    ) {
        self.id = id
        self.price = price
        self.title = title
        self.description = description
        self.amount = amount
        self.currency = currency
        self.period = period
        self.trialPeriod = trialPeriod
    }

    var json: TrevoValue {
        var object: [String: TrevoValue] = ["id": .string(id), "price": .string(price)]
        if let title { object["title"] = .string(title) }
        if let description { object["description"] = .string(description) }
        if let amount { object["amount"] = .number(amount) }
        if let currency { object["currency"] = .string(currency) }
        if let period { object["period"] = .string(period) }
        if let trialPeriod { object["trialPeriod"] = .string(trialPeriod) }
        return .object(object)
    }
}

public enum TrevoPurchaseOutcome: String, Sendable {
    case purchased
    case cancelled
    /// Waiting on someone else, such as a parent's approval or a bank.
    case pending
}

public enum TrevoRestoreOutcome: String, Sendable {
    case restored
    // Not `none`, which Swift reads as `Optional.none` wherever an optional is compared.
    case nothingToRestore = "none"
}
