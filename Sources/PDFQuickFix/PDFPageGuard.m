#import <AppKit/AppKit.h>
#import <PDFKit/PDFKit.h>
#import <objc/runtime.h>

#import "ExceptionCatcher.h"

static NSString * const PDFQFDrawingFailuresKey = @"PDFQuickFixPageDrawingFailureCount";

NSUInteger PDFQFPageDrawingFailureCount(void) {
    return [NSThread.currentThread.threadDictionary[PDFQFDrawingFailuresKey] unsignedIntegerValue];
}

// Best-effort preview only. Export callers reject any draw which needed this
// fallback because CGPDFPage cannot reproduce the live annotation appearances.
static void PDFQFDrawPreviewUsingCoreGraphics(PDFPage *page, PDFDisplayBox box, CGContextRef context) {
    CGPDFPageRef pageRef = page.pageRef;
    if (!pageRef) { return; } // Never recurse through the swizzled draw method.
    CGAffineTransform transform = [page transformForBox:box];
    CGRect visible = CGRectStandardize(CGRectApplyAffineTransform([page boundsForBox:box], transform));
    CGContextSaveGState(context);
    CGContextClipToRect(context, visible);
    CGContextConcatCTM(context, transform);
    CGContextDrawPDFPage(context, pageRef);
    CGContextRestoreGState(context);
}

@implementation PDFPage (PDFQuickFixGuard)

- (void)pdfqf_drawWithBox:(PDFDisplayBox)box toContext:(CGContextRef)context {
    CGContextSaveGState(context);
    BOOL success = PDFQFPerformBlockCatchingException(^{
        // After the exchange this selector invokes PDFKit's original method.
        [self pdfqf_drawWithBox:box toContext:context];
    }, NULL);
    CGContextRestoreGState(context);
    if (!success) {
        NSThread.currentThread.threadDictionary[PDFQFDrawingFailuresKey] = @(PDFQFPageDrawingFailureCount() + 1);
        NSLog(@"PDFQuickFix: PDFKit page appearance failed; preview fallback only.");
        PDFQFPerformBlockCatchingException(^{
            PDFQFDrawPreviewUsingCoreGraphics(self, box, context);
        }, NULL);
    }
}

@end

@implementation NSNumber (PDFQuickFixCrashGuard)

- (NSUInteger)length {
    return [[self stringValue] length];
}

- (void)_getCString:(char *)buffer maxLength:(NSUInteger)maxLength encoding:(NSUInteger)encoding {
    [[self stringValue] getCString:buffer maxLength:maxLength encoding:encoding];
}

@end

void PDFQFInstallPDFPageGuard(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [PDFPage class];
        SEL originalSel = @selector(drawWithBox:toContext:);
        SEL swizzledSel = @selector(pdfqf_drawWithBox:toContext:);
        Method originalMethod = class_getInstanceMethod(cls, originalSel);
        Method swizzledMethod = class_getInstanceMethod(cls, swizzledSel);
        if (originalMethod && swizzledMethod) {
            method_exchangeImplementations(originalMethod, swizzledMethod);
        }
    });
}
