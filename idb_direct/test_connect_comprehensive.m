//
// test_connect_comprehensive.m
// Comprehensive test suite for idb_connect_target focusing on the segfault fix
//

#import <Foundation/Foundation.h>
#import <stdio.h>
#import <pthread.h>
#import <dispatch/dispatch.h>
#import "idb_direct.h"

// ANSI color codes for output
#define COLOR_RED     "\x1b[31m"
#define COLOR_GREEN   "\x1b[32m"
#define COLOR_YELLOW  "\x1b[33m"
#define COLOR_BLUE    "\x1b[34m"
#define COLOR_RESET   "\x1b[0m"

// Test result tracking
typedef struct {
    int total;
    int passed;
    int failed;
    int skipped;
} test_stats_t;

static test_stats_t g_stats = {0};

// Test utilities
static void test_start(const char* name) {
    printf("\n" COLOR_BLUE "Testing: %s" COLOR_RESET "\n", name);
    g_stats.total++;
}

static void test_pass(const char* message) {
    printf(COLOR_GREEN "  ✓ %s" COLOR_RESET "\n", message);
    g_stats.passed++;
}

static void test_fail(const char* message, idb_error_t error) {
    printf(COLOR_RED "  ✗ %s - %s (code: %d)" COLOR_RESET "\n", 
           message, idb_error_string(error), error);
    g_stats.failed++;
}

static void test_skip(const char* message) {
    printf(COLOR_YELLOW "  ⚠ %s" COLOR_RESET "\n", message);
    g_stats.skipped++;
}

// Helper to find simulators in different states
typedef struct {
    char udid[128];
    char name[256];
    char state[64];
    BOOL found;
} simulator_info_t;

static BOOL find_simulator_by_state(const char* desired_state, simulator_info_t* info) {
    FILE* fp = popen("xcrun simctl list devices -j", "r");
    if (!fp) return NO;
    
    char buffer[4096];
    NSMutableString* json = [NSMutableString string];
    while (fgets(buffer, sizeof(buffer), fp) != NULL) {
        [json appendString:[NSString stringWithUTF8String:buffer]];
    }
    pclose(fp);
    
    NSError* error = nil;
    NSData* jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* devices = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    if (error || !devices) return NO;
    
    for (NSString* runtime in devices[@"devices"]) {
        NSArray* deviceList = devices[@"devices"][runtime];
        for (NSDictionary* device in deviceList) {
            NSString* state = device[@"state"];
            if ([state isEqualToString:[NSString stringWithUTF8String:desired_state]]) {
                strncpy(info->udid, [device[@"udid"] UTF8String], sizeof(info->udid) - 1);
                strncpy(info->name, [device[@"name"] UTF8String], sizeof(info->name) - 1);
                strncpy(info->state, [state UTF8String], sizeof(info->state) - 1);
                info->found = YES;
                return YES;
            }
        }
    }
    
    return NO;
}

static BOOL find_any_simulator(simulator_info_t* info) {
    FILE* fp = popen("xcrun simctl list devices -j", "r");
    if (!fp) return NO;
    
    char buffer[4096];
    NSMutableString* json = [NSMutableString string];
    while (fgets(buffer, sizeof(buffer), fp) != NULL) {
        [json appendString:[NSString stringWithUTF8String:buffer]];
    }
    pclose(fp);
    
    NSError* error = nil;
    NSData* jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* devices = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    if (error || !devices) return NO;
    
    for (NSString* runtime in devices[@"devices"]) {
        NSArray* deviceList = devices[@"devices"][runtime];
        if (deviceList.count > 0) {
            NSDictionary* device = deviceList[0];
            strncpy(info->udid, [device[@"udid"] UTF8String], sizeof(info->udid) - 1);
            strncpy(info->name, [device[@"name"] UTF8String], sizeof(info->name) - 1);
            strncpy(info->state, [device[@"state"] UTF8String], sizeof(info->state) - 1);
            info->found = YES;
            return YES;
        }
    }
    
    return NO;
}

