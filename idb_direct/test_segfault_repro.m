//
// test_segfault_repro.m
// Minimal reproduction of the segfault bug
//

#import <Foundation/Foundation.h>
#import <stdio.h>
#import "idb_direct.h"

int main(int argc, char* argv[]) {
    @autoreleasepool {
        printf("IDB Direct Segfault Reproduction Test\n");
        printf("=====================================\n\n");
        
        // Step 1: Initialize
        printf("1. Initializing IDB...\n");
        idb_error_t result = idb_initialize();
        if (result != IDB_SUCCESS) {
            printf("   Failed to initialize: %s\n", idb_error_string(result));
            return 1;
        }
        printf("   ✓ Initialized successfully\n\n");
        
        // Step 2: Find a booted simulator
        printf("2. Finding booted simulator...\n");
        FILE* fp = popen("xcrun simctl list devices booted -j", "r");
        if (!fp) {
            printf("   Failed to run simctl\n");
            return 1;
        }
        
        char buffer[4096];
        NSMutableString* json = [NSMutableString string];
        while (fgets(buffer, sizeof(buffer), fp) != NULL) {
            [json appendString:[NSString stringWithUTF8String:buffer]];
        }
        pclose(fp);
        
        NSError* error = nil;
        NSData* jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* devices = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
        
        NSString* udid = nil;
        NSString* name = nil;
        for (NSString* runtime in devices[@"devices"]) {
            NSArray* deviceList = devices[@"devices"][runtime];
            for (NSDictionary* device in deviceList) {
                if ([device[@"state"] isEqualToString:@"Booted"]) {
                    udid = device[@"udid"];
                    name = device[@"name"];
                    break;
                }
            }
            if (udid) break;
        }
        
        if (!udid) {
            printf("   No booted simulator found\n");
            printf("   Please boot a simulator with: xcrun simctl boot <device>\n");
            idb_shutdown();
            return 1;
        }
        
        printf("   Found: %s (%s)\n\n", [name UTF8String], [udid UTF8String]);
        
        // Step 3: Connect (this is where the segfault occurred)
        printf("3. Connecting to simulator (testing segfault fix)...\n");
        printf("   Calling idb_connect_target(\"%s\", IDB_TARGET_SIMULATOR)\n", [udid UTF8String]);
        
        result = idb_connect_target([udid UTF8String], IDB_TARGET_SIMULATOR);
        
        if (result == IDB_SUCCESS) {
            printf("   ✓ Connected successfully! (No segfault)\n\n");
            
            // Step 4: Verify connection with a simple operation
            printf("4. Verifying connection with tap...\n");
            result = idb_tap(200, 400);
            if (result == IDB_SUCCESS) {
                printf("   ✓ Tap succeeded\n");
            } else {
                printf("   Tap failed: %s\n", idb_error_string(result));
            }
            
            // Step 5: Disconnect
            printf("\n5. Disconnecting...\n");
            result = idb_disconnect_target();
            printf("   %s\n", result == IDB_SUCCESS ? "✓ Disconnected" : "Failed to disconnect");
        } else {
            printf("   ✗ Failed to connect: %s\n", idb_error_string(result));
        }
        
        // Step 6: Shutdown
        printf("\n6. Shutting down...\n");
        result = idb_shutdown();
        printf("   %s\n", result == IDB_SUCCESS ? "✓ Shutdown complete" : "Failed to shutdown");
        
        printf("\n✅ Test completed successfully - no segfault!\n");
        return 0;
    }
}