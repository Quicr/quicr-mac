// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

class WrappedOptional<T> {
    var value: T?
    init(_ value: T?) {
        self.value = value
    }
}
