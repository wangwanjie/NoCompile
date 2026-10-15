//
//  NCLog.m
//

#if DEBUG || NOCOMPILE_FORCE_ENABLE

#import "NCLog.h"

static NCLogForwarder gForwarder;

void NCLogSetForwarder(NCLogForwarder forwarder) {
    gForwarder = [forwarder copy];
}

void NCLogMessage(NCLogLevel level, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    static NSArray<NSString *> *prefixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefixes = @[@"ℹ️", @"✅", @"⚠️", @"❌"];
    });
    NSString *prefix = (level >= 0 && level < prefixes.count) ? prefixes[level] : @"";
    NSLog(@"[NoCompile] %@ %@", prefix, message);

    NCLogForwarder forwarder = gForwarder;
    if (forwarder) {
        forwarder(level, message);
    }
}

#endif