// Test 1: Basic initialization and shutdown
static void test_basic_init_shutdown(void) {
    test_start("Basic initialization and shutdown");
    
    idb_error_t result = idb_initialize();
    if (result == IDB_SUCCESS) {
        test_pass("idb_initialize succeeded");
        
        result = idb_shutdown();
        if (result == IDB_SUCCESS) {
            test_pass("idb_shutdown succeeded");
        } else {
            test_fail("idb_shutdown failed", result);
        }
    } else {
        test_fail("idb_initialize failed", result);
    }
}

// Test 2: Connect to booted simulator (main bug fix test)
static void test_connect_booted_simulator(void) {
    test_start("Connect to booted simulator (segfault fix verification)");
    
    simulator_info_t sim = {0};
    if (!find_simulator_by_state("Booted", &sim)) {
        test_skip("No booted simulator found");
        return;
    }
    
    printf("  Found simulator: %s (%s) - State: %s\n", sim.name, sim.udid, sim.state);
    
    idb_error_t result = idb_initialize();
    if (result != IDB_SUCCESS) {
        test_fail("idb_initialize failed", result);
        return;
    }
    
    // This is where the segfault occurred
    result = idb_connect_target(sim.udid, IDB_TARGET_SIMULATOR);
    if (result == IDB_SUCCESS) {
        test_pass("Successfully connected to booted simulator (no segfault!)");
        
        // Try a simple operation to verify connection
        result = idb_tap(100, 100);
        if (result == IDB_SUCCESS) {
            test_pass("Tap operation succeeded");
        } else {
            test_fail("Tap operation failed", result);
        }
        
        idb_disconnect_target();
    } else {
        test_fail("Failed to connect to booted simulator", result);
    }
    
    idb_shutdown();
}

// Test 3: Connect to shutdown simulator
static void test_connect_shutdown_simulator(void) {
    test_start("Connect to shutdown simulator");
    
    simulator_info_t sim = {0};
    if (!find_simulator_by_state("Shutdown", &sim)) {
        test_skip("No shutdown simulator found");
        return;
    }
    
    printf("  Found simulator: %s (%s) - State: %s\n", sim.name, sim.udid, sim.state);
    
    idb_error_t result = idb_initialize();
    if (result != IDB_SUCCESS) {
        test_fail("idb_initialize failed", result);
        return;
    }
    
    result = idb_connect_target(sim.udid, IDB_TARGET_SIMULATOR);
    if (result == IDB_ERROR_SIMULATOR_NOT_RUNNING) {
        test_pass("Correctly rejected connection to shutdown simulator");
    } else if (result == IDB_SUCCESS) {
        test_fail("Unexpectedly connected to shutdown simulator", IDB_SUCCESS);
        idb_disconnect_target();
    } else {
        test_fail("Unexpected error", result);
    }
    
    idb_shutdown();
}

// Test 4: Invalid parameters
static void test_invalid_parameters(void) {
    test_start("Invalid parameter handling");
    
    idb_error_t result = idb_initialize();
    if (result != IDB_SUCCESS) {
        test_fail("idb_initialize failed", result);
        return;
    }
    
    // NULL UDID
    result = idb_connect_target(NULL, IDB_TARGET_SIMULATOR);
    if (result == IDB_ERROR_INVALID_PARAMETER) {
        test_pass("Correctly rejected NULL UDID");
    } else {
        test_fail("Failed to reject NULL UDID", result);
    }
    
    // Invalid target type
    result = idb_connect_target("test-udid", 999);
    if (result == IDB_ERROR_INVALID_PARAMETER) {
        test_pass("Correctly rejected invalid target type");
    } else {
        test_fail("Failed to reject invalid target type", result);
    }
    
    // Non-existent UDID
    result = idb_connect_target("00000000-0000-0000-0000-000000000000", IDB_TARGET_SIMULATOR);
    if (result == IDB_ERROR_DEVICE_NOT_FOUND) {
        test_pass("Correctly reported device not found");
    } else {
        test_fail("Failed to report device not found", result);
    }
    
    idb_shutdown();
}

// Test 5: Not initialized error
static void test_not_initialized(void) {
    test_start("Not initialized error handling");
    
    // Ensure we're not initialized
    idb_shutdown();
    
    idb_error_t result = idb_connect_target("test", IDB_TARGET_SIMULATOR);
    if (result == IDB_ERROR_NOT_INITIALIZED) {
        test_pass("Correctly reported not initialized");
    } else {
        test_fail("Failed to report not initialized", result);
    }
}

