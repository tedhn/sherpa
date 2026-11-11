import Foundation
import Network

enum Scenario: String {
    case ok, unauthorized = "401", rateLimited = "429", refusal
}

var positional: [String] = []
var answerDelay = 0.0
var scenarioFile: URL?
var remaining = CommandLine.arguments.dropFirst()[...]
while let argument = remaining.popFirst() {
    if argument == "--answer-delay", let value = remaining.popFirst().flatMap(Double.init) {
        answerDelay = value
    } else if argument == "--scenario-file", let path = remaining.popFirst() {
        scenarioFile = URL(fileURLWithPath: path)
    } else {
        positional.append(argument)
    }
}
guard positional.count == 2 else {
    FileHandle.standardError.write(Data("usage: fake-claude <port-file> <request-dir> [--answer-delay s] [--scenario-file path]\n".utf8))
    exit(2)
}
let portFile = URL(fileURLWithPath: positional[0])
let requests = URL(fileURLWithPath: positional[1])
try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)

func scenario() -> Scenario {
    scenarioFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .flatMap { Scenario(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? .ok
}

setvbuf(stdout, nil, _IOLBF, 0)
let queue = DispatchQueue(label: "fake-claude")
nonisolated(unsafe) var saved = 0

let paragraphs = [
    "The screen shows a window with a heading, a level bar and a line of text under it. Everything in it is laid out in a single column, centred, with the control you hold to talk at the top and the words you spoke at the bottom. Nothing else on the display is in front of it, so there is nothing to read past the panel itself.",
    "If you want more detail, ask about one part of it. I can describe the colours, read out the text exactly as written, or say where each control sits relative to the others. I can also compare it with what is on the other display, if there is one, and tell you which of the two the cursor is on right now.",
]

func errorBody(_ type: String, _ message: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": type, "message": message]])
}

func message(content: [[String: Any]], stop: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["type": "message", "role": "assistant", "content": content, "stop_reason": stop])
}

func lastText(in body: Data) -> String {
    let messages = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["messages"] as? [[String: Any]]
    let content = messages?.last?["content"] as? [[String: Any]]
    return content?.last?["text"] as? String ?? ""
}

final class Exchange {
    private let connection: NWConnection
    private var received = Data()

    init(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [self] data, _, isComplete, error in
            received.append(data ?? Data())
            if let (status, answer) = reply() {
                let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(answer.count)\r\nConnection: close\r\n\r\n"
                let wire = Data(head.utf8) + answer
                queue.asyncAfter(deadline: .now() + answerDelay) { [connection] in
                    connection.send(content: wire, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                read()
            }
        }
    }

    private func reply() -> (String, Data)? {
        guard let headEnd = received.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: received[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = Data(received[headEnd.upperBound...])
        guard body.count >= Int(headers["content-length"] ?? "0") ?? 0 else { return nil }

        guard lines.first == "POST /v1/messages HTTP/1.1" else {
            return ("404 Not Found", errorBody("not_found_error", "unexpected \(lines.first ?? "")"))
        }
        guard headers["x-api-key"] == "fake" else {
            return ("401 Unauthorized", errorBody("authentication_error", "invalid x-api-key"))
        }
        guard headers["anthropic-version"] == "2026-10-21", headers["content-type"] == "application/json" else {
            return ("400 Bad Request", errorBody("invalid_request_error", "bad version or content type"))
        }
        saved += 1
        try! body.write(to: requests.appending(path: "\(saved).json"))
        print("request \(saved) \(body.count) bytes")

        switch scenario() {
        case .ok:
            let text = "Answer to: \(lastText(in: body))\n\n" + paragraphs.joined(separator: "\n\n")
            return ("200 OK", message(content: [["type": "thinking", "thinking": ""], ["type": "text", "text": text]], stop: "end_turn"))
        case .unauthorized:
            return ("401 Unauthorized", errorBody("authentication_error", "invalid x-api-key"))
        case .rateLimited:
            return ("429 Too Many Requests", errorBody("rate_limit_error", "slow down"))
        case .refusal:
            return ("200 OK", message(content: [], stop: "refusal"))
        }
    }
}

let parameters = NWParameters.tcp
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
let listener = try NWListener(using: parameters)
listener.newConnectionHandler = { connection in _ = Exchange(connection) }
listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        let line = "http://127.0.0.1:\(listener.port!)/v1/messages"
        try! line.write(to: portFile, atomically: true, encoding: .utf8)
        print("listening \(line)")
    case .failed(let error):
        print("listener failed: \(error)")
        exit(1)
    default:
        break
    }
}
listener.start(queue: queue)

let parentExit = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: queue)
parentExit.setEventHandler { exit(0) }
parentExit.activate()

dispatchMain()
