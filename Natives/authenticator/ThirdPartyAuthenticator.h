#import "BaseAuthenticator.h"

@interface ThirdPartyAuthenticator : BaseAuthenticator

// Expose designated initializer to callers to avoid "no visible @interface" errors.
- (id)initWithData:(NSMutableDictionary *)data;

@end