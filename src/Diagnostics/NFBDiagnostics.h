//
//  NFBDiagnostics.h
//  NeoFreeBird
//
//  In-memory diagnostic log ring buffer. NFBLog() writes to both NSLog
//  and the buffer, so the log can be viewed in-app via the Diagnostics
//  settings page (no Mac/syslog needed).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Log a diagnostic message. Also writes to NSLog with the [NFB] prefix.
void NFBLog(NSString* format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Returns a copy of the buffered log lines (oldest first). Thread-safe.
NSArray<NSString*>* NFBDiagnosticLines(void);

/// Clears the buffered log lines.
void NFBClearDiagnostics(void);

NS_ASSUME_NONNULL_END
