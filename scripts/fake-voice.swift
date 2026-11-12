import Foundation
import Network

enum Scenario: String {
    case ok, long
}

var positional: [String] = []
var scenarioFile: URL?
var remaining = CommandLine.arguments.dropFirst()[...]
while let argument = remaining.popFirst() {
    if argument == "--scenario-file", let path = remaining.popFirst() {
        scenarioFile = URL(fileURLWithPath: path)
    } else {
        positional.append(argument)
    }
}
guard positional.count == 2 else {
    FileHandle.standardError.write(Data("usage: fake-voice <port-file> <request-dir> [--scenario-file path]\n".utf8))
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
let queue = DispatchQueue(label: "fake-voice")
nonisolated(unsafe) var saved = 0

func errorBody(_ code: String, _ message: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["code": code, "message": message])
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
            if let reply = reply() {
                connection.send(content: reply, completion: .contentProcessed { [connection] _ in connection.cancel() })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                read()
            }
        }
    }

    private func reply() -> Data? {
        guard let headEnd = received.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: received[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = Data(received[headEnd.upperBound...])
        guard body.count >= Int(headers["content-length"] ?? "0") ?? 0 else { return nil }

        func whole(_ status: String, _ body: Data, type: String = "application/json") -> Data {
            Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        }
        guard lines.first == "POST /v1/speech HTTP/1.1" else {
            return whole("404 Not Found", errorBody("not_found", "unexpected \(lines.first ?? "")"))
        }
        guard headers["authorization"] == "fake" else {
            return whole("401 Unauthorized", errorBody("unauthorized", "invalid key"))
        }
        guard headers["content-type"] == "application/json",
              let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              fields["encoding"] as? String == "pcm_s16le", fields["sample_rate"] as? Int == 24_000
        else {
            return whole("400 Bad Request", errorBody("invalid_request", "bad content type or body"))
        }
        saved += 1
        let saving = ["authorization": headers["authorization"] ?? "", "body": fields] as [String: Any]
        try! JSONSerialization.data(withJSONObject: saving, options: [.sortedKeys]).write(to: requests.appending(path: "\(saved).json"))
        print("request \(saved) \(body.count) bytes")
        let silence = switch scenario() {
        case .ok: Data(count: 24_000)
        case .long: Data(count: 384_000)
        }
        return whole("200 OK", silence, type: "audio/pcm;rate=24000;channels=1")
    }
}

let parameters = NWParameters.tcp
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
let listener = try NWListener(using: parameters)
listener.newConnectionHandler = { connection in _ = Exchange(connection) }
listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        let line = "http://127.0.0.1:\(listener.port!)/v1/speech"
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
