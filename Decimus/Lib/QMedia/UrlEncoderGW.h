#ifndef UrlEncoderGW_h
#define UrlEncoderGW_h

#include "UrlEncoder.h"
#include <memory>
#include <vector>
#include <string>

class UrlEncoderGW {
public:
    UrlEncoderGW(const std::vector<std::string>& templates);
    ~UrlEncoderGW() = default;

    std::string encodeUrl(const std::string& url);

private:
    std::unique_ptr<UrlEncoder> urlEncoder;
};

#endif /* UrlEncoderGW_h */
