//
//  NFBDiagnostics.m
//  NeoFreeBird
//

#import "Diagnostics/NFBDiagnostics.h"

static NSMutableArray<NSString*>* _NFBLogBuffer = nil;
static dispatch_queue_t _NFBLogQueue = nil;
static const NSUInteger _NFBLogMaxLines = 300;

static void _NFBLogEnsureInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _NFBLogBuffer = [NSMutableArray array];
        _NFBLogQueue = dispatch_queue_create("com.neofreebird.diagnostics",
                                             DISPATCH_QUEUE_SERIAL);
    });
}

void NFBLog(NSString* format, ...) {
    _NFBLogEnsureInit();
    va_list args;
    va_start(args, format);
    NSString* message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Timestamp for the in-app viewer (NSLog already timestamps itself).
    static NSDateFormatter* formatter = nil;
    static dispatch_once_t formatterOnce;
    dispatch_once(&formatterOnce, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss";
    });
    NSString* timestamped =
        [NSString stringWithFormat:@"[%@] %@", [formatter stringFromDate:[NSDate date]], message];

    dispatch_sync(_NFBLogQueue, ^{
        [_NFBLogBuffer addObject:timestamped];
        while (_NFBLogBuffer.count > _NFBLogMaxLines) {
            [_NFBLogBuffer removeObjectAtIndex:0];
        }
    });

    NSLog(@"[NFB] %@", message);
}

NSArray<NSString*>* NFBDiagnosticLines(void) {
    _NFBLogEnsureInit();
    __block NSArray<NSString*>* copy = nil;
    dispatch_sync(_NFBLogQueue, ^{
        copy = [_NFBLogBuffer copy];
    });
    return copy;
}

void NFBClearDiagnostics(void) {
    _NFBLogEnsureInit();
    dispatch_sync(_NFBLogQueue, ^{
        [_NFBLogBuffer removeAllObjects];
    });
}
