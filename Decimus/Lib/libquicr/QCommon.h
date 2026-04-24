// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QCommon_h
#define QCommon_h

#import <Foundation/Foundation.h>

typedef NS_ENUM(uint8_t, QGroupOrder) {
    kQGroupOrderOriginalPublisherOrder = 0x00,
    kQGroupOrderAscending = 0x01,
    kQGroupOrderDescending = 0x02
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

typedef NS_ENUM(uint64_t, QObjectStatus) {
    kQObjectStatusAvailable = 0x0,
    kQObjectStatusDoesNotExist = 0x1,
    kQObjectStatusEndOfGroup = 0x3,
    kQObjectStatusEndOfTrack = 0x4,
    kQObjectStatusEndOfSubGroup = 0x5,
};

typedef NS_ENUM(uint8_t, QSubgroupIdMode) {
    kQSubgroupIdModeIsZero,
    kQSubgroupIdModeSetFromFirstObject,
    kQSubgroupIdModeExplicit,
};

@interface QStreamHeaderProperties : NSObject
@property (nonatomic, readonly) bool extensions;
@property (nonatomic, readonly) QSubgroupIdMode subgroupIdMode;
@property (nonatomic, readonly) bool endOfGroup;
@property (nonatomic, readonly) bool defaultPriority;
-(instancetype _Nonnull) initWithExtensions: (bool) extensions
                             subgroupIdMode: (QSubgroupIdMode) subgroupIdMode
                                 endOfGroup: (bool) endOfGroup
                            defaultPriority: (bool) defaultPriority;
@end

typedef struct QObjectHeaders {
    const uint64_t groupId;
    const uint64_t subgroupId;
    const uint64_t objectId;
    const uint64_t payloadLength;
    const QObjectStatus status;
    const uint8_t* _Nullable priority;
    const uint16_t* _Nullable ttl;
} QObjectHeaders;

#ifdef __cplusplus
#include <quicr/detail/messages.h>

static QStreamHeaderProperties* _Nullable convertStreamHeaderProperties(const std::optional<quicr::messages::StreamHeaderProperties>& props) {
    if (!props.has_value()) return nil;
    return [[QStreamHeaderProperties alloc] initWithExtensions:props->extensions
                                               subgroupIdMode:static_cast<QSubgroupIdMode>(props->subgroup_id_mode)
                                                   endOfGroup:props->end_of_group
                                              defaultPriority:props->default_priority];
}

static quicr::messages::StreamHeaderProperties convertStreamHeaderProperties(QStreamHeaderProperties* _Nonnull props) {
    return quicr::messages::StreamHeaderProperties {
        props.extensions,
        static_cast<quicr::messages::SubgroupIdType>(props.subgroupIdMode),
        props.endOfGroup,
        props.defaultPriority,
    };
}

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
