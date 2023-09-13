/// C mapping for <transport/transport.h> qtransport::TransportConfig.

#ifndef TransportConfig_h
#define TransportConfig_h

#include <stdbool.h>
#include <stdint.h>

struct TransportConfig
{
  const char *tls_cert_filename;                /// QUIC TLS certificate to use
  const char *tls_key_filename;                 /// QUIC TLS private key to use
  const uint32_t time_queue_init_queue_size;    /// Initial queue size to reserve upfront
  const uint32_t time_queue_max_duration;       /// Max duration for the time queue in milliseconds
  const uint32_t time_queue_bucket_interval;    /// The bucket interval in milliseconds
  const uint32_t time_queue_size_rx;            /// Receive queue size
  bool debug;                                   /// Enable debug logging/processing
};
typedef struct TransportConfig TransportConfig;

#endif /* TransportConfig_h */
