import Foundation
import LukaCore

@MainActor
final class SonioxClient {
    enum Event {
        case connected
        case response(SonioxResponse)
        case failed(SonioxError)
        /// The socket dropped; the client is opening a replacement stream.
        case reconnecting(attempt: Int)
    }

    enum SonioxError: Error, Equatable {
        case invalidKey, noCredits, rateLimited, config(String), network(String)
    }

    private static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private static let maxReconnects = 5

    var onEvent: (Event) -> Void = { _ in }
    var carryover: () -> String? = { nil }

    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var config: SessionConfig?
    private var apiKey = ""
    private var attempts = 0
    private var lastAudio = Date.distantPast
    private var keepalive: Timer?

    var isOpen: Bool { task != nil }

    func connect(apiKey: String, config: SessionConfig) {
        self.apiKey = apiKey
        self.config = config
        attempts = 0
        open(carryover: nil)
    }

    private func open(carryover: String?) {
        guard let config else { return }
        closeSocket()
        let gen = generation
        let task = URLSession.shared.webSocketTask(with: Self.endpoint)
        self.task = task
        task.resume()
        task.send(.string(config.json(apiKey: apiKey, carryover: carryover))) { [weak self] error in
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
        onEvent(.response(response))
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
