// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QCommon_h
#define QCommon_h

#import <Foundation/Foundation.h>
#ifdef __cplusplus
#include <quicr/track_name.h>
#endif

typedef struct QMinMaxAvg {
    uint64_t min;
    uint64_t max;
    uint64_t avg;
    uint64_t value_sum;
    uint64_t value_count;
} QMinMaxAvg;

typedef struct QFullTrackName
{
    const char* nameSpace;
    size_t nameSpaceLength;
    const char* name;
    size_t nameLength;
} QFullTrackName;

typedef struct QObjectHeaders {
    uint64_t groupId;
    uint64_t objectId;
    uint64_t payloadLength;
    const uint8_t* priority;
    const uint16_t* ttl;
} QObjectHeaders;


#ifdef __cplusplus
static quicr::FullTrackName ftnConvert(QFullTrackName qFtn) {
    const auto nameSpace = std::vector<std::uint8_t>(qFtn.nameSpace, qFtn.nameSpace + qFtn.nameSpaceLength);
    std::vector<std::vector<std::uint8_t>> tuple = { nameSpace };
    return {
        .name_space = quicr::TrackNamespace(tuple),
        .name = std::vector<std::uint8_t>(qFtn.name, qFtn.name + qFtn.nameLength)
    };
}
#endif
#endif
