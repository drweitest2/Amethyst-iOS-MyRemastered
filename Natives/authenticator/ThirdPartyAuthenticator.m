#import "ThirdPartyAuthenticator.h"
#import "AFNetworking.h"
#import "../utils.h"
#import "../ios_uikit_bridge.h"

@implementation ThirdPartyAuthenticator

// Helper: insert hyphens into 32-char uuid to 8-4-4-4-12
- (NSString *)formatUUIDWithHyphens:(NSString *)uuid {
    if (uuid == nil) return nil;
    NSString *clean = [uuid stringByReplacingOccurrencesOfString:@"-" withString:@""];
    if (clean.length != 32) return uuid;
    return [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
            [clean substringWithRange:NSMakeRange(0,8)],
            [clean substringWithRange:NSMakeRange(8,4)],
            [clean substringWithRange:NSMakeRange(12,4)],
            [clean substringWithRange:NSMakeRange(16,4)],
            [clean substringWithRange:NSMakeRange(20,12)]];
}

// Try to extract JSON object from arbitrary data (handles pure JSON, text/plain, or JSON embedded in HTML)
- (NSDictionary *)parseJSONDictionaryFromData:(NSData *)data {
    if (!data) return nil;

    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&err];
    if (!err && [obj isKindOfClass:[NSDictionary class]]) {
        return (NSDictionary *)obj;
    }

    // Try to decode as UTF8 string and find a JSON object inside (e.g. JSON embedded in HTML)
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) return nil;

    // Quick heuristic: find first '{' and last '}' and try parse substring
    NSRange first = [s rangeOfString:@"{"];
    NSRange last = [s rangeOfString:@"}" options:NSBackwardsSearch];
    if (first.location != NSNotFound && last.location != NSNotFound && last.location > first.location) {
        NSRange jsonRange = NSMakeRange(first.location, last.location - first.location + 1);
        NSString *sub = [s substringWithRange:jsonRange];
        NSData *subData = [sub dataUsingEncoding:NSUTF8StringEncoding];
        NSError *err2 = nil;
        id obj2 = [NSJSONSerialization JSONObjectWithData:subData options:kNilOptions error:&err2];
        if (!err2 && [obj2 isKindOfClass:[NSDictionary class]]) {
            return (NSDictionary *)obj2;
        }
    }

    return nil;
}

// Process parsed response dictionary into authData and call callback accordingly
- (void)processAuthResponseDict:(NSDictionary *)response callback:(Callback)callback {
    if (!response || ![response isKindOfClass:[NSDictionary class]]) {
        callback([NSError errorWithDomain:@"ThirdPartyAuthenticator" code:500 userInfo:@{NSLocalizedDescriptionKey:@"Invalid response from auth server"}], NO);
        return;
    }

    NSString *access = response[@"accessToken"];
    NSString *client = response[@"clientToken"];
    NSDictionary *profile = response[@"selectedProfile"];
    if (profile == nil) {
        NSArray *profiles = response[@"availableProfiles"];
        if (profiles.count > 0) profile = profiles[0];
    }

    if (access == nil || profile == nil) {
        callback([NSError errorWithDomain:@"ThirdPartyAuthenticator" code:500 userInfo:@{NSLocalizedDescriptionKey:@"Invalid response from auth server"}], NO);
        return;
    }

    // Save data in authData (BaseAuthenticator.saveChanges will remove input)
    self.authData[@"accessToken"] = access;
    if (client) self.authData[@"clientToken"] = client;
    NSString *profileId = profile[@"id"];
    NSString *name = profile[@"name"];
    if (profileId) {
        NSString *formatted = [self formatUUIDWithHyphens:profileId];
        self.authData[@"profileId"] = formatted;
        // Use mc-heads to show avatar in UI (same pattern as MicrosoftAuthenticator)
        self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/head/%@/120", formatted];
    }
    if (name) {
        self.authData[@"oldusername"] = self.authData[@"username"];
        self.authData[@"username"] = name;
    }

    // Many Yggdrasil implementations don't return expiry; set a default of 1 day.
    self.authData[@"expiresAt"] = @((long)[NSDate.date timeIntervalSince1970] + 86400);

    BOOL saved = [super saveChanges];
    if (!saved) {
        callback([NSError errorWithDomain:@"ThirdPartyAuthenticator" code:500 userInfo:@{NSLocalizedDescriptionKey:@"Failed to save account"}], NO);
        return;
    }

    callback(nil, YES);
}

