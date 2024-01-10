/// Allows a value type to be wrapped as a reference type.
class RefWrapper<T> {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}
