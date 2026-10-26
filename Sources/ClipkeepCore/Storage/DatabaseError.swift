public enum DatabaseError: Error, Equatable {
    case open(String)
    case wrongKey
    case prepare(code: Int32, message: String)
    case step(code: Int32, message: String)
    case migration(version: Int, message: String)
    /// The file was written by a newer app version than this build understands.
    case schemaTooNew(found: Int, supported: Int)
}
