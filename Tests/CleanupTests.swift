import Foundation

func diag(_ message: String) {}

final class MockProtocol: URLProtocol {
    static var delay: TimeInterval = 0
    static var status = 200
    static var reason = "end_turn"
    static var capturedRequest: URLRequest?
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.capturedRequest = request
        let status = Self.status, reason = Self.reason
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let data = try! JSONSerialization.data(withJSONObject: ["stop_reason":reason,"content":[["type":"text","text":"明天下午四点开会。"]]])
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = item
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: item)
    }
    override func stopLoading() { work?.cancel() }
}

@main struct CleanupTests {
    static func main() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let cases: [(String, Double, Int, String, Bool)] = [
            ("success", 0.01, 200, "end_turn", true),
            ("timeout", 0.3, 200, "end_turn", false),
            ("http error", 0.01, 503, "end_turn", false),
            ("truncation", 0.01, 200, "max_tokens", false),
            ("refusal", 0.01, 200, "refusal", false)
        ]
        for (name, delay, status, reason, succeeds) in cases {
            MockProtocol.delay = delay; MockProtocol.status = status; MockProtocol.reason = reason
            var count = 0, result: String?, elapsed: Double = 0
            let started = ProcessInfo.processInfo.systemUptime
            Cleanup.polish("明天下午三点，不，四点开会。", apiKey: "test-key", model: "claude-haiku-4-5",
                           vocabulary: [], session: session, maxWait: 0.08) { text in
                precondition(Thread.isMainThread)
                count += 1; result = text
                elapsed = ProcessInfo.processInfo.systemUptime - started
            }
            let end = Date().addingTimeInterval(0.4)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
            precondition(count == 1, "\(name): duplicate or missing callback")
            precondition((result != nil) == succeeds, "\(name): incorrect fallback")
            precondition(elapsed < 0.2, "\(name): deadline exceeded")
            print("PASS \(name): one completion, \(String(format: "%.3f", elapsed))s")
        }
        precondition(Cleanup.basic("嗯，明天下午四点开会。", replacements: []) == "明天下午四点开会。")
        print("PASS basic cleanup retains complete text")
    }
}
