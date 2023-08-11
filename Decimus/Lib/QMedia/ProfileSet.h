#ifndef ProfileSet_h
#define ProfileSet_h

#import <Foundation/Foundation.h>

struct QClientProfile {
    NSString* qualityProfile;
    int timeToLive;
    NSString* quicrNamespace;
    int* priorities;
    size_t prioritiesCount;
};

struct QClientProfileSet {
    NSString* type;
    struct QClientProfile* profiles;
    size_t profilesCount;
};

#endif /* ProfileSet_h */
