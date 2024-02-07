#include <stdlib.h>
#import <Foundation/Foundation.h>
#import "UrlEncoderGWObjC.h"
#include "UrlEncoderGW.h"

// objective c
@implementation UrlEncoderGWObjC

- (id)init:(NSArray*)templates {
    self = [super init];
    std::vector<std::string> convertedTemplates;
    for (int templateIndex = 0; templateIndex < templates.count; templateIndex++) {
        NSString* templateString = templates[templateIndex];
        convertedTemplates.push_back(std::string([templateString UTF8String]));
    }
    urlEncoderGW = std::make_unique<UrlEncoderGW>(convertedTemplates);
    return self;
}

- (NSString*)encodeUrl:(NSString*)url
{
    std::string encoded = urlEncoderGW->encodeUrl(std::string([url UTF8String]));
    return [NSString stringWithCString:encoded.c_str() encoding:[NSString defaultCStringEncoding]];
}

@end

// C++

UrlEncoderGW::UrlEncoderGW(const std::vector<std::string>& templates)
{
    urlEncoder = std::make_unique<UrlEncoder>();
    for(int templateIndex = 0; templateIndex < templates.size(); templateIndex++) {
        urlEncoder->AddTemplate(templates[templateIndex]);
    }
}

std::string UrlEncoderGW::encodeUrl(const std::string& url) {
    try {
        return urlEncoder->EncodeUrl(url);
    } catch(const UrlEncoderException& exception) {
        return std::string(exception.what());
    }
}
