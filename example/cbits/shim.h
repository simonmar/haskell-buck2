#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int x;
    int y;
} ShimPoint;

int shim_add_point(const ShimPoint *p);

#ifdef __cplusplus
}
#endif
