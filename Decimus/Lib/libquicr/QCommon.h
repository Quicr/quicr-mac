// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QCommon_h
#define QCommon_h

#import <Foundation/Foundation.h>

typedef NS_ENUM(uint8_t, QGroupOrder) {
    kQGroupOrderOriginalPublisherOrder,
    kQGroupOrderAscending,
    kQGroupOrderDescending
};

typedef NS_ENUM(uint64_t, QFilterType) {
    kQFilterTypeNone,
    kQFilterTypeLatestGroup,
    kQFilterTypeLatestObject,
    kQFilterTypeAbsoluteStart,
    kQFilterTypeAbsoluteRange,
};

typedef struct QMinMaxAvg {
    uint64_t min;
    uint64_t max;
    uint64_t avg;
    uint64_t value_sum;
    uint64_t value_count;
} QMinMaxAvg;

typedef struct QObjectHeaders {
    uint64_t groupId;
    uint64_t objectId;
    uint64_t payloadLength;
    const uint8_t* priority;
    const uint16_t* ttl;
} QObjectHeaders;

#ifdef __cplusplus
#include <quicr/detail/messages.h>
static NSMutableDictionary<NSNumber*, NSArray<NSData*>*>* convertExtensions(const std::optional<quicr::Extensions>& extensions) {
    if (!extensions.has_value()) {
        return nil;
    }

    NSMutableDictionary<NSNumber*, NSArray<NSData*>*>* result = [NSMutableDictionary dictionary];
    for (const auto& kvps : *extensions) {
        NSNumber* key = @(kvps.first);
        NSMutableArray<NSData*>* dataArray = [NSMutableArray arrayWithCapacity:kvps.second.size()];
        for (const auto& kvp : kvps.second) {
            NSData* data = [[NSData alloc] initWithBytesNoCopy:(void*)kvp.data() length:kvp.size() deallocator:nil];
            [dataArray addObject:data];
        }
        [result setObject:dataArray forKey:key];
    }
    return result;
}
#endif

#endif
