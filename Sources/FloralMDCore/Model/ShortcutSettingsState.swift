public struct ShortcutSettingsState: Equatable, Sendable {
    public var searchText: String
    public private(set) var presentationRevision: UInt

    public init(searchText: String = "", presentationRevision: UInt = 0) {
        self.searchText = searchText
        self.presentationRevision = presentationRevision
    }

    public mutating func refreshPresentation() {
        presentationRevision &+= 1
    }
}
