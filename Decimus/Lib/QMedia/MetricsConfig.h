#ifndef MetricsConfig_h
#define MetricsConfig_h

#include <stdbool.h>
#include <stdint.h>

struct QuicrMetricsConfig {
    const char* metrics_namespace;
    uint8_t priority;
    uint16_t ttl;
};
typedef struct QuicrMetricsConfig QuicrMetricsConfig;

#endif /* MetricsConfig_h */
