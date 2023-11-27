#ifndef ProfileSet_h
#define ProfileSet_h

#import <Foundation/Foundation.h>

struct QClientProfile {
    const char* qualityProfile;
    const char* quicrNamespace;
    const unsigned char* priorities;
    size_t prioritiesCount;
    int32_t expiry;
};

struct QClientProfileSet {
    const char* type;
    struct QClientProfile* profiles;
    size_t profilesCount;
};

#endif /* ProfileSet_h */
