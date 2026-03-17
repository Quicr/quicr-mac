// SPDX-FileCopyrightText: Copyright (c) 2027 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

extension QLocationImpl: Comparable {
    public static func < (lhs: QLocationImpl, rhs: QLocationImpl) -> Bool {
        lhs.group < rhs.group || lhs.group == rhs.group && lhs.object < rhs.object
    }

    public static func < (lhs: QLocationImpl, rhs: QLocation) -> Bool {
        lhs.group < rhs.group || lhs.group == rhs.group && lhs.object < rhs.object
    }
}
