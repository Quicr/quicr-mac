import DequeModule

class SlidingWindow<T: Comparable> {
    private var values: Deque<(timestamp: Date, value: T)> = []
    private let length: TimeInterval

    init(length: TimeInterval) {
        self.length = length
    }

    func add(timestamp: Date, value: T) {
        // Remove values that are too old.
        while let first = self.values.first,
              timestamp.timeIntervalSince(first.timestamp) > self.length {
            _ = self.values.popFirst()
        }

        // Remove anything smaller than this value.
        while let last = self.values.last,
              last.value <= value {
            _ = self.values.popLast()
        }

        self.values.append((timestamp, value))
    }

    func max() -> T? {
        self.values.first?.value
    }
}

class SlidingTimeWindow {
    private let window: SlidingWindow<TimeInterval>
    private var lastSubmit: Date?

    init(length: TimeInterval) {
        self.window = .init(length: length)
    }

    func add(timestamp: Date) {
        if let lastSubmit = self.lastSubmit {
            let elapsed = timestamp.timeIntervalSince(lastSubmit)
            self.window.add(timestamp: timestamp, value: elapsed)
        }
        self.lastSubmit = timestamp
    }

    func max() -> TimeInterval? {
        self.window.max()
    }
}
