import Foundation
import Network

enum Scenario: String {
    case ok, silent, noEndpoint = "no-endpoint", close1008 = "close-1008", noBegin = "no-begin",
         noTermination = "no-termination", token401 = "token-401", expiredOnce = "expired-once"
}

var positional: [String] = []
var beginDelay = 0.8
var answerDelay = 0.25
var scenarioFile: URL?
var remaining = CommandLine.arguments.dropFirst()[...]
while let argument = remaining.popFirst() {
    if argument == "--begin-delay", let value = remaining.popFirst().flatMap(Double.init) {
        beginDelay = value
    } else if argument == "--answer-delay", let value = remaining.popFirst().flatMap(Double.init) {
        answerDelay = value
    } else if argument == "--scenario-file", let path = remaining.popFirst() {
        scenarioFile = URL(fileURLWithPath: path)
    } else {
        positional.append(argument)
    }
}
guard positional.count >= 2, let parsed = Scenario(rawValue: positional.count > 2 ? positional[2] : "ok") else {
    FileHandle.standardError.write(Data("usage: fake-assemblyai <port-file> <capture-file> [scenario] [--begin-delay s] [--answer-delay s] [--scenario-file path]\n".utf8))
    exit(2)
}

let defaultScenario = parsed

extension Scenario {
    // Read as each connection opens, so the in-app harness can change one
    // hold's scenario without relaunching the app.
    static var current: Scenario {
        scenarioFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { Scenario(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? defaultScenario
    }
}
let portFile = URL(fileURLWithPath: positional[0])
let captureFile = URL(fileURLWithPath: positional[1])
FileManager.default.createFile(atPath: captureFile.path, contents: nil)
let capture = try FileHandle(forWritingTo: captureFile)

setvbuf(stdout, nil, _IOLBF, 0)
let queue = DispatchQueue(label: "fake-assemblyai")
let bytesPerSecond = 32_000
nonisolated(unsafe) var mints = 0
let expiredText = "Unauthorized Connection: Signature has expired"

func loopback() -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    return parameters
}

func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

final class TokenExchange {
    private let connection: NWConnection
    private var received = Data()

    init(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
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
        let body = received[headEnd.upperBound...]
        guard body.count >= Int(headers["content-length"] ?? "0") ?? 0 else { return nil }

        let (status, answer): (String, [String: Any])
        if Scenario.current == .token401 {
            (status, answer) = ("401 Unauthorized", ["error": "Invalid API key"])
        } else if lines.first != "POST /v1/token HTTP/1.1" {
            (status, answer) = ("404 Not Found", ["error": "expected POST /v1/token, got \(lines.first ?? "")"])
        } else if headers["authorization", default: ""].isEmpty {
            (status, answer) = ("401 Unauthorized", ["error": "no Authorization header"])
        } else if !String(decoding: body, as: UTF8.self).contains(#""product":"streaming""#) {
            (status, answer) = ("400 Bad Request", ["error": "the body does not ask for a streaming token"])
        } else {
            mints += 1
            print("mint \(mints)")
            (status, answer) = ("200 OK", ["token": "fake-token-\(mints)", "expires_in_seconds": 480])
        }
        let content = json(answer)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(content.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + content
    }
}

// Models the measured server: a cursor that starts 0.3 s after Begin and works
// through the received audio at twice real time until it catches up, then
// keeps pace. Turns come only from processed audio. ForceEndpoint takes effect
// at the cursor, not after the queued audio, and processing then stalls until
// Terminate, which processes the rest at once.
final class StreamingSession {
    private static let closeFallback = 1.0
    private static let processingDelay = 0.3
    private static let processingSpeed = 2.0
    private static let turnEndsAtFrame = 15
    private static var count = 0

    private let connection: NWConnection
    private let id: Int
    private let scenario: Scenario
    private let opened = Date()
    private var received: [Int] = []
    private var silent: [Bool] = []
    private var bytes = 0
    private var closing = false
    private let refuses: Bool

    private var processed = 0
    private var processedBytes = 0
    private var wordBytes = 0
    private var cursorFree: Date?
    private var stepping = false
    private var stalled = false
    private var order = 0
    private var openText: String?
    private var answerPending = false
    private var terminateWaiting = false

    // Network.framework hands a server only the upgrade request's headers, not
    // its URL, so the token cannot be read. The second connection counts as
    // presenting the first token when no second mint happened before it.
    init(_ connection: NWConnection) {
        Self.count += 1
        id = Self.count
        scenario = Scenario.current
        refuses = scenario == .expiredOnce && id == 2 && mints == 1
        self.connection = connection
        connection.stateUpdateHandler = { [self] state in
            guard case .ready = state else { return }
            if refuses {
                send(["type": "Error", "error_code": 1008, "error": expiredText])
                close(.protocolCode(.policyViolation), expiredText)
                return
            }
            switch scenario {
            case .close1008:
                send(["type": "Error", "error_code": 1008, "error": "Unauthorized Connection: Invalid API key"])
                close(.protocolCode(.policyViolation), "Unauthorized Connection: Invalid API key")
            case .noBegin:
                break
            case .ok, .silent, .noEndpoint, .noTermination, .token401, .expiredOnce:
                queue.asyncAfter(deadline: .now() + beginDelay) { [self] in
                    send(["type": "Begin", "id": "fake-\(id)", "expires_at": Int(Date().timeIntervalSince1970) + 480])
                    queue.asyncAfter(deadline: .now() + Self.processingDelay) { [self] in
                        cursorFree = Date()
                        step()
                    }
                }
            }
        }
        connection.start(queue: queue)
        read()
    }