// Test 6: Thread safety
static void* thread_connect_test(void* arg) {
    simulator_info_t* sim = (simulator_info_t*)arg;
    
    for (int i = 0; i < 5; i++) {
        idb_error_t result = idb_connect_target(sim->udid, IDB_TARGET_SIMULATOR);
        if (result == IDB_SUCCESS) {
            usleep(10000); // 10ms
            idb_disconnect_target();
        }
        usleep(5000); // 5ms between attempts
    }
    
    return NULL;
}

static void test_thread_safety(void) {
    test_start("Thread safety");
    
    simulator_info_t sim = {0};
    if (!find_simulator_by_state("Booted", &sim)) {
        test_skip("No booted simulator found");
        return;
    }
    
    idb_error_t result = idb_initialize();
    if (result != IDB_SUCCESS) {
        test_fail("idb_initialize failed", result);
        return;
    }
    
    // Create multiple threads trying to connect/disconnect
    pthread_t threads[4];
    for (int i = 0; i < 4; i++) {
        if (pthread_create(&threads[i], NULL, thread_connect_test, &sim) != 0) {
            test_fail("Failed to create thread", IDB_ERROR_OPERATION_FAILED);
            idb_shutdown();
            return;
        }
    }
    
    // Wait for all threads
    for (int i = 0; i < 4; i++) {
        pthread_join(threads[i], NULL);
    }
    
    test_pass("Thread safety test completed without crashes");
    
    idb_shutdown();
}

// Test 7: Rapid connect/disconnect cycles
static void test_rapid_connect_disconnect(void) {
    test_start("Rapid connect/disconnect cycles");
    
    simulator_info_t sim = {0};
    if (!find_simulator_by_state("Booted", &sim)) {
        test_skip("No booted simulator found");
        return;
    }
    
    idb_error_t result = idb_initialize();
    if (result != IDB_SUCCESS) {
        test_fail("idb_initialize failed", result);
        return;
    }
    
    BOOL all_passed = YES;
    for (int i = 0; i < 10; i++) {
        result = idb_connect_target(sim.udid, IDB_TARGET_SIMULATOR);
        if (result != IDB_SUCCESS) {
            all_passed = NO;
            break;
        }
        
        result = idb_disconnect_target();
        if (result != IDB_SUCCESS) {
            all_passed = NO;
            break;
        }
    }
    
    if (all_passed) {
        test_pass("Completed 10 rapid connect/disconnect cycles");
    } else {
        test_fail("Failed during rapid cycles", result);
    }
    
    idb_shutdown();
}

// Test 8: Memory stress test
static void test_memory_stress(void) {
    test_start("Memory stress test");
    
    simulator_info_t sim = {0};
    if (!find_simulator_by_state("Booted", &sim)) {
        test_skip("No booted simulator found");
        return;
    }
    
    idb_error_t result = idb_initialize();
    if (result != IDB_SUCCESS) {
        test_fail("idb_initialize failed", result);
        return;
    }
    
    // Connect once
    result = idb_connect_target(sim.udid, IDB_TARGET_SIMULATOR);
    if (result != IDB_SUCCESS) {
        test_fail("Failed to connect", result);
        idb_shutdown();
        return;
    }
    
    // Perform many operations
    BOOL all_passed = YES;
    for (int i = 0; i < 100; i++) {
        // Take screenshots (allocates memory)
        idb_screenshot_t screenshot = {0};
        result = idb_take_screenshot(&screenshot);
        if (result == IDB_SUCCESS) {
            idb_free_screenshot(&screenshot);
        } else if (result != IDB_ERROR_NOT_IMPLEMENTED) {
            all_passed = NO;
            break;
        }
        
        // Perform taps
        result = idb_tap(100 + i, 100 + i);
        if (result != IDB_SUCCESS && result != IDB_ERROR_NOT_IMPLEMENTED) {
            all_passed = NO;
            break;
        }
    }
    
    if (all_passed) {
        test_pass("Completed memory stress test");
    } else {
        test_fail("Failed during memory stress", result);
    }
    
    idb_disconnect_target();
    idb_shutdown();
}

