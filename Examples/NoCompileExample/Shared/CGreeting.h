//
//  CGreeting.h
//  C 函数热重载验证
//

#ifndef CGreeting_h
#define CGreeting_h

#ifdef __cplusplus
extern "C" {
#endif

/// 修改 CGreeting.c 中的返回值并保存，界面会自动刷新
const char *c_greeting(void);

#ifdef __cplusplus
}
#endif

#endif /* CGreeting_h */
