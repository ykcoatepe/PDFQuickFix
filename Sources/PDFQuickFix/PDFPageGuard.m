#import <AppKit/AppKit.h>
#import <PDFKit/PDFKit.h>
#import <objc/runtime.h>

#import "ExceptionCatcher.h"

static CGImageRef PDFQFCreateRasterImageFromPage(PDFPage *page, PDFDisplayBox box, CGFloat scale) {
    CGRect bounds = [page boundsForBox:box];
    size_t width = MAX(1, (size_t)ceil(bounds.size.width * scale));
    size_t height = MAX(1, (size_t)ceil(bounds.size.height * scale));

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, 0, space, bitmapInfo);
    CGColorSpaceRelease(space);
    if (!bitmap) { return NULL; }

    CGContextSetRGBFillColor(bitmap, 1, 1, 1, 1);
    CGContextFillRect(bitmap, CGRectMake(0, 0, width, height));
    CGContextSetInterpolationQuality(bitmap, kCGInterpolationHigh);

    CGPDFPageRef pageRef = page.pageRef;
    if (pageRef) {
        CGAffineTransform transform = CGPDFPageGetDrawingTransform(pageRef, (CGPDFBox)box, CGRectMake(0, 0, width, height), 0, true);
        CGContextConcatCTM(bitmap, transform);
        CGContextDrawPDFPage(bitmap, pageRef);
    } else {
        // Fall back to PDFPage drawing (which may recurse) but guard it.
        PDFQFPerformBlockCatchingException(^{
            [page drawWithBox:box toContext:bitmap];
        }, nil);
    }

    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    return image;
}

static BOOL PDFQFDrawPageUsingCoreGraphics(PDFPage *page, PDFDisplayBox box, CGContextRef context) {
    CGPDFPageRef pageRef = page.pageRef;
    if (!pageRef) { return NO; }

    CGRect bounds = [page boundsForBox:box];
    CGRect localRect = CGRectMake(0, 0, bounds.size.width, bounds.size.height);
    CGAffineTransform transform = CGPDFPageGetDrawingTransform(pageRef, (CGPDFBox)box, localRect, 0, true);

    CGContextSaveGState(context);
    CGContextTranslateCTM(context, bounds.origin.x, bounds.origin.y);
    CGContextConcatCTM(context, transform);
    CGContextDrawPDFPage(context, pageRef);
    CGContextRestoreGState(context);
    return YES;
}

@implementation PDFPage (PDFQuickFixGuard)

- (void)pdfqf_drawWithBox:(PDFDisplayBox)box toContext:(CGContextRef)context {
    if (PDFQFDrawPageUsingCoreGraphics(self, box, context)) {
        return;
    }

    BOOL success = PDFQFPerformBlockCatchingException(^{
        [self pdfqf_drawWithBox:box toContext:context];
    }, NULL);
    if (!success) {
        NSLog(@"PDFQuickFix: drawWithBox fallback triggered for %@", self);
        CGImageRef fallback = PDFQFCreateRasterImageFromPage(self, box, 2.0);
        if (fallback) {
            CGRect bounds = [self boundsForBox:box];
            CGContextSaveGState(context);
            CGContextTranslateCTM(context, 0, CGRectGetMaxY(bounds));
            CGContextScaleCTM(context, 1, -1);
            CGContextDrawImage(context, bounds, fallback);
            CGContextRestoreGState(context);
            CGImageRelease(fallback);
        }
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
