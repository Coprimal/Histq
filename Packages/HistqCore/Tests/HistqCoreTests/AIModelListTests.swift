// Contract and security tests for the model list (task 1.4), served by the stub `URLProtocol` of `GitHubClientTests`:
// no test reaches the network. The request goes to the base's own `models` path with the key only in a header, the
// untrusted answer is cleaned before it reaches a picker, and an error never shows the key.
import Foundation
import HistqCore
import Testing

struct AIModelListTests {
    /// A made-up key; the tests look for it where it must never be.
    static let key = "sk-HistqFakeKey0123456789"

    @Test("the model list is a GET of the base's models path, with the key only in its header", arguments: [
        (AIProvider.openAI, "https://api.openai.com/v1/models", "Authorization"),
        (.anthropic, "https://api.anthropic.com/v1/models?limit=1000", "x-api-key"),
        (.gemini, "https://generativelanguage.googleapis.com/v1beta/openai/models", "Authorization"),
    ])
    func modelListRequest(provider: AIProvider, url: String, keyHeader: String) async throws {
        let stub = StubServer { _ in .init(body: #"{"data": [{"id": "m-2"}, {"id": "models/m-1"}]}"#) }
        let client = try AIChatClient(provider: provider, apiKey: Self.key, session: stub.session)

        #expect(try await client.listModels() == ["m-1", "m-2"])
        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.url?.absoluteString == url)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 15)
        let expectedHeader = keyHeader == "Authorization" ? "Bearer \(Self.key)" : Self.key
        #expect(request.value(forHTTPHeaderField: keyHeader) == expectedHeader)
        if provider == .anthropic { #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01") }
        #expect(request.url?.absoluteString.contains(Self.key) == false)
    }

    @Test("a custom server without a key gets no Authorization header")
    func customServerWithoutKey() async throws {
        let stub = StubServer { _ in .init(body: #"{"data": [{"id": "local-model"}]}"#) }
        let client = try AIChatClient(provider: .custom, apiKey: nil, customBaseURL: "http://localhost:11434", session: stub.session)

        #expect(try await client.listModels() == ["local-model"])
        let request = try #require(stub.requests.first)
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("parse strips models/, drops bad ids, dedupes, sorts and caps the list")
    func parseCleansTheList() throws {
        let long = String(repeating: "x", count: 201)
        let json = """
            {"data": [{"id": "gpt-b"}, {"id": "models/gpt-a"}, {"id": "gpt-a"}, {"id": "models/"}, {"id": ""},
            {"id": "\(long)"}, {"id": "evil\\nline"}, {"id": "bell\\u0007"}, {"id": 42}, {"name": "no-id"}]}
            """
        #expect(try AIModelList.parse(Data(json.utf8)) == ["gpt-a", "gpt-b"])
        #expect(try AIModelList.parse(Data(#"{"models": [{"name": "models/gemini-pro"}]}"#.utf8)) == ["gemini-pro"])

        let many = (0..<2_500).map { #"{"id": "m-\#(String(format: "%04d", $0))"}"# }.joined(separator: ",")
        let capped = try AIModelList.parse(Data(#"{"data": [\#(many)]}"#.utf8))
        #expect(capped.count == 2_000 && capped.first == "m-0000" && capped.last == "m-1999")

        #expect(throws: AIClientError.self) { try AIModelList.parse(Data("<html>".utf8)) }
    }

    @Test("an error answer that echoes the key is shown without it")
    func errorsNeverShowTheKey() async throws {
        let stub = StubServer { _ in
            .init(status: 401, body: #"{"error": {"message": "Incorrect API key provided: \#(Self.key). Check it."}}"#)
        }
        let client = try AIChatClient(provider: .custom, apiKey: Self.key, customBaseURL: "https://llm.example", session: stub.session)

        let error = await #expect(throws: AIClientError.self) { try await client.listModels() }
        #expect(error == .http(status: 401, message: "Incorrect API key provided: [API key]. Check it."))
        #expect(error?.description.contains(Self.key) == false)
    }

    @Test("a redirect to another host is not followed")
    func redirectToAnotherHostIsRefused() async throws {
        let stub = StubServer { _ in
            .init(status: 307, headers: ["Location": "https://evil.example/v1/models"], body: "",
                  redirect: URL(string: "https://evil.example/v1/models"))
        }
        let client = try AIChatClient(provider: .openAI, apiKey: Self.key, session: stub.session)

        let error = await #expect(throws: AIClientError.self) { try await client.listModels() }
        #expect(error == .http(status: 307, message: ""))
        #expect(stub.requests.allSatisfy { $0.url?.host() == "api.openai.com" })
    }
}
