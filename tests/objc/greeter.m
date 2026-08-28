#import "objc/greeter.h"

#if !__has_feature(objc_arc)
#error "expected ARC to be enabled for objc_library srcs"
#endif

@implementation Greeter
- (NSString *)greeting {
  return @"hello from objective-c";
}
@end

const char *GreeterGreetingCString(void) {
  Greeter *greeter = [[Greeter alloc] init];
  return [[greeter greeting] UTF8String];
}
