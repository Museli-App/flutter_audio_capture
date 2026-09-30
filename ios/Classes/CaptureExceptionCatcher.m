#import "CaptureExceptionCatcher.h"

@implementation CaptureExceptionCatcher
+ (BOOL)run:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"AudioCapture" code:-1
                userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
        }
        return NO;
    }
}
@end
