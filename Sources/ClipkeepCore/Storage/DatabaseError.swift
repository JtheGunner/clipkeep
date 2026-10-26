public enum DatabaseError: Error, Equatable {
    case open(String)
    case wrongKey
    case prepare(String)
    case step(String)
    case migration(version: Int, message: String)
}
