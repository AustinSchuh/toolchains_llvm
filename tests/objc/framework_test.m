// Only resolves when the framework search path (`-F`) contributed by the
// dependency below reaches the compile action.
#import <Foundation/Foundation.h>

#import <Fake/Fake.h>

#ifndef FAKE_FRAMEWORK_HEADER_INCLUDED
#error "expected the framework header to be found through -F"
#endif

const char *FrameworkCheck(void) { return "framework"; }
