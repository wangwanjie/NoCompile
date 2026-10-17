//
//  ExMath.c
//  场景 M02：framework 内的 C 函数
//

#include <ExCore/ExMath.h>

const char *ex_math_describe(void) {
    return "ExMath:@@v1@@";
}

double ex_math_average(const double *values, int count) {
    if (count <= 0) {
        return 0;
    }
    double sum = 0;
    for (int i = 0; i < count; i++) {
        sum += values[i];
    }
    return sum / count;
}
