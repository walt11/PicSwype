import SwiftUI

@MainActor final class MatchQueue: ObservableObject {
    struct Key: Hashable {
        let pair: String
        let source: PhotoSource
        let id: String
    }
    enum Outcome: Equatable {
        case found(LinkedPhoto), noMatch, unavailable
    }

    static let windowSize = 5
    private var lookup: (@MainActor (Key) async throws -> LinkedPhoto?)?
    private var order: [Key] = []
    private var running: [Key: Task<Void, Never>] = [:]
    @Published private(set) var results: [Key: Outcome] = [:]

    func update(_ keys: [Key], find: @escaping @MainActor (Key) async throws -> LinkedPhoto?) {
        lookup = find
        order = Array(keys.prefix(Self.windowSize))
        for key in Array(running.keys) where !order.contains(key) {
            running.removeValue(forKey: key)?.cancel()
        }
        if results.keys.contains(where: { !order.contains($0) }) {
            results = results.filter { order.contains($0.key) }
        }
        startAvailable()
    }

    private func startAvailable() {
        guard let find = lookup else { return }
        for key in order where running.count < 2 && running[key] == nil && results[key] == nil {
            running[key] = Task {
                guard !Task.isCancelled else { return }
                let outcome: Outcome
                do { outcome = try await find(key).map(Outcome.found) ?? .noMatch }
                catch { outcome = .unavailable }
                guard !Task.isCancelled else { return }
                results[key] = outcome
                running.removeValue(forKey: key)
                startAvailable()
            }
        }
    }

    func clear() {
        running.values.forEach { $0.cancel() }
        running.removeAll()
        results.removeAll()
        order.removeAll()
        lookup = nil
    }
}