// Test 9: Special "booted" keyword
static void test_booted_keyword(void) {
    test_start("Connect using 'booted' keyword");
    
    // Check if any simulator is booted
    simulator_info_t sim = {0};
    if (!find_simulator_by_state("Booted", &sim)) {
        test_skip("No booted simulator found");
        return;
    }
    
    idb_error_t result = idb_initialize();
    if (result != IDB_SUCCESS) {
        test_fail("idb_initialize failed", result);
        return;
    }
    
    result = idb_connect_target("booted", IDB_TARGET_SIMULATOR);
    if (result == IDB_SUCCESS) {
        test_pass("Successfully connected using 'booted' keyword");
        idb_disconnect_target();
    } else {
        test_fail("Failed to connect using 'booted' keyword", result);
    }
    
    idb_shutdown();
}

// Test 10: Error string coverage
static void test_error_strings(void) {
    test_start("Error string coverage");
    
    // Test all known error codes
    const idb_error_t errors[] = {
        IDB_SUCCESS,
        IDB_ERROR_NOT_INITIALIZED,
        IDB_ERROR_INVALID_PARAMETER,
        IDB_ERROR_DEVICE_NOT_FOUND,
        IDB_ERROR_SIMULATOR_NOT_RUNNING,
        IDB_ERROR_OPERATION_FAILED,
        IDB_ERROR_TIMEOUT,
        IDB_ERROR_OUT_OF_MEMORY,
        IDB_ERROR_NOT_IMPLEMENTED,
        IDB_ERROR_UNSUPPORTED,
        IDB_ERROR_PERMISSION_DENIED,
        IDB_ERROR_APP_NOT_FOUND,
        IDB_ERROR_INVALID_APP_BUNDLE,
        -999 // Unknown error
    };
    
    BOOL all_valid = YES;
    for (int i = 0; i < sizeof(errors)/sizeof(errors[0]); i++) {
        const char* str = idb_error_string(errors[i]);
        if (!str || strlen(str) == 0) {
            printf("  Error %d has no string\n", errors[i]);
            all_valid = NO;
        }
    }
    
    if (all_valid) {
        test_pass("All error codes have valid strings");
    } else {
        test_fail("Some error codes missing strings", IDB_ERROR_OPERATION_FAILED);
    }
}

// Main test runner
int main(int argc, char* argv[]) {
    @autoreleasepool {
        printf(COLOR_BLUE "IDB Direct Connect Comprehensive Test Suite\n");
        printf("===========================================" COLOR_RESET "\n");
        
        // Check for DEVELOPER_DIR
        const char* dev_dir = getenv("DEVELOPER_DIR");
        if (!dev_dir) {
            printf(COLOR_YELLOW "\nWarning: DEVELOPER_DIR not set. Using default Xcode path.\n" COLOR_RESET);
        } else {
            printf("\nDEVELOPER_DIR: %s\n", dev_dir);
        }
        
        // Run all tests
        test_basic_init_shutdown();
        test_connect_booted_simulator();
        test_connect_shutdown_simulator();
        test_invalid_parameters();
        test_not_initialized();
        test_thread_safety();
        test_rapid_connect_disconnect();
        test_memory_stress();
        test_booted_keyword();
        test_error_strings();
        
        // Print summary
        printf("\n" COLOR_BLUE "Test Summary\n");
        printf("============" COLOR_RESET "\n");
        printf("Total tests:   %d\n", g_stats.total);
        printf(COLOR_GREEN "Passed:        %d" COLOR_RESET "\n", g_stats.passed);
        if (g_stats.failed > 0) {
            printf(COLOR_RED "Failed:        %d" COLOR_RESET "\n", g_stats.failed);
        } else {
            printf("Failed:        %d\n", g_stats.failed);
        }
        if (g_stats.skipped > 0) {
            printf(COLOR_YELLOW "Skipped:       %d" COLOR_RESET "\n", g_stats.skipped);
        } else {
            printf("Skipped:       %d\n", g_stats.skipped);
        }
        
        if (g_stats.failed == 0) {
            printf("\n" COLOR_GREEN "✅ All tests passed!" COLOR_RESET "\n");
            return 0;
        } else {
            printf("\n" COLOR_RED "❌ Some tests failed!" COLOR_RESET "\n");
            return 1;
        }
    }
}