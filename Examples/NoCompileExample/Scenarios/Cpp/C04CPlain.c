//
//  C04CPlain.c
//  场景 C04：纯 C：结构体按值返回、可变参数、函数指针回调、静态全局
//

#include "C04CPlain.h"

static int gC04Calls = 0;

C04Size c04_make_size(int width, int height) {
    C04Size size = {width, height, "size"};
    return size;
}

const char *c04_describe(void) {
    gC04Calls += 1;
    return "C04(@@v1@@)";
}

int c04_sum(int count, ...) {
    va_list args;
    va_start(args, count);
    int total = 0;
    for (int i = 0; i < count; i++) {
        total += va_arg(args, int);
    }
    va_end(args);
    return total;
}

int c04_apply(C04Callback callback, int value) {
    return callback(value);
}

int c04_double(int value) {
    return value * 2;
}
