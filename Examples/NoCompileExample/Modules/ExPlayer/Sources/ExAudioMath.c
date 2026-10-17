//
//  ExAudioMath.c
//  静态库里的 C 文件
//

#include "ExAudioMath.h"
#include <math.h>

const char *ex_audio_describe(void) {
    return "ExAudioMath:@@v1@@";
}

int ex_audio_db_to_percent(double db) {
    double percent = pow(10.0, db / 20.0) * 100.0;
    return (int)(percent > 100 ? 100 : percent);
}
