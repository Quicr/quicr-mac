// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// MoQ subscribe-namespace handler using libquicr.
final class QSubscribeNamespaceHandler: NSObject, MoQSubscribeNamespaceHandler, QSubscribeNamespaceHandlerCallbacks {
    var statusChangedCallback: MoQSubscribeNamespaceStatusCallback?

    /// The underlying libquicr handler.
    let handler: QSubscribeNamespaceHandlerObjC

    var namespacePrefix: [Data] {
        self.handler.getNamespacePrefix()
    }

    var status: QSubscribeNamespaceHandlerStatus {
        self.handler.getStatus()
    }

    /// Creates a new libquicr subscribe-namespace handler.
    /// - Parameter namespacePrefix: Namespace prefix to subscribe to.
    init(namespacePrefix: [Data]) {
        self.handler = .init(namespacePrefix: namespacePrefix)
        super.init()
        self.handler.setCallbacks(self)
    }

    func statusChanged(_ status: QSubscribeNamespaceHandlerStatus, errorCode: QSubscribeNamespaceErrorCode) {
        self.statusChangedCallback?(status, errorCode, self.namespacePrefix)
    }
}
