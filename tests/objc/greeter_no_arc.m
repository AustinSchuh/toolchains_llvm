// Listed in `non_arc_srcs`, so this one must be compiled *without* ARC: it
// manages the retain count by hand, which ARC rejects outright.
#import "objc/greeter.h"

#if __has_feature(objc_arc)
#error "expected ARC to be disabled for objc_library non_arc_srcs"
#endif

const char *GreeterGreetingCStringNoArc(void) {
  Greeter *greeter = [[Greeter alloc] init];
  const char *greeting = [[greeter greeting] UTF8String];
  [greeter release];
  return greeting;
}
