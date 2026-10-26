import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct DatabaseTests {
    @Test func dataSurvivesReopeningWithTheSameKey() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }

        try temp.open().write { try $0.execute("INSERT INTO settings VALUES ('a', 'b')") }
        let value = try temp.open().read {
            try $0.query("SELECT value FROM settings WHERE key = 'a'") { $0.text(0) }
        }

        #expect(value == ["b"])
    }

    @Test func fileOnDiskIsNotPlainSQLite() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        try temp.open().write {
            try $0.execute("INSERT INTO settings VALUES ('secret-marker', 'secret-marker')")
        }

        let bytes = try Data(contentsOf: URL(fileURLWithPath: temp.path))

        #expect(!String(decoding: bytes.prefix(16), as: UTF8.self).hasPrefix("SQLite format"))
        #expect(bytes.range(of: Data("secret-marker".utf8)) == nil)
    }

    @Test func wrongKeyIsRejected() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        _ = try temp.open()

        #expect(throws: DatabaseError.wrongKey) {
            try Database(path: temp.path, key: Data(repeating: 7, count: 32))
        }
    }

    @Test func failedWriteRollsBack() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()

        #expect(throws: DatabaseError.self) {
            try database.write { connection in
                try connection.execute("INSERT INTO settings VALUES ('x', '1')")
                try connection.execute("INSERT INTO settings VALUES ('x', '2')")
            }
        }

        let count = try database.read {
            try $0.query("SELECT count(*) FROM settings") { $0.int(0) }
        }
        #expect(count == [0])
    }

    @Test func boundParametersDoNotExecuteAsSQL() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()
        let hostile = "x'); DROP TABLE settings; --"

        try database.write {
            try $0.execute("INSERT INTO settings VALUES (?, ?)", [.text(hostile), .text("v")])
        }

        let keys = try database.read { try $0.query("SELECT key FROM settings") { $0.text(0) } }
        #expect(keys == [hostile])
    }

    @Test func fullTextTrigramIndexIsAvailable() throws {
        let temp = try TemporaryDatabase()
        defer { temp.remove() }
        let database = try temp.open()

        let hits = try database.write { connection in
            try connection.execute("CREATE VIRTUAL TABLE t USING fts5(body, tokenize='trigram')")
            try connection.execute("INSERT INTO t(body) VALUES ('getUserData()')")
            return try connection.query("SELECT body FROM t WHERE t MATCH 'serDa'") { $0.text(0) }
        }

        #expect(hits == ["getUserData()"])
    }
}
