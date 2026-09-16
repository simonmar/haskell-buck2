#include "shim.h"

#include <functional>

namespace {
// A trivial bit of real C++ (not just C wrapped in extern "C"), so this
// genuinely exercises the C++ toolchain rather than compiling as C in
// disguise.
int add(int a, int b) {
    std::function<int(int, int)> f = [](int a, int b) { return a + b; };
    return f(a, b);
}
}  // namespace

extern "C" int shim_add_point(const ShimPoint *p) {
    return add(p->x, p->y);
}
