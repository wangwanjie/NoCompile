//
//  C04CPlain.h
//

#ifndef C04CPlain_h
#define C04CPlain_h

#include <stdarg.h>

typedef struct {
    int width;
    int height;
    const char *label;
} C04Size;

C04Size c04_make_size(int width, int height);
const char *c04_describe(void);
int c04_sum(int count, ...);
typedef int (*C04Callback)(int);
int c04_apply(C04Callback callback, int value);
int c04_double(int value);

#endif /* C04CPlain_h */
