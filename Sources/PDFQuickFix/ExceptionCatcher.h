#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes the supplied block and catches any Objective-C exceptions that might be thrown.
/// Returns YES when the block succeeds. If an exception is caught, the function returns NO and
/// populates the error pointer with a descriptive NSError instance.
BOOL PDFQFPerformBlockCatchingException(NS_NOESCAPE dispatch_block_t block, NSError **error);

NS_ASSUME_NONNULL_END
