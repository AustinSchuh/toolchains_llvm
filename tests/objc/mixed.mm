// Objective-C++: compiled with the `objc++-compile` action, which picks up the
// C++ flags (including -std=) the same way `c++-compile` does.
#import "objc/greeter.h"

#include <string>

std::string MixedGreeting() {
  Greeter *greeter = [[Greeter alloc] init];
  return std::string([[greeter greeting] UTF8String]) + " (objc++)";
}
