#import "ExceptionCatcher.h"

void PDFQFInstallPDFPageGuard(void);

/// Thread-local counter: export renderers must reject a draw that needed the preview fallback.
NSUInteger PDFQFPageDrawingFailureCount(void);
