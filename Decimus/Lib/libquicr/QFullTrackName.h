// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QFullTrackName_h
#define QFullTrackName_h

#import <Foundation/Foundation.h>
#ifdef __cplusplus
#include <quicr/track_name.h>
#endif

typedef NSData* _Nonnull QName;
typedef NSArray<NSData*>* _Nonnull QTrackNamespace;

@protocol QFullTrackName
@property (readonly, strong) QName name;
@property (readonly, strong) QTrackNamespace nameSpace;
@end

@interface QFullTrackNameImpl: NSObject<QFullTrackName>
@property (strong) QName name;
@property (strong) QTrackNamespace nameSpace;
-(instancetype _Nonnull) initWithNamespace: (QTrackNamespace) nameSpace name: (QName) name;
@end

#ifdef __cplusplus

static QTrackNamespace nsConvert(const quicr::TrackNamespace& nameSpace) {
    const auto& entries = nameSpace.GetEntries();
    NSMutableArray<NSData*>* tuple = [NSMutableArray arrayWithCapacity:entries.size()];
    for (const auto& element : entries) {
        NSData* objcElement = [[NSData alloc] initWithBytes:(void*)element.data()  length:element.size()];
        [tuple addObject:objcElement];
    }
    return tuple;
}

static QName nameConvert(const std::vector<std::uint8_t> name) {
    return [[NSData alloc] initWithBytes:(void*)name.data() length:name.size()];
}

static id<QFullTrackName> _Nonnull ftnConvert(const quicr::FullTrackName& ftn) {
    return [[QFullTrackNameImpl alloc] initWithNamespace:nsConvert(ftn.name_space) name:nameConvert(ftn.name)];
}

static quicr::TrackNamespace nsConvert(QTrackNamespace qNamespace) {
    std::vector<std::vector<std::uint8_t>> tuple;
    for (NSData* element in qNamespace) {
        const auto elementBytes = reinterpret_cast<const std::uint8_t*>(element.bytes);
        tuple.emplace_back(elementBytes, elementBytes + element.length);
    }
    return tuple;
}

static std::vector<std::uint8_t> nameConvert(QName qName) {
    const auto nameBytes = reinterpret_cast<const std::uint8_t*>(qName.bytes);
    return { nameBytes, nameBytes + qName.length };
}

static quicr::FullTrackName ftnConvert(id<QFullTrackName> _Nonnull qFtn) {
    return {
        .name_space = nsConvert(qFtn.nameSpace),
        .name = nameConvert(qFtn.name)
    };
}
#endif

#endif
