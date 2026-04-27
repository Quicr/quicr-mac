// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QTrackFilter_h
#define QTrackFilter_h

#import <Foundation/Foundation.h>

@interface QTrackFilterObjC : NSObject
@property (nonatomic, readonly) uint64_t propertyType;
@property (nonatomic, readonly) uint64_t maxTracksSelected;
@property (nonatomic, readonly) uint64_t timeout;
- (id _Nonnull)initWithPropertyType:(uint64_t)propertyType
                  maxTracksSelected:(uint64_t)maxTracksSelected
                            timeout:(uint64_t)timeout;
@end

#ifdef __cplusplus
#include <quicr/detail/ctrl_message_types.h>

[[maybe_unused]]
static quicr::messages::TrackFilter trackFilterConvert(QTrackFilterObjC* _Nonnull filter) {
    return {
        .property_type = filter.propertyType,
        .max_tracks_selected = filter.maxTracksSelected,
        .timeout = filter.timeout
    };
}

[[maybe_unused]]
static QTrackFilterObjC* _Nonnull trackFilterConvert(const quicr::messages::TrackFilter& filter) {
    return [[QTrackFilterObjC alloc] initWithPropertyType:filter.property_type
                                        maxTracksSelected:filter.max_tracks_selected
                                                  timeout:filter.timeout];
}
#endif

#endif /* QTrackFilter_h */
