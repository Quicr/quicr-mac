/// C mapping for <transport/transport.h> qtransport::TransportConfig.

#ifndef TransportConfig_h
#define TransportConfig_h

#include <stdbool.h>
#include <stdint.h>

struct TransportConfig
{
  char *tls_cert_filename;                /// QUIC TLS certificate to use
  char *tls_key_filename;                 /// QUIC TLS private key to use
  uint32_t time_queue_init_queue_size;    /// Initial queue size to reserve upfront
  uint32_t time_queue_max_duration;       /// Max duration for the time queue in milliseconds
  uint32_t time_queue_bucket_interval;    /// The bucket interval in milliseconds
  uint32_t time_queue_size_rx;            /// Receive queue size
  bool debug;                             /// Enable debug logging/processing
  uint64_t quic_cwin_minimum;             /// QUIC congestion control minimum size (default is 128k)
  uint32_t quic_wifi_shadow_rtt_us;       /// QUIC wifi shadow RTT in microseconds
  uint64_t pacing_decrease_threshold_Bps; /// QUIC pacing rate decrease threshold for notification in Bps
  uint64_t pacing_increase_threshold_Bps; /// QUIC pacing rate increase threshold for notification in Bps
  uint64_t idle_timeout_ms;               /// QUIC idle timeout for connection(s) in milliseconds
};
typedef struct TransportConfig TransportConfig;

#endif /* TransportConfig_h */
