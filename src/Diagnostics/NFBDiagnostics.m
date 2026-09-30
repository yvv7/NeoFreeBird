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

static NSString* _NFBLogFilePath(void) {
    static NSString* path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // tmp survives long enough for post-crash inspection; Documents
        // would persist across launches but tmp is fine and auto-cleaned.
        NSString* tmp = NSTemporaryDirectory();
        path = [tmp stringByAppendingPathComponent:@"nfb-diagnostics.log"];
    });
    return path;
}

void NFBLog(NSString* format, ...) {
    _NFBLogEnsureInit();
    va_list args;
    va_start(args, format);
    NSString* message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Timestamp for the in-app viewer (NSLog already timestamps itself).
    // NSDateFormatter is NOT thread-safe: create one per call. NFBLog can
    // be called from any thread (ffmpeg callbacks, etc.).
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm:ss";
    NSString* timestamped =
        [NSString stringWithFormat:@"[%@] %@", [formatter stringFromDate:[NSDate date]], message];

    dispatch_sync(_NFBLogQueue, ^{
        [_NFBLogBuffer addObject:timestamped];
        while (_NFBLogBuffer.count > _NFBLogMaxLines) {
            [_NFBLogBuffer removeObjectAtIndex:0];
        }
        // Append to file so logs survive an app crash. Use a file handle
        // kept open for the process lifetime to avoid reopening each time.
        static NSFileHandle* fileHandle = nil;
        static dispatch_once_t fileOnce;
        dispatch_once(&fileOnce, ^{
            NSString* logPath = _NFBLogFilePath();
            [[NSFileManager defaultManager] createFileAtPath:logPath
                                                    contents:nil
                                                  attributes:nil];
            fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
            [fileHandle seekToEndOfFile];
            // Mark process start so post-crash logs are distinguishable.
            NSString* header = [NSString stringWithFormat:
                @"\n===== NFB log started %@ =====\n",
                [[NSDate date] description]];
            [fileHandle writeData:[header dataUsingEncoding:NSUTF8StringEncoding]];
        });
        if (fileHandle) {
            NSString* line = [timestamped stringByAppendingString:@"\n"];
            @try {
                [fileHandle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [fileHandle synchronizeFile];
            } @catch (NSException* e) {
                // Logging must never crash the app.
            }
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
    // If the buffer is empty (e.g. fresh launch after a crash), fall back
    // to the on-disk log so pre-crash lines are still visible.
    if (copy.count == 0) {
        NSString* logPath = _NFBLogFilePath();
        NSString* content = [NSString stringWithContentsOfFile:logPath
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
        if (content.length > 0) {
            NSArray* allLines = [content componentsSeparatedByString:@"\n"];
            // Return the last 300 lines to match the buffer limit.
            NSUInteger start = allLines.count > 300 ? allLines.count - 300 : 0;
            copy = [allLines subarrayWithRange:NSMakeRange(start, allLines.count - start)];
        }
    }
    return copy ?: @[];
}

void NFBClearDiagnostics(void) {
    _NFBLogEnsureInit();
    dispatch_sync(_NFBLogQueue, ^{
        [_NFBLogBuffer removeAllObjects];
        // Truncate the file too.
        NSString* logPath = _NFBLogFilePath();
        [[NSFileManager defaultManager] createFileAtPath:logPath
                                                contents:nil
                                              attributes:nil];
    });
}
