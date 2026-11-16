import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct SnippetValidatorTests {
    private func isInvalid(_ check: SnippetCheck) -> Bool {
        if case .invalid = check { return true }
        return false
    }

    private func hint(of check: SnippetCheck) -> String? {
        if case .invalid(let hint) = check { return hint }
        return nil
    }

    // MARK: - Shell

    @Test func shellPipelineIsValid() {
        #expect(SnippetValidator.check("ls -la /x | grep foo", language: .shell) == .valid)
    }

    @Test func shellUnterminatedQuoteIsInvalid() {
        let check = SnippetValidator.check(#"echo "abc"#, language: .shell)
        #expect(hint(of: check)?.contains("Anführungszeichen") == true)
        #expect(isInvalid(SnippetValidator.check("echo 'abc", language: .shell)))
    }

    @Test(arguments: [
        "echo $(date", "ls |", "cmd &&", "cmd ||", "ls | | grep a", "echo $((1 + 2)",
        "( cd /tmp", "{ echo a; ", "echo `date", "echo ${HOME", "ls | ;", "echo $(ls |)",
        "echo a;;", "cat <<EOF\nline\n", "( ls )) ",
    ])
    func shellStructuralErrorsAreInvalid(text: String) {
        #expect(isInvalid(SnippetValidator.check(text, language: .shell)))
    }

    @Test(arguments: [
        "f() { echo a; }", "function f { echo a; }",
        "case $1 in\n  a) echo a ;;\n  *) echo other ;;\nesac",
        "cat <<< \"$x\"", "diff <(ls a) <(ls b)", "[[ $x =~ ^(a|b)$ ]] && echo y",
        "ls !(*.txt)",
    ])
    func shellUnmodelledConstructsAreNotChecked(text: String) {
        #expect(SnippetValidator.check(text, language: .shell) == .notChecked)
    }

    @Test(arguments: [
        "echo $((1+2))", "x=$(( (1 + 2) * 3 ))", "[[ -f a && -n \"$b\" ]] && echo ok",
        "if [ -f a ]; then echo yes; else echo no; fi",
        "for f in *.txt; do\n  echo \"$f\"\ndone",
        "echo \"it's \\\"quoted\\\"\"", "echo 'say \"hi\"'", "echo don\\'t",
        "ls # don't worry", "# a comment with 'apostrophe\nls",
        "cat <<EOF\nhello ( { ' \"\nEOF", "cat <<-'END'\n\tbody $(x\n\tEND\necho done",
        "cat <<EOF | grep a\nabc\nEOF", "ls -la \\\n  /tmp", "ls |\n  grep a",
        "make && \\\n  make install", "echo \"$(date +%s) and `whoami`\"",
        "echo ${HOME:-/tmp} ${#arr[@]} $# $? $$", "a=(1 2 3); echo ${a[0]}",
        "{ echo a; echo b; } > out", "echo {a,b}.txt", "echo }", "ls >| file",
        "cmd 2>&1 | tee log", "cmd &> /dev/null &", "echo $'a\\'b'",
        "kubectl get pods -o jsonpath='{.items[*].metadata.name}'",
        "find . -name '*.log' -exec rm {} \\;", "echo a#b", "echo \"é 😀\" | wc -c",
        "ls -la\r\necho a\r\n", "for ((i=0;;i++)); do break; done", "(( x = 1 << 2 ))",
        "echo 2fa 10px 1e3 0xFF", "git log --format='%h %s' | head",
        "awk '{ print $5 }' f | sort -n", "echo $(( $(wc -l < f) + 1 ))",
        "x=$(cat <<EOF\nbody )\nEOF\n)", "[ -z \"$x\" ] || { echo missing; exit 1; }",
        "for i in {1..10}; do echo $i; done", "((count++))", "exec 3>&-",
        "curl -d '{\"a\": 1}' -H \"Authorization: Bearer $TOKEN\" https://x/#frag",
        "export PATH=\"$HOME/bin:$PATH\"", "{\n  echo a\n}", "time { sleep 1; }",
    ])
    func validShellIsNeverInvalid(text: String) {
        let check = SnippetValidator.check(text, language: .shell)
        #expect(!isInvalid(check), "\(check)")
    }

    @Test(arguments: [
        "echo $((1+2))", "cat <<EOF\nhello\nEOF", "ls -la \\\n  /tmp",
        "{ echo a; echo b; } > out", "echo \"$(date) `whoami`\"", "ls | grep a && echo ok",
    ])
    func commonShellIsValid(text: String) {
        #expect(SnippetValidator.check(text, language: .shell) == .valid)
    }

    // MARK: - SQL

    @Test func sqlSelectIsValid() {
        #expect(SnippetValidator.check("SELECT id FROM t WHERE a = 1", language: .sql) == .valid)
    }

    @Test func sqlUnclosedParenthesisIsInvalid() {
        let check = SnippetValidator.check("SELECT id FROM t WHERE (a = 1", language: .sql)
        #expect(hint(of: check)?.contains("(") == true)
    }

    @Test(arguments: [
        "SELECT 'abc FROM t", "UPDATE t WHERE a = 1", "INSERT INTO t",
        "SELECT id FROM t WHERE a = 1)", "SELECT \"id FROM t", "SELECT 1 /* open",
        "insert into t (a, b)",
    ])
    func sqlStructuralErrorsAreInvalid(text: String) {
        #expect(isInvalid(SnippetValidator.check(text, language: .sql)))
    }

    @Test(arguments: [
        "PRAGMA user_version", "SHOW TABLES", "SELECT 1; VACUUM",
        // PostgreSQL 9.4+ accepts an empty select list.
        "SELECT FROM t", "SELECT;", "SELECT WHERE true",
        "SELECT [it's] FROM t", "SELECT 'it\\'s' FROM t", "SELECT 1 # don't",
        "SELECT 1 /* a /* nested */ */", "(SELECT 1) UNION (SELECT 2)",
    ])
    func sqlDialectSpecificInputIsNotChecked(text: String) {
        #expect(SnippetValidator.check(text, language: .sql) == .notChecked)
    }

    @Test(arguments: [
        "SELECT a -- don't (forget\nFROM t", "SELECT 'it''s' FROM t;",
        "CREATE FUNCTION f() RETURNS int AS $$ SELECT 'x; ( $$ LANGUAGE sql;",
        "SELECT $tag$ it's ( $tag$", "SELECT 1; SELECT 2;",
        "WITH x AS (SELECT 1 AS a) SELECT a FROM x",
        "CREATE TABLE t (\n  id INTEGER PRIMARY KEY,\n  name TEXT NOT NULL\n);",
        "INSERT INTO t (a, b) VALUES (1, 'x'), (2, 'y');", "INSERT INTO t SELECT * FROM u",
        "UPDATE t SET a = 1 WHERE b IN (SELECT c FROM d)", "DELETE FROM t WHERE id = $1",
        "select \"weird \"\"name\"\"\" from `t`", "SELECT a::text, b FROM t\r\nWHERE c = 1",
        "SELECT 2fa, 1e3, 0xFF FROM t", "SELECT 'é 😀' FROM t", "/* header */ SELECT 1",
        "ALTER TABLE t ADD COLUMN c INT;", "DROP TABLE IF EXISTS t;", "BEGIN; SELECT 1; COMMIT;",
        "SELECT * FROM t WHERE a = ? AND b = :name", "SELECT arr[1] FROM t",
        "UPDATE STATISTICS t", "INSERT INTO t DEFAULT VALUES",
    ])
    func validSQLIsNeverInvalid(text: String) {
        let check = SnippetValidator.check(text, language: .sql)
        #expect(!isInvalid(check), "\(check)")
    }

    // MARK: - YAML

    @Test func yamlNestedMappingIsValid() {
        #expect(SnippetValidator.check("a:\n  b: 1\n  c: 2", language: .yaml) == .valid)
    }

    @Test func yamlTabIndentationIsInvalid() {
        let check = SnippetValidator.check("a:\n\tb: 1", language: .yaml)
        #expect(hint(of: check)?.contains("Tabulator") == true)
    }

    @Test(arguments: [
        "a: [1, 2", "a: \"x", "a:\n  b: 1\n   c: 2", "a: 'x", "a: {b: 1", "a: [1, 2}",
        "a:\n    b: 1\n  c: 2", "a: 1\nb\nc: 2", "- name: x\n    image: y",
        "k: \"v\"\n  - x", "k: [1]\n  - x", "k: v\n  b: 1",
    ])
    func yamlStructuralErrorsAreInvalid(text: String) {
        #expect(isInvalid(SnippetValidator.check(text, language: .yaml)))
    }

    @Test(arguments: [
        "# config\na: 1 # don't\nb: \"x\" # it's",
        "---\na: 1\n---\nb: 2\n...",
        "script: |\n  echo \"$(date\" {\n    [ odd ( indent\n\tx\nnext: 1",
        "folded: >-\n  some ' text\n  more\n\nafter: 2",
        "base: &base\n  a: 1\nderived:\n  <<: *base\n  b: 2",
        "list: [1, 2, {a: b}]\nmap: {x: 1, y: [2, 3]}",
        "\"quoted key\": 1\n'other: key': 2",
        "items:\n  - name: a\n    value: 1\n  - name: b\n    value: 2",
        "items:\n- a\n- b\nnext: 1", "url: http://example.com:80/a", "path: C:\\temp",
        "multi: [1,\n  2,\n  3]\nnext: 1", "msg: \"line one\n  line two\"\nnext: 1",
        "a: don't\nb: it's", "empty:\nother: ~", "key:\t1", "- a\n- b\n-\n  c: 1",
        "a: 1\r\nb:\r\n  c: 2\r\n", "emoji: \"😀 é\"", "a: b]", "a: b[1]",
        "key: 'it''s'", "spec:\n  containers:\n    - name: web\n      image: nginx\n",
        "%YAML 1.2\n---\na: 1", "a: 1\n  # odd comment\nb: 2",
        """
        apiVersion: v1
        kind: Pod
        metadata:
          name: x
          labels:
            app: web
        spec:
          containers:
          - name: web
            image: nginx:1.25
            ports:
            - containerPort: 80
        """,
        """
        on:
          push:
            branches: [main]
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - name: Run
                run: |
                  echo "hi" && make test
                env:
                  A: ${{ secrets.A }}
        """,
        "{\n  \"a\": 1,\n  \"b\": [1, 2]\n}", "description: a long\n  continued line",
        "- a:\n  - x", "ports:\n  - \"8080:80\"\n  - 9090:90",
        // A deeper `- ` line after a plain value continues that plain scalar.
        "k: v\n  - x", "- a\n  - b", "description: does X\n  - and Y\n  - and Z\nnext: 1",
    ])
    func validYAMLIsNeverInvalid(text: String) {
        let check = SnippetValidator.check(text, language: .yaml)
        #expect(!isInvalid(check), "\(check)")
    }

    @Test(arguments: [
        "items:\n  - name: a\n    value: 1\n  - name: b", "list: [1, 2, {a: b}]",
        "script: |\n  echo (\nnext: 1", "---\na: 1\n---\nb: 2",
    ])
    func commonYAMLIsValid(text: String) {
        #expect(SnippetValidator.check(text, language: .yaml) == .valid)
    }

    // MARK: - All languages

    @Test(arguments: SnippetLanguage.allCases)
    func emptyTextIsNotChecked(language: SnippetLanguage) {
        #expect(SnippetValidator.check("", language: language) == .notChecked)
        #expect(SnippetValidator.check(" \n\t\n", language: language) == .notChecked)
    }

    @Test(arguments: SnippetLanguage.allCases)
    func hintsNeverRepeatTheSnippet(language: SnippetLanguage) {
        let text = "x: \"s3cr3tValue (( [[ {{ $( `"
        if let hint = hint(of: SnippetValidator.check(text, language: language)) {
            #expect(!hint.contains("s3cr3tValue"))
        }
    }

    @Test func textOverTheLimitIsNotChecked() {
        let text = String(repeating: "echo \"a", count: SnippetValidator.maximumUTF8Length)
        #expect(SnippetValidator.check(text, language: .shell) == .notChecked)
    }

    @Test func statusTextShowsTheResult() {
        #expect(SnippetCheck.valid.statusText == "✓ Syntax gültig")
        #expect(
            SnippetCheck.invalid(hint: "Klammer ( nicht geschlossen").statusText
                == "✗ Syntax ungültig: Klammer ( nicht geschlossen")
        #expect(SnippetCheck.notChecked.statusText == nil)
    }

    @Test func largeInputIsBounded() {
        let pieces: [(SnippetLanguage, String)] = [
            (.shell, "echo \"a\" | grep -v b && "), (.sql, "select 1 from t where a = 'x' and "),
            (.yaml, "key: value\n"),
        ]
        for (language, piece) in pieces {
            let text = String(repeating: piece, count: 1_048_576 / piece.utf8.count)
            let start = Date()
            _ = SnippetValidator.check(text, language: language)
            _ = SnippetValidator.evaluate(text, language: language)
            #expect(Date().timeIntervalSince(start) < PerformanceBudget.limit(2.0))
        }
    }

    @Test(arguments: SnippetLanguage.allCases)
    func adversarialLargeInputsTerminate(language: SnippetLanguage) {
        let megabyte = 1_048_576
        let inputs = [
            "\"" + String(repeating: "a", count: megabyte),
            "'" + String(repeating: "a", count: megabyte),
            "`" + String(repeating: "a", count: megabyte),
            String(repeating: "(", count: megabyte), String(repeating: ")", count: megabyte),
            String(repeating: "{", count: megabyte), String(repeating: "[", count: megabyte),
            String(repeating: "$(", count: megabyte / 2),
            String(repeating: "${", count: megabyte / 2),
            String(repeating: "$((", count: megabyte / 3), String(repeating: "`", count: megabyte),
            String(repeating: "|", count: megabyte), String(repeating: "&&", count: megabyte / 2),
            String(repeating: "\t", count: megabyte), String(repeating: "😀é", count: megabyte / 6),
            String(repeating: "a: 1\r\n", count: megabyte / 6),
            String(repeating: "select 2fa 1é 0xFF\r\n", count: megabyte / 22),
            String(repeating: "\\", count: megabyte), String(repeating: "$", count: megabyte),
            String(repeating: "<<", count: megabyte / 2),
            String(repeating: "- ", count: megabyte / 2),
            String(repeating: "$$", count: megabyte / 2),
            String(repeating: "/*", count: megabyte / 2),
            String(repeating: "a:\n ", count: megabyte / 4),
            String(repeating: "cat <<E\n", count: megabyte / 8),
            String(repeating: "1", count: megabyte) + "x",
        ]
        for text in inputs {
            let start = Date()
            _ = SnippetValidator.evaluate(text, language: language)
            #expect(
                Date().timeIntervalSince(start) < PerformanceBudget.limit(3.0),
                "\(text.prefix(8))")
        }
    }

    /// Deep nesting followed by many comments or separators: any per-token work that grows with
    /// the nesting depth turns these quadratic. Each input fits under the check's length limit,
    /// so it is what a paste into the creation sheet would cost on every keystroke.
    @Test(arguments: SnippetLanguage.allCases)
    func deepNestingWithManyCommentsStaysLinear(language: SnippetLanguage) {
        let inputs = [
            String(repeating: "(", count: 131_072) + String(repeating: "\n#", count: 65_536),
            String(repeating: "{ ", count: 65_536) + String(repeating: "\n#", count: 65_536),
            String(repeating: "$(", count: 65_536) + String(repeating: "\n#", count: 65_536),
            String(repeating: "`", count: 65_537) + String(repeating: "\n#", count: 65_536),
            String(repeating: "[", count: 131_072) + String(repeating: "\n#", count: 65_536),
            String(repeating: "(", count: 131_072) + String(repeating: "\n--", count: 43_690),
            String(repeating: "(", count: 131_072) + String(repeating: ";", count: 131_072),
            String(repeating: "a:\n", count: 1) + String(repeating: " ", count: 131_000)
                + "b:\n" + String(repeating: "#\n", count: 65_536),
        ]
        for text in inputs {
            #expect(text.utf8.count <= SnippetValidator.maximumUTF8Length)
            let start = Date()
            _ = SnippetValidator.check(text, language: language)
            #expect(
                Date().timeIntervalSince(start) < PerformanceBudget.limit(0.5),
                "\(text.prefix(8))")
        }
    }
}
