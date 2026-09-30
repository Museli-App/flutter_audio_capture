#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AVAudioEngine raises NSExceptions (e.g. on a dead input), which Swift can't catch: this
/// turns one raised by [block] into an error carrying its reason.
@interface CaptureExceptionCatcher : NSObject
+ (BOOL)run:(NS_NOESCAPE void (^)(void))block error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
