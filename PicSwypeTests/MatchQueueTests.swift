import XCTest
@testable import PicSwype

@MainActor final class MatchQueueTests: XCTestCase {
    func testAdvanceReusesQueuedWorkAndSchedulesNewCards() async {
        let queue = MatchQueue()
        let keys = (0..<6).map { MatchQueue.Key(pair: "test", source: .immich, id: String($0)) }
        var calls: [String] = []
        var gates: [String: CheckedContinuation<Void, Never>] = [:]
        func enqueue(_ window: [MatchQueue.Key]) {
            queue.update(window) { key in
                XCTAssertTrue(window.contains(key))
                calls.append(key.id)
                await withCheckedContinuation { gates[key.id] = $0 }
                return nil
            }
        }
        enqueue(Array(keys.prefix(5)))
        await Task.yield()
        XCTAssertEqual(Set(calls), ["0","1"])
        gates.removeValue(forKey: "0")?.resume()
        for _ in 0..<100 where gates["2"] == nil { await Task.yield() }
        enqueue(Array(keys.dropFirst()))
        for id in 1...5 {
            for _ in 0..<100 where gates[String(id)] == nil { await Task.yield() }
            gates.removeValue(forKey: String(id))?.resume()
        }
        for _ in 0..<100 where queue.results.count != 5 { await Task.yield() }
        XCTAssertEqual(calls.sorted(), keys.map(\.id))
        XCTAssertEqual(queue.results.count, 5)
        XCTAssertEqual(queue.results[keys[1]], .noMatch)
        XCTAssertNil(queue.results[keys[0]])
        queue.clear()
    }
}