- (void)loginWithCallback:(Callback)callback {
    // Reuse an existing localized progress string if present; fallback to generic
    NSString *progressMsg = localize(@"login.msa.progress.acquireAccessToken", nil) ?: @"Logging in...";
    callback(progressMsg, YES);

    NSString *authServer = self.authData[@"authServer"];
    if (authServer == nil || authServer.length == 0) {
        callback([NSError errorWithDomain:@"ThirdPartyAuthenticator" code:400 userInfo:@{NSLocalizedDescriptionKey:@"Missing auth server"}], NO);
        return;
    }
    // Normalize base URL (remove trailing slash)
    NSString *base = authServer;
    if ([base hasSuffix:@"/"]) {
        base = [base substringToIndex:base.length-1];
    }
    NSString *url = [NSString stringWithFormat:@"%@/authenticate", base];

    NSDictionary *body = @{
        @"agent": @{@"name": @"Minecraft", @"version": @1},
        @"username": self.authData[@"username"] ?: @"",
        @"password": self.authData[@"input"] ?: @"",
        @"requestUser": @YES
    };

    __weak typeof(self) wself = self;

    // First try: send JSON body and accept raw response; we'll parse manually (handles servers with wrong Content-Type)
    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    manager.responseSerializer = AFHTTPResponseSerializer.serializer; // receive raw NSData, parse ourselves

    // Set an Accept header favoring JSON to discourage HTML login pages
    [manager.requestSerializer setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];
    [manager POST:url parameters:body headers:nil progress:nil success:^(NSURLSessionDataTask *task, id responseObject) {
        __strong typeof(wself) sself = wself;
        NSData *data = (NSData *)responseObject;
        NSDictionary *respDict = [sself parseJSONDictionaryFromData:data];
        if (respDict) {
            [sself processAuthResponseDict:respDict callback:callback];
            return;
        }

        // If response looks like HTML or cannot parse, fall through to form-encoded retry below
        // fallthrough: attempt form-encoded retry
        // (we do not treat this as final failure yet)
        // Create a retry manager with form serializer
        AFHTTPSessionManager *retryManager = AFHTTPSessionManager.manager;
        retryManager.requestSerializer = AFHTTPRequestSerializer.serializer; // form encoded
        retryManager.responseSerializer = AFHTTPResponseSerializer.serializer;
        [retryManager.requestSerializer setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];

        // Build form body (string-keyed values)
        NSDictionary *formBody = @{
            @"username": self.authData[@"username"] ?: @"",
            @"password": self.authData[@"input"] ?: @"",
            @"agent": @"{\\\"name\\\":\\\"Minecraft\\\",\\\"version\\\":1}",
            @"requestUser": @"true"
        };
        [retryManager POST:url parameters:formBody headers:nil progress:nil success:^(NSURLSessionDataTask *task2, id responseObject2) {
            NSData *data2 = (NSData *)responseObject2;
            NSDictionary *respDict2 = [sself parseJSONDictionaryFromData:data2];
            if (respDict2) {
                [sself processAuthResponseDict:respDict2 callback:callback];
            } else {
                // Can't parse even after retry
                NSString *s = [[NSString alloc] initWithData:data2 encoding:NSUTF8StringEncoding] ?: @"Unknown response";
                NSError *err = [NSError errorWithDomain:@"ThirdPartyAuthenticator" code:500 userInfo:@{NSLocalizedDescriptionKey: s}];
                callback(err, NO);
            }
        } failure:^(NSURLSessionDataTask *task2, NSError *error2) {
            NSData *d2 = error2.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
            NSString *s2 = d2 ? [[NSString alloc] initWithData:d2 encoding:NSUTF8StringEncoding] : error2.localizedDescription;
            NSError *err = [NSError errorWithDomain:@"ThirdPartyAuthenticator" code:error2.code userInfo:@{NSLocalizedDescriptionKey: s2 ?: @"Request failed"}];
            callback(err, NO);
        }];
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        // If initial JSON send fails (network, server returned non-2xx, etc.), inspect response body and try form-encoded fallback
        __strong typeof(wself) sself = wself;
        NSData *data = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
        // If body exists, try to extract JSON from it first
        NSDictionary *maybe = [sself parseJSONDictionaryFromData:data];
        if (maybe) {
            [sself processAuthResponseDict:maybe callback:callback];
            return;
        }

        // Otherwise attempt form-encoded retry
        AFHTTPSessionManager *retryManager = AFHTTPSessionManager.manager;
        retryManager.requestSerializer = AFHTTPRequestSerializer.serializer; // form encoded
        retryManager.responseSerializer = AFHTTPResponseSerializer.serializer;
        [retryManager.requestSerializer setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];

        NSDictionary *formBody = @{
            @"username": self.authData[@"username"] ?: @"",
            @"password": self.authData[@"input"] ?: @"",
            @"agent": @"{\\\"name\\\":\\\"Minecraft\\\",\\\"version\\\":1}",
            @"requestUser": @"true"
        };

        [retryManager POST:url parameters:formBody headers:nil progress:nil success:^(NSURLSessionDataTask *task2, id responseObject2) {
            NSData *data2 = (NSData *)responseObject2;
            NSDictionary *respDict2 = [sself parseJSONDictionaryFromData:data2];
            if (respDict2) {
                [sself processAuthResponseDict:respDict2 callback:callback];
            } else {
                NSString *s2 = [[NSString alloc] initWithData:data2 encoding:NSUTF8StringEncoding] ?: @"Unknown response";
                NSError *err = [NSError errorWithDomain:@"ThirdPartyAuthenticator" code:500 userInfo:@{NSLocalizedDescriptionKey: s2}];
                callback(err, NO);
            }
        } failure:^(NSURLSessionDataTask *task2, NSError *error2) {
            NSData *d2 = error2.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
            NSString *s2 = d2 ? [[NSString alloc] initWithData:d2 encoding:NSUTF8StringEncoding] : error2.localizedDescription;
            NSError *err = [NSError errorWithDomain:@"ThirdPartyAuthenticator" code:error2.code userInfo:@{NSLocalizedDescriptionKey: s2 ?: @"Request failed"}];
            callback(err, NO);
        }];
    }];
}

