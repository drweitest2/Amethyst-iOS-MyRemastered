//
// TCBootstrap.m
// Automatically start TouchController server on app launch.
//
// This file uses a constructor attribute to start server in background.
// It avoids modifying launcher / nav controller sources directly.
//
// If you prefer explicit control, remove this file and call TC_StartServer(...) from your launcher init code.
//

#import <Foundation/Foundation.h>
#import "TCTransport.h"

__attribute__((constructor))
static void tc_auto_start() {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Use a recognizable socket name. You can change this if needed.
        TC_StartServer(@"AmethystLauncher");
    });
}