// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import Synchronization
import Testing

struct TestMDNSLookup {
    private enum Failure: Error { case expected }

    private final class Source: Sendable {
        let callback = Mutex<AsyncThrowingStream<Int, Error>.Continuation?>(nil)
        let starts = Mutex(0)
        let stops = Mutex(0)
        let started = AsyncStream<Void>.makeStream()

        func start(_ continuation: AsyncThrowingStream<Int, Error>.Continuation) {
            self.starts.withLock { $0 += 1 }
            self.callback.withLock { $0 = continuation }
            self.started.continuation.yield()
        }

        func stop() {
            self.stops.withLock { $0 += 1 }
        }

        func waitUntilStarted() async {
            var iterator = self.started.stream.makeAsyncIterator()
            await iterator.next()
        }
    }

    @Test("The first result wins over repeated callbacks and a later failure")
    func repeatedCallbacks() async throws {
        let source = Source()
        let result: Int = try await MDNSLookup.firstResult { continuation in
            source.start(continuation)
            continuation.yield(42)
            continuation.yield(99)
            continuation.finish(throwing: Failure.expected)
            continuation.yield(100)
            continuation.finish(throwing: Failure.expected)
        } stop: {
            source.stop()
        }
        #expect(result == 42)
        #expect(source.stops.get() == 1)
    }

    @Test("Failure releases the operation and ignores later success")
    func failure() async {
        let source = Source()
        do {
            let _: Int = try await MDNSLookup.firstResult { continuation in
                source.start(continuation)
                continuation.finish(throwing: Failure.expected)
                continuation.yield(42)
            } stop: {
                source.stop()
            }
            Issue.record("Expected resolution to fail")
        } catch {
            #expect(error is Failure)
        }
        #expect(source.stops.get() == 1)
    }

    @Test("Success releases the operation before returning")
    func success() async throws {
        let source = Source()
        let result: Int = try await MDNSLookup.firstResult { continuation in
            source.start(continuation)
            continuation.yield(42)
        } stop: {
            source.stop()
        }
        #expect(result == 42)
        #expect(source.stops.get() == 1)
        source.callback.get()?.yield(99)
        source.callback.get()?.finish(throwing: Failure.expected)
        #expect(source.stops.get() == 1)
    }

    @Test("An already cancelled task never starts discovery")
    func cancelledBeforeStart() async {
        let source = Source()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MDNSLookup.firstResult { continuation in
                source.start(continuation)
            } stop: {
                source.stop()
            }
        }
        switch await task.result {
        case .success:
            Issue.record("Expected cancellation")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        #expect(source.starts.get() == 0)
        #expect(source.stops.get() == 0)
    }

    @Test("Cancellation during setup or while waiting releases discovery", arguments: [true, false])
    func cancellation(duringSetup: Bool) async {
        let source = Source()
        let task = Task {
            let result: Int = try await MDNSLookup.firstResult { continuation in
                source.start(continuation)
                if duringSetup {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            } stop: {
                source.stop()
            }
            return result
        }
        await source.waitUntilStarted()
        if !duringSetup {
            task.cancel()
        }
        switch await task.result {
        case .success:
            Issue.record("Expected cancellation")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        #expect(source.stops.get() == 1)
        source.callback.get()?.yield(42)
        source.callback.get()?.finish(throwing: Failure.expected)
        #expect(source.stops.get() == 1)
    }

    @Test("Concurrent success, failure and cancellation complete once", arguments: 0..<25)
    func competingCallbacks(iteration: Int) async {
        let source = Source()
        let task = Task {
            try await MDNSLookup.firstResult { continuation in
                source.start(continuation)
            } stop: {
                source.stop()
            }
        }
        await source.waitUntilStarted()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { source.callback.get()?.yield(iteration) }
            group.addTask { source.callback.get()?.finish(throwing: Failure.expected) }
            group.addTask { task.cancel() }
        }
        switch await task.result {
        case .success(let value):
            #expect(value == iteration)
        case .failure(let error):
            #expect(error is CancellationError || error is Failure)
        }
        #expect(source.stops.get() == 1)
    }
}
