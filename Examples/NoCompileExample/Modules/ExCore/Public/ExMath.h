//
//  ExMath.h
//  C 函数（framework 内的 .c 文件），头文件保持纯 C，使 .c 文件能引用
//

#ifndef ExMath_h
#define ExMath_h

#ifdef __cplusplus
extern "C" {
#endif

const char *ex_math_describe(void);
double ex_math_average(const double *values, int count);

#ifdef __cplusplus
}
#endif

#endif /* ExMath_h */
