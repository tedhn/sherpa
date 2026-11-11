import Foundation
import Network

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: fake-supabase <port-file> <archive-dir>\n".utf8))
    exit(2)
}
let portFile = URL(fileURLWithPath: CommandLine.arguments[1])
let archive = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

setvbuf(stdout, nil, _IOLBF, 0)
let queue = DispatchQueue(label: "fake-supabase")

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

        let (status, answer) = answer(for: lines.first ?? "", body: body)
        let head = "HTTP/1.1 \(status)\r\nContent-Length: \(answer.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + answer
    }

    private func answer(for request: String, body: Data) -> (String, Data) {
        let uploads = "POST /storage/v1/object/utterances/"
        if request.hasPrefix(uploads), request.hasSuffix(" HTTP/1.1") {
            let name = String(request.dropFirst(uploads.count).dropLast(" HTTP/1.1".count))
            guard !name.isEmpty, !name.contains("/") else { return ("400 Bad Request", Data("bad name".utf8)) }
            try! body.write(to: archive.appending(path: name))
            print("upload \(name) \(body.count) bytes")
            return ("200 OK", Data(#"{"Key":"utterances/\#(name)"}"#.utf8))
        }
        if request == "POST /rest/v1/utterances HTTP/1.1" {
            guard let id = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["id"] as? String,
                  UUID(uuidString: id) != nil
            else { return ("400 Bad Request", Data("no id".utf8)) }
            try! body.write(to: archive.appending(path: "\(id).json"))
            print("insert \(id)")
            return ("201 Created", Data())
        }
        return ("404 Not Found", Data("unexpected \(request)".utf8))
    }
}

let parameters = NWParameters.tcp
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
let listener = try NWListener(using: parameters)
listener.newConnectionHandler = { connection in _ = Exchange(connection) }
listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        let line = "http://127.0.0.1:\(listener.port!)"
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
