// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// C mapping for <transport/transport.h> qtransport::TransportConfig.

#ifndef TransportConfig_h
#define TransportConfig_h

#include <stdbool.h>
#include <stdint.h>

struct TransportConfig
{
    /// QUIC TLS certificate to use
    const char *tls_cert_filename;
    /// QUIC TLS private key to use
    const char *tls_key_filename;
    /// Initial queue size to reserve upfront
    const uint32_t time_queue_init_queue_size;
    /// Max duration for the time queue in milliseconds
    const uint32_t time_queue_max_duration;
    /// The bucket interval in milliseconds
    const uint32_t time_queue_bucket_interval;
    /// Receive queue size
    const uint32_t time_queue_rx_size;
    /// Enable debug logging/processing
    const bool debug;
    /// QUIC congestion control minimum size (default is 128k)
    const uint64_t quic_cwin_minimum;
    /// QUIC wifi shadow RTT in microseconds
    const uint32_t quic_wifi_shadow_rtt_us;
    /// QUIC idle timeout for connection(s) in milliseconds
    const uint64_t idle_timeout_ms;
    /// Use Reset and wait strategy for congestion control
    const bool use_reset_wait_strategy;
    /// Use BBR if true, NewReno if false
    const bool use_bbr;
    /// QUIC LOG file location path, null terminated cstring
    const char *quic_qlog_path;
    /// Lowest priority that will not be bypassed from pacing/CC in picoquic
    const uint8_t quic_priority_limit;
    // Max number of active QUIC connections per QUIC instance
    const size_t max_connections;
    // Enable SSL key logging for QUIC connections
    const bool ssl_keylog;
    // QUIC UDP socket buffer size
    const size_t socket_buffer_size;
};
typedef struct TransportConfig TransportConfig;

#endif /* TransportConfig_h */
