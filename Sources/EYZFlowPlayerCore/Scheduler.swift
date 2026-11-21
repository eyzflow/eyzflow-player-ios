import Foundation

/// A pending timer from a [`PlaybackScheduler`].
@MainActor
public protocol PlaybackTimer: AnyObject {
    /// Stops the timer. An action already running carries on.
    func cancel()
}

/// The timers behind token renewal, the session heartbeat and the beats.
/// [`TaskScheduler`] in apps; a scheduler with a manual clock in tests.
@MainActor
public protocol PlaybackScheduler: AnyObject {
    /// Runs `action` once, after `delay`.
    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor () async -> Void
    ) -> any PlaybackTimer

    /// Runs `action` every `interval`, the first time one interval from now,
    /// like Dart's `Timer.periodic`: a tick does not wait for the last one's
    /// action to finish.
    func scheduleRepeating(
        every interval: Duration,
        _ action: @escaping @MainActor () async -> Void
    ) -> any PlaybackTimer
}

/// [`PlaybackScheduler`] on `Task.sleep`.
@MainActor
public final class TaskScheduler: PlaybackScheduler {
    public init() {}

    public func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor () async -> Void
    ) -> any PlaybackTimer {
        TaskTimer(
            Task { @MainActor in
                do { try await Task.sleep(for: delay) } catch { return }
                // A separate task, so cancelling the timer does not cancel a
                // request the action has started.
                Task { @MainActor in await action() }
            }
        )
    }

    public func scheduleRepeating(
        every interval: Duration,
        _ action: @escaping @MainActor () async -> Void
    ) -> any PlaybackTimer {
        TaskTimer(
            Task { @MainActor in
                while true {
                    do { try await Task.sleep(for: interval) } catch { return }
                    Task { @MainActor in await action() }
                }
            }
        )
    }
}

@MainActor
private final class TaskTimer: PlaybackTimer {
    private let task: Task<Void, Never>

    init(_ task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

/// Milliseconds on a monotonic clock.
public typealias MonotonicClock = @MainActor () -> Int

/// Milliseconds since the clock was made.
public func makeMonotonicClock() -> MonotonicClock {
    let clock = ContinuousClock()
    let start = clock.now
    return { (clock.now - start).inMilliseconds }
}
