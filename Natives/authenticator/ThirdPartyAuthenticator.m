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

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    manager.responseSerializer = AFJSONResponseSerializer.serializer;
    [manager POST:url parameters:body headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        NSString *access = response[@"accessToken"];
        NSString *client = response[@"clientToken"];
        NSDictionary *profile = response[@"selectedProfile"];
        if (profile == nil) {
            NSArray *profiles = response[@"availableProfiles"];
            if (profiles.count > 0) profile = profiles[0];
        }

        if (access == nil || profile == nil) {
            callback([NSError errorWithDomain:@"ThirdPartyAuthenticator" code:500 userInfo:@{NSLocalizedDescriptionKey: @"Invalid response from auth server"}], NO);
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
            callback([NSError errorWithDomain:@"ThirdPartyAuthenticator" code:500 userInfo:@{NSLocalizedDescriptionKey: @"Failed to save account"}], NO);
            return;
        }

        callback(nil, YES);
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        NSData *data = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
        if (data) {
            NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            callback([NSError errorWithDomain:@"ThirdPartyAuthenticator" code:error.code userInfo:@{NSLocalizedDescriptionKey:s ?: error.localizedDescription}], NO);
        } else {
            callback(error, NO);
        }
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

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    manager.responseSerializer = AFJSONResponseSerializer.serializer;
    [manager POST:url parameters:body headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        NSString *access = response[@"accessToken"];
        NSDictionary *profile = response[@"selectedProfile"];
        if (access) self.authData[@"accessToken"] = access;
        if (profile && profile[@"id"]) {
            NSString *formatted = [self formatUUIDWithHyphens:profile[@"id"]];
            self.authData[@"profileId"] = formatted;
            self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/head/%@/120", formatted];
            self.authData[@"oldusername"] = self.authData[@"username"];
            if (profile[@"name"]) self.authData[@"username"] = profile[@"name"];
        }
        self.authData[@"expiresAt"] = @((long)[NSDate.date timeIntervalSince1970] + 86400);
        BOOL saved = [super saveChanges];
        callback(nil, saved);
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        // If refresh isn't supported by server, just return success; caller will force re-login if necessary.
        callback(nil, YES);
    }];
}

@end
