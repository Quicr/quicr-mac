class Wrapped<T> {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}

class WrappedOptional<T> {
    var value: T?
    init(_ value: T?) {
        self.value = value
    }
}
