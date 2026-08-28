// `objc_library(pch = ...)` passes the prefix header as the `pch_file` build
// variable; the toolchain turns it into `-include`.
#import <Foundation/Foundation.h>

#ifndef PREFIX_HEADER_WAS_INCLUDED
#error "expected objc_library(pch = ...) to be force-included"
#endif

const char *PchCheck(void) { return "pch"; }
