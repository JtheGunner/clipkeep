import Testing

@testable import ClipkeepCore

@Suite struct SnippetShapeTests {
    private func sameShape(
        _ first: String, _ second: String, _ language: SnippetLanguage = .shell
    ) -> Bool {
        SnippetShape.hash(of: first, language: language)
            == SnippetShape.hash(of: second, language: language)
    }

    @Test func pathsAreMasked() {
        #expect(sameShape("ls -la /mnt/a/plugin/", "ls -la /mnt/b/prefs/"))
        #expect(sameShape("cat ~/notes.txt", "cat ./other/notes.md"))
    }

    @Test func redirectsAreIgnored() {
        #expect(sameShape("ls -la /mnt/a/ 2>/dev/null", "ls -la /mnt/b/"))
        #expect(sameShape("cmd >/dev/null 2>&1", "cmd"))
        #expect(sameShape("cmd &> out.log", "cmd"))
        #expect(sameShape("cmd > out.log", "cmd"))
    }

    @Test func flagsAndProgramStayDistinct() {
        #expect(!sameShape("ls -la /x", "ls -l /x"))
        #expect(!sameShape("./deploy.sh /x", "./build.sh /x"))
        #expect(!sameShape("cmd | grep foo", "cmd | sort"))
        #expect(!sameShape("cmd /x && ./a.sh", "cmd /x && ./b.sh"))
    }

    @Test func commandArgumentsOfDashCAreNotMasked() {
        #expect(!sameShape(#"sh -c "echo a""#, #"sh -c "echo b""#))
        #expect(!sameShape(#"eval "$(a)""#, #"eval "$(b)""#))
        #expect(sameShape(#"echo "a""#, #"echo "b""#))
    }

    @Test func numbersUrlsIpsAndHashesAreMasked() {
        #expect(sameShape("curl http://a.example/x -m 5", "curl http://b.example/y -m 9"))
        #expect(sameShape("ping 10.0.0.1", "ping 10.0.0.2"))
        #expect(sameShape("ping6 fe80::1", "ping6 2001:db8::2"))
        #expect(sameShape("git show 1a2b3c4d5e", "git show 9f8e7d6c5b"))
    }

    @Test func lineCountMustMatch() {
        let twoLines = "cd /tmp\nls -la"
        #expect(!sameShape(twoLines, twoLines + "\nls -la"))
        #expect(sameShape(twoLines, "cd /var\nls -la"))
    }

    @Test func sqlLiteralsAreMaskedAndKeywordCaseIgnored() {
        #expect(sameShape("SELECT * FROM t WHERE id = 5", "select * from t where id = 9", .sql))
        #expect(
            sameShape("SELECT * FROM t WHERE name = 'a'", "SELECT * FROM t WHERE name='bb'", .sql))
        #expect(!sameShape("SELECT * FROM t", "SELECT * FROM u", .sql))
    }

    @Test func yamlScalarsAreMaskedKeysAreNot() {
        #expect(sameShape("replicas: 2", "replicas: 5", .yaml))
        #expect(!sameShape("replicas: 2", "copies: 2", .yaml))
        #expect(sameShape("- name: web\n  image: nginx:1.25", "- name: api\n  image: app:2", .yaml))
        #expect(!sameShape("spec:\n  replicas: 2", "spec:\nreplicas: 2", .yaml))
    }

    @Test func anonymiserPlaceholdersStayLiteral() {
        #expect(!sameShape("export K=<OPENAI_API_KEY>", "export K=<GITHUB_TOKEN>"))
        #expect(!sameShape("token: <OPENAI_API_KEY>", "token: <GITHUB_TOKEN>", .yaml))
        #expect(!sameShape("WHERE k = '<VALUE>'", "WHERE k = '<TOKEN>'", .sql))
    }

    @Test func languageIsPartOfTheKey() {
        #expect(
            SnippetShape.hash(of: "replicas: 2", language: .shell)
                != SnippetShape.hash(of: "replicas: 2", language: .yaml))
    }

    @Test func shapeTokensUseTheMarkerCharacter() {
        #expect(SnippetShape.of("ls /a", language: .shell) == "ls \u{1}path")
    }
}
