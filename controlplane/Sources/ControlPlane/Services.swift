import Fluent
import Foundation
import NIOConcurrencyHelpers
import Vapor

/// Shared state of one control plane process.
final class Maccheri: Sendable {
    let settings: Settings
    let clock: AppClock
    let provisioner: (any RunnerProvisioner)?
    let workAvailable = WorkNotifier()
    let signaling = SignalHub()
    /// Serializes handing out work and redeeming invites: one piece of work goes to one host,
    /// one invite makes one user.
    let assignment = AsyncLock()

    init(settings: Settings, clock: AppClock, provisioner: (any RunnerProvisioner)?) {
        self.settings = settings
        self.clock = clock
        self.provisioner = provisioner
    }

    var now: Date { clock.now() }
}

extension Application {
    private struct MaccheriKey: StorageKey { typealias Value = Maccheri }

    var maccheri: Maccheri {
        get {
            guard let maccheri = storage[MaccheriKey.self] else { fatalError("configure(_:) has not run") }
            return maccheri
        }
        set { storage[MaccheriKey.self] = newValue }
    }
}

extension Request {
    var maccheri: Maccheri { application.maccheri }
}

/// Injectable time, so tests can move it forward.
struct AppClock: Sendable {
    var now: @Sendable () -> Date

    static let system = AppClock { Date() }
}

/// Wakes long-polling agents when a session or a CI job is queued.
final class WorkNotifier: Sendable {
    private enum Waiter {
        case waiting(CheckedContinuation<Void, Never>)
        /// Woken before its continuation was registered.
        case woken
    }
    private let waiters = NIOLockedValueBox<[UUID: Waiter]>([:])

    func notifyAll() {
        let woken = waiters.withLockedValue { waiters in
            defer { waiters.removeAll() }
            return waiters.values.compactMap { if case .waiting(let continuation) = $0 { continuation } else { nil } }
        }
        woken.forEach { $0.resume() }
    }

    /// Returns on the next ``notifyAll()`` or after `timeout`, whichever comes first.
    func wait(timeout: Duration) async {
        let id = UUID()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let alreadyWoken = self.waiters.withLockedValue { waiters in
                        if case .woken = waiters[id] {
                            waiters[id] = nil
                            return true
                        }
                        waiters[id] = .waiting(continuation)
                        return false
                    }
                    if alreadyWoken { continuation.resume() }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { self.wake(id) }
            }
            // Woken by `notifyAll`: stop the timer. The group then waits for both children.
            await group.next()
            group.cancelAll()
        }
    }

    private func wake(_ id: UUID) {
        let continuation = waiters.withLockedValue { waiters -> CheckedContinuation<Void, Never>? in
            switch waiters[id] {
            case .waiting(let continuation):
                waiters[id] = nil
                return continuation
            case .woken:
                return nil
            case nil:
                waiters[id] = .woken
                return nil
            }
        }
        continuation?.resume()
    }
}

/// A mutex for async code: unlike an actor, it is held across suspension points.
final class AsyncLock: Sendable {
    private struct State {
        var locked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = NIOLockedValueBox(State())

    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }

    private func lock() async {
        await withCheckedContinuation { continuation in
            let acquired = state.withLockedValue { state in
                if state.locked {
                    state.waiters.append(continuation)
                    return false
                }
                state.locked = true
                return true
            }
            if acquired { continuation.resume() }
        }
    }

    private func unlock() {
        let next = state.withLockedValue { state -> CheckedContinuation<Void, Never>? in
            if state.waiters.isEmpty {
                state.locked = false
                return nil
            }
            return state.waiters.removeFirst() // stays locked, ownership passes on
        }
        next?.resume()
    }
}
