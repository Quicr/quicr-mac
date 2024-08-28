#import <Foundation/Foundation.h>
#ifdef __cplusplus
#include <moq/track_name.h>
#endif

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
    uint8_t priority;
    uint16_t ttl;
} QObjectHeaders;


#ifdef __cplusplus
moq::FullTrackName ftnConvert(QFullTrackName qFtn) {
    return {
        .name_space = std::vector<std::uint8_t>(qFtn.nameSpace, qFtn.nameSpace + qFtn.nameSpaceLength),
        .name = std::vector<std::uint8_t>(qFtn.name, qFtn.name + qFtn.nameLength)
    };
}
#endif
