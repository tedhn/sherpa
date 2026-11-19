import Foundation
import Network

enum Scenario: String {
    case ok, slow, unauthorized = "401", rateLimited = "429", refusal, overloaded
}

var positional: [String] = []
var answerDelay = 0.0
var chunkInterval = 0.05
var scenarioFile: URL?
var remaining = CommandLine.arguments.dropFirst()[...]
while let argument = remaining.popFirst() {
    if argument == "--answer-delay", let value = remaining.popFirst().flatMap(Double.init) {
        answerDelay = value
    } else if argument == "--chunk-interval", let value = remaining.popFirst().flatMap(Double.init) {
        chunkInterval = value
    } else if argument == "--scenario-file", let path = remaining.popFirst() {
        scenarioFile = URL(fileURLWithPath: path)
    } else {
        positional.append(argument)
    }
}
guard positional.count == 2 else {
    FileHandle.standardError.write(Data("usage: fake-claude <port-file> <request-dir> [--answer-delay s] [--chunk-interval s] [--scenario-file path]\n".utf8))
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

enum Response {
    case whole(status: String, body: Data)
    case stream(head: [Data], chunks: [Data], tail: [Data], interval: Double = chunkInterval)
}

func event(_ type: String, _ fields: [String: Any] = [:]) -> Data {
    let json = try! JSONSerialization.data(withJSONObject: fields.merging(["type": type]) { $1 })
    return Data("event: \(type)\ndata: ".utf8) + json + Data("\n\n".utf8)
}

func textDelta(_ text: String) -> Data {
    event("content_block_delta", ["index": 1, "delta": ["type": "text_delta", "text": text]])
}

func chunks(of text: String) -> [Data] {
    var rest = Substring(text)
    var pieces: [Data] = []
    while !rest.isEmpty {
        pieces.append(textDelta(String(rest.prefix(16))))
        rest = rest.dropFirst(16)
    }
    return pieces
}

func messageEnd(_ stop: String) -> [Data] {
    [event("message_delta", ["delta": ["stop_reason": stop, "stop_sequence": NSNull()]]), event("message_stop")]
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
            if let response = reply() {
                switch response {
                case .whole(let status, let body):
                    let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    send([(Data(head.utf8) + body, answerDelay)])
                case .stream(let head, let chunks, let tail, let interval):
                    let first = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8) + head.reduce(Data(), +)
                    let last = tail.reduce(Data(), +)
                    send([(first, answerDelay)] + chunks.enumerated().map { ($1, answerDelay + Double($0 + 1) * interval) }
                        + [(last, answerDelay + Double(chunks.count + 1) * interval)])
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                read()
            }
        }
    }

    private func send(_ pieces: [(Data, Double)]) {
        for (index, (data, delay)) in pieces.enumerated() {
            queue.asyncAfter(deadline: .now() + delay) { [connection] in
                if index == pieces.count - 1 {
                    connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    connection.send(content: data, completion: .idempotent)
                }
            }
        }
    }

    private func reply() -> Response? {
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
            return .whole(status: "404 Not Found", body: errorBody("not_found_error", "unexpected \(lines.first ?? "")"))
        }
        guard headers["x-api-key"] == "fake" else {
            return .whole(status: "401 Unauthorized", body: errorBody("authentication_error", "invalid x-api-key"))
        }
        guard headers["anthropic-version"] == "2026-10-21", headers["content-type"] == "application/json" else {
            return .whole(status: "400 Bad Request", body: errorBody("invalid_request_error", "bad version or content type"))
        }
        saved += 1
        try! body.write(to: requests.appending(path: "\(saved).json"))
        print("request \(saved) \(body.count) bytes")

        let start = event("message_start", ["message": ["id": "msg_fake", "type": "message", "role": "assistant", "content": [], "stop_reason": NSNull()]])
        let block = event("content_block_start", ["index": 1, "content_block": ["type": "text", "text": ""]])
        let thinking = [
            event("content_block_start", ["index": 0, "content_block": ["type": "thinking", "thinking": ""]]),
            event("content_block_delta", ["index": 0, "delta": ["type": "thinking_delta", "thinking": ""]]),
            event("content_block_delta", ["index": 0, "delta": ["type": "signature_delta", "signature": "sig"]]),
            event("content_block_stop", ["index": 0]),
            event("ping"),
        ]
        let head = [start] + thinking + [block]
        let answer = chunks(of: "Answer to: \(lastText(in: body))\n\n" + paragraphs.joined(separator: "\n\n"))
        let ended = [event("content_block_stop", ["index": 1])] + messageEnd("end_turn")
        switch scenario() {
        case .ok:
            return .stream(head: head, chunks: answer, tail: ended)
        case .slow:
            return .stream(head: head, chunks: answer, tail: ended, interval: 0.5)
        case .unauthorized:
            return .whole(status: "401 Unauthorized", body: errorBody("authentication_error", "invalid x-api-key"))
        case .rateLimited:
            return .whole(status: "429 Too Many Requests", body: errorBody("rate_limit_error", "slow down"))
        case .refusal:
            return .stream(head: head, chunks: Array(chunks(of: paragraphs[0]).prefix(3)), tail: messageEnd("refusal"))
        case .overloaded:
            return .stream(head: head, chunks: Array(chunks(of: paragraphs[0]).prefix(3)), tail: [event("error", ["error": ["type": "overloaded_error", "message": "Overloaded"]])])
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
