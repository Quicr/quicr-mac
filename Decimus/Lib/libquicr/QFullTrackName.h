// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QFullTrackName_h
#define QFullTrackName_h

#import <Foundation/Foundation.h>
#ifdef __cplusplus
#include <quicr/track_name.h>
#endif

@protocol QFullTrackName
@property (readonly, strong) NSData* _Nonnull name;
@property (readonly, strong) NSData* _Nonnull nameSpace;
@end

@interface QFullTrackNameImpl: NSObject<QFullTrackName>
@property (strong) NSData* _Nonnull name;
@property (strong) NSData* _Nonnull nameSpace;
-(instancetype _Nonnull) initWithNamespace: (NSData* _Nonnull) nameSpace name: (NSData* _Nonnull) name;
@end

#ifdef __cplusplus
static quicr::FullTrackName ftnConvert(id<QFullTrackName> _Nonnull qFtn) {
    const auto nameSpaceBytes = reinterpret_cast<const std::uint8_t*>(qFtn.nameSpace.bytes);
    const auto nameBytes = reinterpret_cast<const std::uint8_t*>(qFtn.name.bytes);
    return {
        .name_space = std::vector<std::uint8_t>(nameSpaceBytes, nameSpaceBytes + qFtn.nameSpace.length),
        .name = std::vector<std::uint8_t>(nameBytes, nameBytes + qFtn.name.length)
    };
}
#endif

#endif
