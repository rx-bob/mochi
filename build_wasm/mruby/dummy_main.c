// dummy_main.c - provides main() for Emscripten linking
// The real entry point is through JS Module.ccall to mochi_* exports
#include <emscripten.h>

int main() {
  return 0;
}