    private func read() {
        connection.receiveMessage { [self] content, context, _, error in
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            guard error == nil, let metadata else {
                finish("ended")
                return
            }
            switch metadata.opcode {
            case .binary:
                hear(content ?? Data())
            case .text where content == Data(#"{"type":"ForceEndpoint"}"#.utf8):
                forceEndpoint()
            case .text where content == Data(#"{"type":"Terminate"}"#.utf8):
                terminate()
            case .close:
                finish("closed by the client")
                return
            default:
                break
            }
            read()
        }
    }

    private func hear(_ frame: Data) {
        try? capture.write(contentsOf: frame)
        received.append(frame.count)
        silent.append(frame.allSatisfy { $0 == 0 })
        bytes += frame.count
        guard frame.count % 2 == 0, (1600...32_000).contains(frame.count) else {
            let ms = frame.count * 1000 / bytesPerSecond
            close(.applicationCode(3007), "Input duration violation: \(ms) ms. Expected between 50 and 1000 ms")
            return
        }
        step()
    }

    private func step() {
        guard !stepping, !stalled, let free = cursorFree, processed < received.count else { return }
        stepping = true
        let seconds = Double(received[processed]) / Double(bytesPerSecond)
        let due = max(Date(), free.addingTimeInterval(seconds / Self.processingSpeed))
        queue.asyncAfter(deadline: .now() + due.timeIntervalSinceNow) { [self] in
            stepping = false
            guard !stalled else { return }
            cursorFree = due
            process()
            step()
        }
    }

    private func process() {
        let isSilent = silent[processed]
        processedBytes += received[processed]
        if !isSilent { wordBytes = processedBytes }
        processed += 1
        guard scenario != .silent, !isSilent, processed % 3 == 0 else { return }
        let text = "S\(id) frame \(processed)"
        if processed == Self.turnEndsAtFrame {
            sendTurn(text.lowercased(), formatted: false, end: true)
            endOpenTurn(text)
        } else {
            sendTurn(text, formatted: true, end: false)
            openText = text
        }
    }

    private func forceEndpoint() {
        print("session \(id) force-endpoint at frame \(processed) of \(received.count)")
        stalled = true
        guard scenario != .noEndpoint else { return }
        answerPending = true
        queue.asyncAfter(deadline: .now() + answerDelay) { [self] in
            answerPending = false
            endOpenTurn(openText)
            if terminateWaiting { terminate() }
        }
    }

    private func terminate() {
        guard !answerPending else {
            terminateWaiting = true
            return
        }
        print("session \(id) terminated after \(received.count) frames, \(bytes) bytes")
        stalled = true
        while processed < received.count { process() }
        if openText != nil { endOpenTurn(openText) }
        endOpenTurn(nil)
        guard scenario != .noTermination else { return }
        send([
            "type": "Termination",
            "audio_duration_seconds": Double(bytes) / Double(bytesPerSecond),
            "session_duration_seconds": Date().timeIntervalSince(opened),
        ])
        close(.protocolCode(.normalClosure), "")
    }

    private func endOpenTurn(_ text: String?) {
        sendTurn(text.map { $0 + "." } ?? "", formatted: true, end: true)
        order += 1
        openText = nil
    }

    private func sendTurn(_ text: String, formatted: Bool, end: Bool) {
        let cursor = wordBytes * 1000 / bytesPerSecond
        let words: [[String: Any]] = text.isEmpty ? [] : [["text": "frame", "start": max(0, cursor - 100), "end": cursor]]
        send(["type": "Turn", "turn_order": order, "turn_is_formatted": formatted, "end_of_turn": end, "transcript": text, "words": words])
    }

    private func send(_ message: [String: Any]) {
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: json(message), contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func close(_ code: NWProtocolWebSocket.CloseCode, _ reason: String) {
        guard !closing else { return }
        closing = true
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: Data(reason.utf8), contentContext: context, isComplete: true, completion: .idempotent)
        queue.asyncAfter(deadline: .now() + Self.closeFallback) { [self] in finish("closed by the fake") }
    }

    private func finish(_ how: String) {
        guard connection.state != .cancelled else { return }
        connection.cancel()
        print("session \(id) \(how) after \(received.count) frames, \(bytes) bytes")
    }
}

let tokenListener = try NWListener(using: loopback())
tokenListener.newConnectionHandler = { connection in _ = TokenExchange(connection) }

let socketParameters = loopback()
let webSocket = NWProtocolWebSocket.Options()
webSocket.autoReplyPing = true
socketParameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
let socketListener = try NWListener(using: socketParameters)
socketListener.newConnectionHandler = { connection in _ = StreamingSession(connection) }

func announceWhenReady() {
    guard let token = tokenListener.port, let socket = socketListener.port,
          tokenListener.state == .ready, socketListener.state == .ready
    else { return }
    let line = "token=http://127.0.0.1:\(token)/v1/token socket=ws://127.0.0.1:\(socket)/v3/ws\n"
    try! line.write(to: portFile, atomically: true, encoding: .utf8)
    print("listening \(line)", terminator: "")
}

for listener in [tokenListener, socketListener] {
    listener.stateUpdateHandler = { state in
        if case .failed(let error) = state {
            print("listener failed: \(error)")
            exit(1)
        }
        announceWhenReady()
    }
    listener.start(queue: queue)
}

let parentExit = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: queue)
parentExit.setEventHandler { exit(0) }
parentExit.activate()

dispatchMain()
