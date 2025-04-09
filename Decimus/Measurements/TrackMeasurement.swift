// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

class TrackMeasurement: Measurement {
    enum PubSub {
        case publish
        case subscribe
        case fetch
    }

    init(type: PubSub, endpointId: String, relayId: String, namespace: String) {
        var tags: [String: String] = [:]
        tags["type"] = switch type {
        case .publish:
            "publish"
        case .subscribe:
            "subscribe"
        case .fetch:
            "fetch"
        }
        tags["endpoint_id"] = endpointId
        tags["relay_id"] = relayId
        tags["source"] = "client"
        tags["namespace"] = namespace
        super.init(name: "quic-dataFlow", tags: tags)
    }

    func record(_ metrics: QPublishTrackMetrics) {
        let time = Date.now
        record(field: "tx_bytes", value: metrics.bytesPublished as AnyObject, timestamp: time)
        record(field: "tx_objs", value: metrics.objectsPublished as AnyObject, timestamp: time)
        record("tx_queue_size", values: metrics.quic.tx_queue_size, time: time)
        record("tx_callback_ms", values: metrics.quic.tx_callback_ms, time: time)
        record("tx_object_duration_us", values: metrics.quic.tx_object_duration_us, time: time)
        record(field: "tx_buffer_drops", value: metrics.quic.tx_buffer_drops as AnyObject, timestamp: time)
        record(field: "tx_queue_discards", value: metrics.quic.tx_queue_discards as AnyObject, timestamp: time)
        record(field: "tx_queue_expired", value: metrics.quic.tx_queue_expired as AnyObject, timestamp: time)
        record(field: "tx_delayed_callback", value: metrics.quic.tx_delayed_callback as AnyObject, timestamp: time)
        record(field: "tx_reset_wait", value: metrics.quic.tx_reset_wait as AnyObject, timestamp: time)
    }

    func record(_ metrics: QSubscribeTrackMetrics) {
        let time = Date.now
        record(field: "rx_bytes", value: metrics.bytesReceived as AnyObject, timestamp: time)
        record(field: "rx_objs", value: metrics.objectsReceived as AnyObject, timestamp: time)
    }
}
