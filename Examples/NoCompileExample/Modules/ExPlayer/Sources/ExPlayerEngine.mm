//
//  ExPlayerEngine.mm
//  场景 M08 / B15 / B19 / H07：静态库内的 ObjC++，混用 C++ 类、模板、异常和 C 函数
//

#import "ExPlayerEngine.h"
#include "ExPlaylist.hpp"
#include "ExRingBuffer.hpp"
#include "ExAudioMath.h"
#include <stdexcept>

/// 自定义异常类型（有 vtable 与 typeinfo）：场景 B19
class ExPlayerError : public std::runtime_error {
public:
    explicit ExPlayerError(const std::string &message, int code) : std::runtime_error(message), code_(code) {}
    int code() const {
        return code_;
    }

private:
    int code_;
};

@implementation ExPlayerEngine

+ (NSString *)engineInfo {
    return @"ExPlayerEngine:@@v1@@";
}

+ (NSString *)exceptionInfo {
    try {
        throw ExPlayerError("boom", 42);
    } catch (const ExPlayerError &error) {
        return [NSString stringWithFormat:@"caught(@@v1@@):%s:%d", error.what(), error.code()];
    } catch (const std::exception &error) {
        return @"caught-std";
    }
    return @"not-caught";
}

+ (NSString *)playlistSummary {
    ExPlaylist playlist;
    playlist.add("b-track", 200);
    playlist.add("a-track", 100);
    return [NSString stringWithUTF8String:playlist.summary().c_str()];
}

+ (NSString *)ringBufferSummary {
    ExRingBuffer<int> buffer(3);
    for (int i = 1; i <= 5; i++) {
        buffer.push(i);
    }
    return [NSString stringWithFormat:@"%s size=%zu first=%d", ExRingBuffer<int>::tag().c_str(), buffer.size(), buffer.at(0)];
}

+ (NSString *)audioMathInfo {
    return [NSString stringWithFormat:@"%s pct=%d", ex_audio_describe(), ex_audio_db_to_percent(-6)];
}

@end
