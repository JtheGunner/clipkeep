import Testing

@testable import ClipkeepCore

@Suite struct SnippetTopicTests {
    @Test func shellTopicIsTheProgram() {
        #expect(SnippetTopic.of("docker compose up -d --build", language: .shell) == "docker")
        #expect(SnippetTopic.of("git log --oneline | head -20", language: .shell) == "git")
    }

    @Test func shellTopicSkipsPromptsEnvironmentAndWrappers() {
        #expect(SnippetTopic.of("$ kubectl get pods -n kube-system", language: .shell) == "kubectl")
        #expect(
            SnippetTopic.of("DEBUG=1 FOO=bar npm run test -- --watch", language: .shell) == "npm")
        #expect(SnippetTopic.of("sudo systemctl restart nginx", language: .shell) == "systemctl")
        #expect(SnippetTopic.of("sudo -E env LANG=C make install", language: .shell) == "make")
    }

    @Test func shellTopicSkipsCommentsAndBlankLines() {
        let text = "\n# build the image\n\ndocker build -t app .\ndocker push app"
        #expect(SnippetTopic.of(text, language: .shell) == "docker")
    }

    @Test func shellTopicOfAScriptPathIsItsFileName() {
        #expect(SnippetTopic.of("./scripts/test.sh --filter Core", language: .shell) == "test.sh")
    }

    @Test func shellTopicIsNilWhenNoProgramCanBeRead() {
        #expect(SnippetTopic.of("$(echo hi) | cat", language: .shell) == nil)
        #expect(SnippetTopic.of("# only a comment", language: .shell) == nil)
    }

    @Test func sqlTopicIsTheFirstTable() {
        #expect(
            SnippetTopic.of("SELECT id, name FROM Customers WHERE active = 1;", language: .sql)
                == "customers")
        #expect(
            SnippetTopic.of("insert into audit.log (a) values (1)", language: .sql) == "audit.log")
        #expect(SnippetTopic.of("UPDATE orders SET paid = true", language: .sql) == "orders")
        #expect(SnippetTopic.of("DELETE FROM sessions WHERE expired", language: .sql) == "sessions")
    }

    @Test func sqlTopicHandlesQuotingAndIfExists() {
        #expect(
            SnippetTopic.of("CREATE TABLE IF NOT EXISTS \"users\" (id int)", language: .sql)
                == "users")
        #expect(SnippetTopic.of("DROP TABLE IF EXISTS `tmp_ids`", language: .sql) == "tmp_ids")
    }

    @Test func sqlTopicSkipsSubqueries() {
        let text = "SELECT * FROM (SELECT id FROM invoices) t"
        #expect(SnippetTopic.of(text, language: .sql) == "invoices")
    }

    @Test func sqlTopicIsNilWithoutATable() {
        #expect(SnippetTopic.of("SELECT 1; SELECT now();", language: .sql) == nil)
    }

    @Test func yamlTopicIsTheKindOfAManifest() {
        let text = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\n"
        #expect(SnippetTopic.of(text, language: .yaml) == "deployment")
    }

    @Test func yamlTopicIsTheFirstTopLevelKeyOtherwise() {
        let text = "---\n# compose file\nservices:\n  web:\n    image: nginx\n"
        #expect(SnippetTopic.of(text, language: .yaml) == "services")
    }

    @Test func yamlTopicIgnoresNestedKinds() {
        let text = "jobs:\n  build:\n    kind: fake\n"
        #expect(SnippetTopic.of(text, language: .yaml) == "jobs")
    }
}
