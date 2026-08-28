#include <cstdio>
#include <cstring>
#include <string>

extern "C" const char *GreeterGreetingCString(void);
extern "C" const char *GreeterGreetingCStringNoArc(void);
std::string MixedGreeting();

int main() {
  if (std::strcmp(GreeterGreetingCString(), "hello from objective-c") != 0) {
    std::fprintf(stderr, "unexpected greeting: %s\n", GreeterGreetingCString());
    return 1;
  }
  if (std::strcmp(GreeterGreetingCStringNoArc(), "hello from objective-c") !=
      0) {
    std::fprintf(stderr, "unexpected non-arc greeting: %s\n",
                 GreeterGreetingCStringNoArc());
    return 1;
  }
  if (MixedGreeting() != "hello from objective-c (objc++)") {
    std::fprintf(stderr, "unexpected mixed greeting: %s\n",
                 MixedGreeting().c_str());
    return 1;
  }
  return 0;
}
