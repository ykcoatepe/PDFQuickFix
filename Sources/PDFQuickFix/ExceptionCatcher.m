#import "ExceptionCatcher.h"

BOOL PDFQFPerformBlockCatchingException(NS_NOESCAPE dispatch_block_t block, NSError **error) {
    @try {
        if (block) {
            block();
        }
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSDictionary *userInfo = exception.reason ? @{NSLocalizedDescriptionKey: exception.reason} : @{};
            *error = [NSError errorWithDomain:@"PDFQuickFix.Exception" code:0 userInfo:userInfo];
        }
        return NO;
    }
}
