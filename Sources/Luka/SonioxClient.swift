import Foundation
import LukaCore

@MainActor
final class SonioxClient {
    enum Event {
        case connected
        /// `baseMs` is where this stream's audio began on the shared audio clock.
        case response(SonioxResponse, baseMs: Int)
        case failed(SonioxError)
        /// The socket dropped; the client is opening a replacement stream.
        case reconnecting(attempt: Int)
    }

    enum SonioxError: Error, Equatable {
        case invalidKey, noCredits, rateLimited, config(String), network(String)
    }

    private static let maxReconnects = 5

    var onEvent: (Event) -> Void = { _ in }
    var carryover: () -> String? = { nil }
    /// Milliseconds of audio sent so far, shared by every stream so their token times line up.
    var clock: () -> Int = { 0 }
    let lane: Int

    private var baseMs = 0

    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var config: SessionConfig?
    private var apiKey = ""
    private var endpoint = SonioxRegion.us.websocketURL
    private var attempts = 0
    private var lastAudio = Date.distantPast
    private var keepalive: Timer?

    var isOpen: Bool { task != nil }

    init(lane: Int = 0) {
        self.lane = lane
    }

    func connect(apiKey: String, region: SonioxRegion, config: SessionConfig) {
        self.apiKey = apiKey
        endpoint = region.websocketURL
        self.config = config
        attempts = 0
        open(carryover: carryover())
    }

    private func open(carryover: String?) {
        guard let config else { return }
        closeSocket()
        let gen = generation
        let task = URLSession.shared.webSocketTask(with: endpoint)
        self.task = task
        baseMs = clock()
        task.resume()
        task.send(.string(config.json(apiKey: apiKey, carryover: carryover, lane: lane))) { [weak self] error in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if let error { self.dropped(error) } else { self.onEvent(.connected) }
            }
        }
        receive(task, gen: gen)
        keepalive = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendKeepaliveIfIdle() }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, gen: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text)
                    if gen == self.generation { self.receive(task, gen: gen) }
                case .success:
                    self.receive(task, gen: gen)
                case .failure(let error):
                    self.dropped(error)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let response = try? SonioxResponse.decode(text) else { return }
        if let code = response.errorCode {
            let message = response.errorMessage ?? ""
            switch code {
            case 401: fail(.invalidKey)
            case 402: fail(.noCredits)
            case 429: fail(.rateLimited)
            case 400: fail(.config(message))
            default: dropped(NSError(domain: "Soniox", code: code, userInfo: [NSLocalizedDescriptionKey: message]))
            }
            return
        }
        attempts = 0
        onEvent(.response(response, baseMs: baseMs))
        if response.finished { closeSocket() }
    }

    private func dropped(_ error: Error) {
        guard config != nil else { return }
        if attempts >= Self.maxReconnects {
            fail(.network(error.localizedDescription))
            return
        }
        attempts += 1
        closeSocket()
        onEvent(.reconnecting(attempt: attempts))
        let delay = min(8.0, pow(2.0, Double(attempts - 1)))
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation, self.config != nil else { return }
            self.open(carryover: self.carryover())
        }
    }

    private func fail(_ error: SonioxError) {
        config = nil
        closeSocket()
        onEvent(.failed(error))
    }

    func send(audio: Data) {
        guard let task else { return }
        lastAudio = .now
        task.send(.data(audio)) { _ in }
    }

    /// Flush pending words as final without ending the stream.
    func finalize() {
        task?.send(.string(#"{"type":"finalize"}"#)) { _ in }
    }

    private func sendKeepaliveIfIdle() {
        guard let task, Date.now.timeIntervalSince(lastAudio) > 4 else { return }
        task.send(.string(#"{"type":"keepalive"}"#)) { _ in }
    }

    func disconnect() {
        config = nil
        if let task {
            task.send(.string("")) { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { task.cancel(with: .normalClosure, reason: nil) }
        }
        generation += 1
        task = nil
        keepalive?.invalidate()
        keepalive = nil
    }

    private func closeSocket() {
        generation += 1
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        keepalive?.invalidate()
        keepalive = nil
    }
}

/// The Soniox streams one session needs: one normally, one per language in three-way mode.
/// Every stream hears the same audio; lane 0 carries the transcript.
@MainActor
final class SonioxStreams {
    private static let maxLanes = 3
    private let clients: [SonioxClient]
    private var active = 1
    private var sentMs = 0

    var onEvent: (_ lane: Int, SonioxClient.Event) -> Void = { _, _ in }
    var carryover: () -> String? = { nil } {
        didSet { clients.forEach { $0.carryover = carryover } }
    }

    init() {
        clients = (0..<Self.maxLanes).map { SonioxClient(lane: $0) }
        for client in clients {
            client.onEvent = { [weak self] in self?.onEvent(client.lane, $0) }
            client.clock = { [weak self] in self?.sentMs ?? 0 }
        }
    }

    var isOpen: Bool { clients[0].isOpen }

    func connect(apiKey: String, region: SonioxRegion, config: SessionConfig) {
        disconnect()
        active = min(config.lanes, Self.maxLanes)
        for client in clients.prefix(active) { client.connect(apiKey: apiKey, region: region, config: config) }
    }

    func send(audio: Data) {
        // The clock runs whether or not a stream is open, so a stream that reconnects stays aligned.
        sentMs += audio.count / 32
        for client in clients.prefix(active) { client.send(audio: audio) }
    }

    func finalize() {
        for client in clients.prefix(active) { client.finalize() }
    }

    func disconnect() {
        for client in clients where client.isOpen { client.disconnect() }
    }
}
