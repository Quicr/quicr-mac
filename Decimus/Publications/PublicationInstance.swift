// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Common interface for all publication types backed by a ``MoQSink``.
protocol PublicationInstance: AnyObject {
    /// Sink responsible for publishing media objects.
    var sink: MoQSink { get }
}
