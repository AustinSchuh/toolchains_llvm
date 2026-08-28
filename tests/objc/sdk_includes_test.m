// `objc_library(sdk_includes = ...)` produces an include path rooted at the
// literal `__BAZEL_XCODE_SDKROOT__` placeholder, which the toolchain resolves
// to the macOS SDK. `sdk_includes = ["CommonCrypto"]` puts
// <sdk>/usr/include/CommonCrypto on the search path, which is the only way
// this unqualified include resolves -- the header is normally reached as
// <CommonCrypto/CommonDigest.h>.
#import <Foundation/Foundation.h>

#include <CommonDigest.h>

unsigned SdkIncludesDigestLength(void) { return CC_MD5_DIGEST_LENGTH; }
