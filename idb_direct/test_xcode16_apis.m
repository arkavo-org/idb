#import <Foundation/Foundation.h>
#import <stdio.h>
#import "idb_direct.h"

void print_usage(const char* program_name) {
    printf("Usage: %s <device_udid>\n", program_name);
    printf("Tests touch and screenshot APIs with Xcode 16.2\n");
}

int main(int argc, char* argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            print_usage(argv[0]);
            return 1;
        }
        
        const char* udid = argv[1];
        
        // Initialize
        printf("Initializing idb_direct...\n");
        idb_error_t error = idb_initialize();
        if (error != IDB_SUCCESS) {
            printf("Failed to initialize: %s\n", idb_error_string(error));
            return 1;
        }
        
        // Connect to simulator
        printf("Connecting to simulator %s...\n", udid);
        error = idb_connect_target(udid, IDB_TARGET_SIMULATOR);
        if (error != IDB_SUCCESS) {
            printf("Failed to connect: %s\n", idb_error_string(error));
            idb_shutdown();
            return 1;
        }
        
        printf("Connected successfully!\n");
        
        // Test 1: Touch API - Tap
        printf("\n=== Testing Touch API ===\n");
        printf("Attempting tap at (195, 422)...\n");
        error = idb_tap(195.0, 422.0);
        if (error == IDB_SUCCESS) {
            printf("✅ Tap successful!\n");
        } else {
            printf("❌ Tap failed: %s\n", idb_error_string(error));
        }
        
        // Wait a bit
        [NSThread sleepForTimeInterval:1.0];
        
        // Test 2: Touch API - Multiple taps
        printf("\nAttempting multiple taps...\n");
        for (int i = 0; i < 3; i++) {
            double x = 100 + (i * 50);
            double y = 200;
            printf("Tap %d at (%.0f, %.0f)...\n", i+1, x, y);
            error = idb_tap(x, y);
            if (error == IDB_SUCCESS) {
                printf("  ✅ Success\n");
            } else {
                printf("  ❌ Failed: %s\n", idb_error_string(error));
            }
            [NSThread sleepForTimeInterval:0.5];
        }
        
        // Test 3: Screenshot API
        printf("\n=== Testing Screenshot API ===\n");
        printf("Taking screenshot...\n");
        idb_screenshot_t screenshot = {0};
        error = idb_take_screenshot(&screenshot);
        if (error == IDB_SUCCESS) {
            printf("✅ Screenshot successful!\n");
            printf("  Format: %s\n", screenshot.format);
            printf("  Size: %zu bytes\n", screenshot.size);
            printf("  Dimensions: %dx%d\n", screenshot.width, screenshot.height);
            
            // Save to file
            NSData* imageData = [NSData dataWithBytes:screenshot.data length:screenshot.size];
            NSString* filename = [NSString stringWithFormat:@"test_screenshot_%@.png", 
                                 [[NSDate date] descriptionWithLocale:nil]];
            [imageData writeToFile:filename atomically:YES];
            printf("  Saved to: %s\n", [filename UTF8String]);
            
            idb_free_screenshot(&screenshot);
        } else {
            printf("❌ Screenshot failed: %s\n", idb_error_string(error));
        }
        
        // Test 4: Touch events
        printf("\n=== Testing Touch Events ===\n");
        printf("Touch down at (150, 300)...\n");
        error = idb_touch_event(IDB_TOUCH_DOWN, 150, 300);
        if (error == IDB_SUCCESS) {
            printf("✅ Touch down successful\n");
            [NSThread sleepForTimeInterval:0.5];
            
            printf("Touch up at (150, 300)...\n");
            error = idb_touch_event(IDB_TOUCH_UP, 150, 300);
            if (error == IDB_SUCCESS) {
                printf("✅ Touch up successful\n");
            } else {
                printf("❌ Touch up failed: %s\n", idb_error_string(error));
            }
        } else {
            printf("❌ Touch down failed: %s\n", idb_error_string(error));
        }
        
        // Cleanup
        printf("\nDisconnecting...\n");
        idb_disconnect_target();
        idb_shutdown();
        
        printf("\nTest complete!\n");
        return 0;
    }
}