- (void)refreshTokenWithCallback:(Callback)callback {
    NSString *authServer = self.authData[@"authServer"];
    if (!authServer || self.authData[@"clientToken"] == nil || self.authData[@"accessToken"] == nil) {
        // No refresh possible/needed
        callback(nil, YES);
        return;
    }
    NSString *base = authServer;
    if ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length-1];
    NSString *url = [NSString stringWithFormat:@"%@/refresh", base];

    NSDictionary *body = @{
        @"accessToken": self.authData[@"accessToken"],
        @"clientToken": self.authData[@"clientToken"],
        @"requestUser": @YES
    };

    __weak typeof(self) wself = self;

    // Use same robust pattern: send JSON first, parse raw, fallback to form-encoded
    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    manager.responseSerializer = AFHTTPResponseSerializer.serializer;
    [manager.requestSerializer setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];

    [manager POST:url parameters:body headers:nil progress:nil success:^(NSURLSessionDataTask *task, id responseObject) {
        __strong typeof(wself) sself = wself;
        NSData *data = (NSData *)responseObject;
        NSDictionary *respDict = [sself parseJSONDictionaryFromData:data];
        if (respDict) {
            // Update tokens/profile if present
            NSString *access = respDict[@"accessToken"];
            NSDictionary *profile = respDict[@"selectedProfile"];
            if (access) sself.authData[@"accessToken"] = access;
            if (profile && profile[@"id"]) {
                NSString *formatted = [sself formatUUIDWithHyphens:profile[@"id"]];
                sself.authData[@"profileId"] = formatted;
                sself.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/head/%@/120", formatted];
                sself.authData[@"oldusername"] = sself.authData[@"username"];
                if (profile[@"name"]) sself.authData[@"username"] = profile[@"name"];
            }
            sself.authData[@"expiresAt"] = @((long)[NSDate.date timeIntervalSince1970] + 86400);
            BOOL saved = [super saveChanges];
            callback(nil, saved);
            return;
        }

        // Fallback to form-encoded retry
        AFHTTPSessionManager *retryManager = AFHTTPSessionManager.manager;
        retryManager.requestSerializer = AFHTTPRequestSerializer.serializer;
        retryManager.responseSerializer = AFHTTPResponseSerializer.serializer;
        [retryManager.requestSerializer setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];

        NSDictionary *formBody = @{
            @"accessToken": self.authData[@"accessToken"],
            @"clientToken": self.authData[@"clientToken"],
            @"requestUser": @"true"
        };

        [retryManager POST:url parameters:formBody headers:nil progress:nil success:^(NSURLSessionDataTask *task2, id responseObject2) {
            NSData *data2 = (NSData *)responseObject2;
            NSDictionary *respDict2 = [sself parseJSONDictionaryFromData:data2];
            if (respDict2) {
                NSString *access2 = respDict2[@"accessToken"];
                NSDictionary *profile2 = respDict2[@"selectedProfile"];
                if (access2) sself.authData[@"accessToken"] = access2;
                if (profile2 && profile2[@"id"]) {
                    NSString *formatted = [sself formatUUIDWithHyphens:profile2[@"id"]];
                    sself.authData[@"profileId"] = formatted;
                    sself.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/head/%@/120", formatted];
                    sself.authData[@"oldusername"] = sself.authData[@"username"];
                    if (profile2[@"name"]) sself.authData[@"username"] = profile2[@"name"];
                }
                sself.authData[@"expiresAt"] = @((long)[NSDate.date timeIntervalSince1970] + 86400);
                BOOL saved = [super saveChanges];
                callback(nil, saved);
            } else {
                // Treat as unsupported refresh; caller will re-login
                callback(nil, YES);
            }
        } failure:^(NSURLSessionDataTask *task2, NSError *error2) {
            // If refresh isn't supported by server, just return success; caller will force re-login if necessary.
            callback(nil, YES);
        }];

    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        // Initial failure: try parse body, then fallback to form-encoded as above
        __strong typeof(wself) sself = wself;
        NSData *data = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
        NSDictionary *maybe = [sself parseJSONDictionaryFromData:data];
        if (maybe) {
            NSString *access = maybe[@"accessToken"];
            NSDictionary *profile = maybe[@"selectedProfile"];
            if (access) sself.authData[@"accessToken"] = access;
            if (profile && profile[@"id"]) {
                NSString *formatted = [sself formatUUIDWithHyphens:profile[@"id"]];
                sself.authData[@"profileId"] = formatted;
                sself.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/head/%@/120", formatted];
                sself.authData[@"oldusername"] = sself.authData[@"username"];
                if (profile[@"name"]) sself.authData[@"username"] = profile[@"name"];
            }
            sself.authData[@"expiresAt"] = @((long)[NSDate.date timeIntervalSince1970] + 86400);
            BOOL saved = [super saveChanges];
            callback(nil, saved);
            return;
        }

        // fallback attempt (form-encoded)
        AFHTTPSessionManager *retryManager = AFHTTPSessionManager.manager;
        retryManager.requestSerializer = AFHTTPRequestSerializer.serializer;
        retryManager.responseSerializer = AFHTTPResponseSerializer.serializer;
        [retryManager.requestSerializer setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];

        NSDictionary *formBody = @{
            @"accessToken": self.authData[@"accessToken"],
            @"clientToken": self.authData[@"clientToken"],
            @"requestUser": @"true"
        };

        [retryManager POST:url parameters:formBody headers:nil progress:nil success:^(NSURLSessionDataTask *task2, id responseObject2) {
            NSData *data2 = (NSData *)responseObject2;
            NSDictionary *respDict2 = [sself parseJSONDictionaryFromData:data2];
            if (respDict2) {
                NSString *access2 = respDict2[@"accessToken"];
                NSDictionary *profile2 = respDict2[@"selectedProfile"];
                if (access2) sself.authData[@"accessToken"] = access2;
                if (profile2 && profile2[@"id"]) {
                    NSString *formatted = [sself formatUUIDWithHyphens:profile2[@"id"]];
                    sself.authData[@"profileId"] = formatted;
                    sself.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/head/%@/120", formatted];
                    sself.authData[@"oldusername"] = sself.authData[@"username"];
                    if (profile2[@"name"]) sself.authData[@"username"] = profile2[@"name"];
                }
                sself.authData[@"expiresAt"] = @((long)[NSDate.date timeIntervalSince1970] + 86400);
                BOOL saved = [super saveChanges];
                callback(nil, saved);
            } else {
                // Not supported; caller will re-login
                callback(nil, YES);
            }
        } failure:^(NSURLSessionDataTask *task2, NSError *error2) {
            // If refresh isn't supported by server, just return success; caller will force re-login if necessary.
            callback(nil, YES);
        }];
    }];
}

@end