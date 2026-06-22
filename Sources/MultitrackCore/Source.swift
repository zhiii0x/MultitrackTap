public typealias SourceID = String

public enum SourceKind: Equatable, Sendable {
    case microphone
    case system
    case app
}

public struct Source: Equatable, Identifiable, Sendable {
    public let id: SourceID
    public let name: String
    public let kind: SourceKind

    public init(id: SourceID, name: String, kind: SourceKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}
