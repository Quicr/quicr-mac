// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import Synchronization

enum TaskCompletionSourceError: Error {
    /// The task was already completed.
    case alreadyCompleted
    /// The task continuation is not set (the task was not been awaited).
    case noContinuation
}

/// TCS can wrap callback APIs to async await (C# TaskCompletionSource).
class TaskCompletionSource<T> {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var isCompleted = false

    }
    private let state: Mutex<State> = .init(.init())

    /// The awaitable task.
    var task: Task<T, Error> {
        Task {
            try await withCheckedThrowingContinuation { continuation in
                self.state.withLock { state in
                    guard !state.isCompleted else {
                        continuation.resume(throwing: TaskCompletionSourceError.alreadyCompleted)
                        return
                    }
                    state.continuation = continuation
                }
            }
        }
    }

    /// Complete the task with a successful result
    /// - Parameter result: The result to complete the task with
    /// - Throws: `TaskCompletionSourceError.alreadyCompleted` if the task has already finished.
    /// - Throws: `TaskCompletionSourceError.noContinuation` if the continuation is not set (task not awaited).
    func setResult(_ result: T) throws {
        try self.state.withLock { state in
            guard !state.isCompleted else {
                throw TaskCompletionSourceError.alreadyCompleted
            }
            guard let continuation = state.continuation else {
                throw TaskCompletionSourceError.noContinuation
            }
            state.isCompleted = true
            state.continuation = nil
            continuation.resume(returning: result)
        }
    }

    /// Complete the task with an error
    /// - Parameter error: The error to complete the task with
    /// - Throws: `TaskCompletionSourceError.alreadyCompleted` if the task has already finished.
    /// - Throws: `TaskCompletionSourceError.noContinuation` if the continuation is not set (task not awaited).
    func setError(_ error: Error) throws {
        try self.state.withLock { state in
            guard !state.isCompleted else {
                throw TaskCompletionSourceError.alreadyCompleted
            }
            guard let continuation = state.continuation else {
                throw TaskCompletionSourceError.noContinuation
            }
            state.isCompleted = true
            state.continuation = nil
            continuation.resume(throwing: error)
        }
    }
}
