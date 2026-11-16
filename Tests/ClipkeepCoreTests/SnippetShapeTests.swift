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

    @Test func stderrNullAndDuplicationRedirectsAreIgnored() {
        #expect(sameShape("ls -la /mnt/a/ 2>/dev/null", "ls -la /mnt/b/"))
        #expect(sameShape("cmd >/dev/null 2>&1", "cmd"))
        #expect(sameShape("cmd &>/dev/null", "cmd"))
        #expect(sameShape("cmd > /dev/null", "cmd"))
        #expect(sameShape("cmd 2> err.log", "cmd"))
        #expect(sameShape("cmd 2>>err.log", "cmd"))
        #expect(sameShape("cmd >&2", "cmd"))
        #expect(sameShape("cmd 1>&2", "cmd"))
    }

    @Test func otherRedirectsKeepTheirOperatorAndMaskTheTarget() {
        #expect(!sameShape("echo hi > /etc/hosts", "echo hi"))
        #expect(!sameShape("psql db < drop.sql", "psql db"))
        #expect(!sameShape("cmd > out.log", "cmd"))
        #expect(!sameShape("cmd &> out.log", "cmd"))
        #expect(!sameShape("cmd > out.log", "cmd >> out.log"))
        #expect(!sameShape("cmd < in.txt", "cmd > in.txt"))
        #expect(sameShape("cmd > out.log", "cmd > /tmp/other.txt"))
        #expect(sameShape("psql db < a.sql", "psql db < b.sql"))
        #expect(SnippetShape.of("echo hi > /etc/hosts", language: .shell) == "echo hi > \u{1}path")
    }

    @Test(arguments: [
        (#"echo "a $(rm -rf /) b""#, #"echo "a $(ls) b""#),
        ("echo \"a `rm -rf /` b\"", "echo \"a `ls` b\""),
        ("echo $(rm -rf /)", "echo $(ls /)"),
        ("diff <(ls /a) <(ls /b)", "diff <(cat /a) <(cat /b)"),
        ("ssh prod 'uptime'", "ssh prod 'sudo reboot'"),
        ("ssh -p 22 -i ~/.ssh/k prod uptime", "ssh -p 22 -i ~/.ssh/k prod reboot"),
        ("mysql -e 'SELECT 1'", "mysql -e 'DROP DATABASE x'"),
        ("psql --command='SELECT 1'", "psql --command='DROP TABLE t'"),
        ("node --eval 'a()'", "node --eval 'b()'"),
        ("perl -ne 'print'", "perl -ne 'unlink'"),
        ("sudo ./deploy.sh", "sudo ./wipe.sh"),
        ("sudo -u root ./deploy.sh", "sudo -u root ./wipe.sh"),
        ("bash ./a.sh", "bash ./b.sh"),
        ("python3 ./x.py", "python3 ./y.py"),
        ("sudo env FOO=1 bash ./a.sh", "sudo env FOO=1 bash ./b.sh"),
        ("nice -n 10 ./a.sh", "nice -n 10 ./b.sh"),
        ("xargs -n 1 ./a.sh", "xargs -n 1 ./b.sh"),
        ("/usr/bin/env ./a.sh", "/usr/bin/env ./b.sh"),
        ("ls /x | sudo ./a.sh", "ls /x | sudo ./b.sh"),
    ])
    func dangerousDifferencesNeverMerge(first: String, second: String) {
        #expect(!sameShape(first, second))
    }

    @Test(arguments: [
        ("ls -la /tmp/a", "ls -la /tmp/b"),
        ("sudo ./deploy.sh /srv/a", "sudo ./deploy.sh /srv/b"),
        ("python3 ./x.py --in /a/1.csv", "python3 ./x.py --in /b/2.csv"),
        ("ssh -p 22 prod uptime", "ssh -p 2222 stage uptime"),
        ("python3 -m http.server 8000", "python3 -m http.server 9000"),
        ("sudo -u root ./deploy.sh", "sudo -u admin ./deploy.sh"),
        (#"echo "a""#, #"echo "b""#),
        ("cat /a/file 2>/dev/null | grep -v x", "cat /b/other 2>&1 | grep -v x"),
    ])
    func nearCopiesStillMerge(first: String, second: String) {
        #expect(sameShape(first, second))
    }

    @Test func flagsAndProgramStayDistinct() {
        #expect(!sameShape("ls -la /x", "ls -l /x"))
        #expect(!sameShape("./deploy.sh /x", "./build.sh /x"))
        #expect(!sameShape("cmd | grep foo", "cmd | sort"))
        #expect(!sameShape("cmd /x && ./a.sh", "cmd /x && ./b.sh"))
        #expect(!sameShape("kill -9 123", "kill -15 123"))
        #expect(!sameShape("gzip -1 f", "gzip -9 f"))
        #expect(!sameShape("head -5 f", "head -20 f"))
        #expect(sameShape("kill -9 123", "kill -9 456"))
        #expect(sameShape("sleep 5", "sleep 9"))
    }

    @Test func combinedDashCFlagsKeepTheirCodeLiteral() {
        #expect(!sameShape(#"bash -lc "echo a""#, #"bash -lc "rm -rf /tmp/x""#))
        #expect(!sameShape(#"sh -ec "a""#, #"sh -ec "b""#))
        #expect(!sameShape(#"zsh -ic "a""#, #"zsh -ic "b""#))
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
