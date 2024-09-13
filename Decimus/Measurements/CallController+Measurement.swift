// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

extension MoqCallController {
    actor MoqCallControllerMeasurement: Measurement {
        let id = UUID()
        var name: String = "quic-connection"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        init(endpointId: String) {
            self.tags["endpoint_id"] = endpointId
            self.tags["source"] = "client"
        }

        func setRelayId(_ relayId: String) {
            self.tags["relay_id"] = relayId
        }

        func record(_ metrics: QConnectionMetrics) {
            // TODO: Use the proper sampled time.
            let time = Date.now
            self.record("rtt_us", values: metrics.quic.rtt_us, time: time)
            self.record(field: "tx_lost_pkts", value: metrics.quic.tx_lost_pkts as AnyObject, timestamp: time)
            self.record(field: "tx_dgram_lost", value: metrics.quic.tx_dgram_lost as AnyObject, timestamp: time)
            self.record(field: "tx_timer_losses", value: metrics.quic.tx_timer_losses as AnyObject, timestamp: time)
            self.record(field: "tx_spurious_losses", value: metrics.quic.tx_spurious_losses as AnyObject, timestamp: time)
            self.record(field: "tx_retransmits", value: metrics.quic.tx_retransmits as AnyObject, timestamp: time)
            self.record(field: "tx_congested", value: metrics.quic.tx_congested as AnyObject, timestamp: time)
            self.record("tx_rate_bps", values: metrics.quic.tx_rate_bps, time: time)
            self.record("tx_cwin_bytes", values: metrics.quic.tx_cwin_bytes, time: time)
            self.record("tx_in_transit_bytes", values: metrics.quic.tx_in_transit_bytes, time: time)
            self.record(field: "cwin_congested", value: metrics.quic.cwin_congested as AnyObject, timestamp: time)
            self.record(field: "prev_cwin_congested", value: metrics.quic.prev_cwin_congested as AnyObject, timestamp: time)
            self.record("rx_rate_bps", values: metrics.quic.rx_rate_bps, time: time)
            self.record("stt_us", values: metrics.quic.srtt_us, time: time)
            self.record(field: "rx_dgrams", value: metrics.quic.rx_dgrams as AnyObject, timestamp: time)
            self.record(field: "rx_dgrams_bytes", value: metrics.quic.rx_dgrams_bytes as AnyObject, timestamp: time)
            self.record(field: "tx_dgram_cb", value: metrics.quic.tx_dgram_cb as AnyObject, timestamp: time)
            self.record(field: "tx_dgram_ack", value: metrics.quic.tx_dgram_ack as AnyObject, timestamp: time)
            self.record(field: "tx_dgram_spurious", value: metrics.quic.tx_dgram_spurious as AnyObject, timestamp: time)
            self.record(field: "tx_dgram_drops", value: metrics.quic.tx_dgram_drops as AnyObject, timestamp: time)
        }

        private func record(_ prefix: String, values: QMinMaxAvg, time: Date) {
            self.record(field: "\(prefix)_min", value: values.min as AnyObject, timestamp: time)
            self.record(field: "\(prefix)_max", value: values.max as AnyObject, timestamp: time)
            self.record(field: "\(prefix)_avg", value: values.avg as AnyObject, timestamp: time)
        }
    }
}
