//
//  H02Inline.h
//  场景 H02：头文件里的 static inline 函数，被 ObjC 与 Swift（经桥接头）同时使用
//

#ifndef H02Inline_h
#define H02Inline_h

static inline const char *h02_inline_text(void) {
    return "H02(@@v1@@)";
}

static inline int h02_clamp(int value, int low, int high) {
    return value < low ? low : (value > high ? high : value);
}

#endif /* H02Inline_h */
