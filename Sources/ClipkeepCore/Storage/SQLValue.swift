import Foundation

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

extension SQLValue {
    public init(_ value: String?) { self = value.map(SQLValue.text) ?? .null }
    public init(_ value: Date) { self = .double(value.timeIntervalSince1970) }
}
