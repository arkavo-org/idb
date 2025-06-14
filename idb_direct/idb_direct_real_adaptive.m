#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import "idb_direct.h"

// We'll use runtime APIs to interact with SimulatorKit
static Class SimDeviceClass = nil;
static Class SimDeviceSetClass = nil;
static Class SimDeviceLegacyClientClass = nil;
static Class AXPTranslatorClass = nil;

// Global state
static struct {
    id current_device;  // SimDevice instance
    id legacy_client;   // SimDeviceLegacyClient instance for HID
    _Atomic(BOOL) initialized;
    dispatch_queue_t sync_queue;
} g_idb_state = {0};

// Thread-safe synchronization macros
#define IDB_SYNC_INIT() \
    static dispatch_once_t once; \
    dispatch_once(&once, ^{ \
        g_idb_state.sync_queue = dispatch_queue_create("com.arkavo.idb_adaptive_sync", DISPATCH_QUEUE_SERIAL); \
    })

#define IDB_SYNCHRONIZED(block) \
    IDB_SYNC_INIT(); \
    dispatch_sync(g_idb_state.sync_queue, ^{ \
        @autoreleasepool { \
            block \
        } \
    })

// Export helper for shared memory implementation
id g_idb_state_current_device(void) {
    __block id device = nil;
    IDB_SYNCHRONIZED({
        device = g_idb_state.current_device;
    });
    return device;
}

// Error string storage
static const char* g_error_strings[] = {
    [0] = "Success",
    [1] = "Not initialized",
    [2] = "Invalid parameter", 
    [3] = "Device not found",
    [4] = "Simulator not running",
    [5] = "Operation failed",
    [6] = "Timeout",
    [7] = "Out of memory",
};

static BOOL load_simulator_kit(void) {
    static dispatch_once_t once;
    static BOOL loaded = NO;
    
    dispatch_once(&once, ^{
        // Load CoreSimulator framework
        void* coreSimHandle = dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_LAZY);
        if (!coreSimHandle) {
            NSLog(@"Failed to load CoreSimulator.framework");
            return;
        }
        
        // Load SimulatorKit framework for legacy HID support
        void* simKitHandle = dlopen("/Library/Developer/PrivateFrameworks/SimulatorKit.framework/SimulatorKit", RTLD_LAZY);
        if (!simKitHandle) {
            NSLog(@"Warning: Failed to load SimulatorKit.framework - some features may be limited");
        }
        
        // Load Accessibility framework for alternative touch method
        void* axHandle = dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", RTLD_LAZY);
        if (!axHandle) {
            NSLog(@"Warning: Failed to load AccessibilityPlatformTranslation.framework");
        }
        
        SimDeviceClass = NSClassFromString(@"SimDevice");
        SimDeviceSetClass = NSClassFromString(@"SimDeviceSet");
        SimDeviceLegacyClientClass = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
        if (!SimDeviceLegacyClientClass) {
            SimDeviceLegacyClientClass = NSClassFromString(@"SimDeviceLegacyHIDClient");
        }
        AXPTranslatorClass = NSClassFromString(@"AXPTranslator_iOS");
        
        if (SimDeviceClass && SimDeviceSetClass) {
            NSLog(@"Successfully loaded CoreSimulator classes");
            if (SimDeviceLegacyClientClass) {
                NSLog(@"Legacy HID client class available");
            }
            if (AXPTranslatorClass) {
                NSLog(@"Accessibility translator class available");
            }
            loaded = YES;
        }
    });
    
    return loaded;
}

idb_error_t idb_initialize(void) {
    if (!load_simulator_kit()) {
        return IDB_ERROR_OPERATION_FAILED;
    }
    
    IDB_SYNCHRONIZED({
        atomic_store(&g_idb_state.initialized, YES);
        NSLog(@"idb_direct: initialized successfully");
    });
    return IDB_SUCCESS;
}

idb_error_t idb_shutdown(void) {
    IDB_SYNCHRONIZED({
        if (g_idb_state.current_device) {
            g_idb_state.current_device = nil;
        }
        if (g_idb_state.legacy_client) {
            g_idb_state.legacy_client = nil;
        }
        atomic_store(&g_idb_state.initialized, NO);
    });
    return IDB_SUCCESS;
}

idb_error_t idb_connect_target(const char* udid, idb_target_type_t type) {
    if (!atomic_load(&g_idb_state.initialized)) {
        return IDB_ERROR_NOT_INITIALIZED;
    }
    
    if (!udid || type != IDB_TARGET_SIMULATOR) {
        return IDB_ERROR_INVALID_PARAMETER;
    }
    
    __block idb_error_t result = IDB_SUCCESS;
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#pragma clang diagnostic ignored "-Wundeclared-selector"
    
    SEL sharedContextSelector = @selector(sharedServiceContextForDeveloperDir:error:);
    SEL defaultSetSelector = @selector(defaultDeviceSetWithError:);
    
    IDB_SYNCHRONIZED({
        @autoreleasepool {
            NSString* targetUdid = [NSString stringWithUTF8String:udid];
            
            // Get default device set with Xcode 16+ compatibility
            id deviceSet = nil;
            
            // Try Xcode <= 15 API first
            if ([SimDeviceSetClass respondsToSelector:@selector(defaultSet)]) {
                deviceSet = [SimDeviceSetClass performSelector:@selector(defaultSet)];
            } else {
                // For Xcode 16+, use SimServiceContext
                Class SimServiceContextClass = NSClassFromString(@"SimServiceContext");
                if (SimServiceContextClass) {
                    if ([SimServiceContextClass respondsToSelector:sharedContextSelector]) {
                        NSError *error = nil;
                        NSString *developerDir = [NSProcessInfo.processInfo.environment objectForKey:@"DEVELOPER_DIR"];
                        // Fallback to default Xcode location if DEVELOPER_DIR not set
                        if (!developerDir) {
                            NSString *defaultPath = @"/Applications/Xcode.app/Contents/Developer";
                            if ([[NSFileManager defaultManager] fileExistsAtPath:defaultPath]) {
                                developerDir = defaultPath;
                            } else {
                                NSLog(@"[idb] Default Xcode path not found at %@, DEVELOPER_DIR not set", defaultPath);
                                result = IDB_ERROR_OPERATION_FAILED;
                                return;
                            }
                        }
                        
                        id sharedContext = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(SimServiceContextClass, sharedContextSelector, developerDir, &error);
                        
                        if (sharedContext) {
                            if ([sharedContext respondsToSelector:defaultSetSelector]) {
                                error = nil;
                                deviceSet = ((id (*)(id, SEL, NSError **))objc_msgSend)(sharedContext, defaultSetSelector, &error);
                            }
                        }
                    }
                }
            }
            
            if (!deviceSet) {
                NSLog(@"[idb] CoreSimulator API changed - could not obtain device set. Tried both SimDeviceSet.defaultSet and SimServiceContext.defaultDeviceSetWithError:");
                result = IDB_ERROR_OPERATION_FAILED;
                return;
            }
            
            // Get all devices
            SEL devicesSelector = NSSelectorFromString(@"devices");
            NSArray* devices = [deviceSet performSelector:devicesSelector];
            
            // Find our target device
            for (id device in devices) {
                SEL udidSelector = NSSelectorFromString(@"UDID");
                NSUUID* deviceUDID = [device performSelector:udidSelector];
                
                if ([deviceUDID.UUIDString isEqualToString:targetUdid] || 
                    [targetUdid isEqualToString:@"booted"]) {
                    // Check if booted
                    // Try to get state using KVC which handles primitive returns better
                    NSInteger state = 0;
                    @try {
                        NSNumber *stateNumber = [device valueForKey:@"state"];
                        NSLog(@"[DEBUG] stateNumber = %@ (class: %@)", stateNumber, [stateNumber class]);
                        state = [stateNumber integerValue];
                    } @catch (NSException *exception) {
                        NSLog(@"[DEBUG] Exception getting state: %@", exception);
                        // Fallback to performSelector with NSInvocation
                        SEL stateSelector = NSSelectorFromString(@"state");
                        if ([device respondsToSelector:stateSelector]) {
                            NSMethodSignature *sig = [device methodSignatureForSelector:stateSelector];
                            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                            [inv setTarget:device];
                            [inv setSelector:stateSelector];
                            [inv invoke];
                            [inv getReturnValue:&state];
                        }
                    }
                    
                    NSLog(@"[DEBUG] Device state = %ld", state);
                    
                    if (state != 3) { // Booted state
                        NSLog(@"Simulator is not booted (state: %ld)", state);
                        result = IDB_ERROR_SIMULATOR_NOT_RUNNING;
                        return;
                    }
                    
                    g_idb_state.current_device = device;
                    
                    // Try to create legacy HID client for better compatibility
                    if (SimDeviceLegacyClientClass) {
                        NSError *error = nil;
                        SEL initSelector = @selector(initWithDevice:error:);
                        if ([SimDeviceLegacyClientClass instancesRespondToSelector:initSelector]) {
                            // Create invocation to handle error parameter properly
                            NSMethodSignature* sig = [SimDeviceLegacyClientClass instanceMethodSignatureForSelector:initSelector];
                            NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
                            [inv setTarget:[SimDeviceLegacyClientClass alloc]];
                            [inv setSelector:initSelector];
                            [inv setArgument:&device atIndex:2];
                            [inv setArgument:&error atIndex:3];
                            [inv invoke];
                            
                            __unsafe_unretained id legacyClient = nil;
                            [inv getReturnValue:&legacyClient];
                            if (legacyClient) {
                                g_idb_state.legacy_client = legacyClient;
                                NSLog(@"Created legacy HID client successfully");
                            } else {
                                NSLog(@"Failed to create legacy HID client: %@", error);
                            }
                        }
                    }
                    
                    NSLog(@"Connected to simulator: %@", deviceUDID.UUIDString);
                    result = IDB_SUCCESS;
                    return;
                }
            }
            
            result = IDB_ERROR_DEVICE_NOT_FOUND;
        }
    });
#pragma clang diagnostic pop
    
    return result;
}

idb_error_t idb_disconnect_target(void) {
    IDB_SYNCHRONIZED({
        g_idb_state.current_device = nil;
        g_idb_state.legacy_client = nil;
    });
    return IDB_SUCCESS;
}

// Forward declaration
static idb_error_t idb_mouse_event(double x, double y, BOOL down);

idb_error_t idb_tap(double x, double y) {
    __block id current_device = nil;
    IDB_SYNCHRONIZED({
        current_device = g_idb_state.current_device;
    });
    
    if (!current_device) {
        return IDB_ERROR_DEVICE_NOT_FOUND;
    }
    
    // For Xcode 16+, try to send a complete tap event via sendAccessibilityRequestAsync
    SEL sendAccessibilitySelector = @selector(sendAccessibilityRequestAsync:completionQueue:completionHandler:);
    NSLog(@"[DEBUG] Checking sendAccessibilityRequestAsync on device for tap");
    if ([current_device respondsToSelector:sendAccessibilitySelector]) {
        Class AXPTranslatorRequestClass = NSClassFromString(@"AXPTranslatorRequest");
        if (AXPTranslatorRequestClass) {
            id request = [[AXPTranslatorRequestClass alloc] init];
            if (request) {
                // Set request type to press
                SEL setRequestTypeSelector = @selector(setRequestType:);
                if ([request respondsToSelector:setRequestTypeSelector]) {
                    NSInteger requestType = 1; // AXPTranslatorRequestTypePress
                    NSMethodSignature* sig = [request methodSignatureForSelector:setRequestTypeSelector];
                    NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:request];
                    [inv setSelector:setRequestTypeSelector];
                    [inv setArgument:&requestType atIndex:2];
                    [inv invoke];
                }
                
                // Create event path for a complete tap (began | ended)
                SEL setEventPathSelector = @selector(setEventPath:);
                if ([request respondsToSelector:setEventPathSelector]) {
                    NSMutableDictionary* tapEvent = [NSMutableDictionary dictionary];
                    tapEvent[@"x"] = @(x);
                    tapEvent[@"y"] = @(y);
                    tapEvent[@"phase"] = @17; // 1 (began) | 16 (ended) = 17
                    tapEvent[@"force"] = @1.0;
                    tapEvent[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
                    
                    NSArray* eventPath = @[tapEvent];
                    
                    NSMethodSignature* sig = [request methodSignatureForSelector:setEventPathSelector];
                    NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:request];
                    [inv setSelector:setEventPathSelector];
                    [inv setArgument:&eventPath atIndex:2];
                    [inv invoke];
                }
                
                // Send the request asynchronously
                dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
                __block idb_error_t result = IDB_ERROR_OPERATION_FAILED;
                
                dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
                
                NSMethodSignature* sig = [current_device methodSignatureForSelector:sendAccessibilitySelector];
                NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:current_device];
                [inv setSelector:sendAccessibilitySelector];
                [inv setArgument:&request atIndex:2];
                [inv setArgument:&queue atIndex:3];
                
                void (^completionHandler)(id) = ^(id response) {
                    if (response) {
                        SEL errorSelector = @selector(error);
                        if ([response respondsToSelector:errorSelector]) {
                            NSError* responseError = nil;
                            NSMethodSignature* errorSig = [response methodSignatureForSelector:errorSelector];
                            NSInvocation* errorInv = [NSInvocation invocationWithMethodSignature:errorSig];
                            [errorInv setTarget:response];
                            [errorInv setSelector:errorSelector];
                            [errorInv invoke];
                            [errorInv getReturnValue:&responseError];
                            
                            if (!responseError) {
                                result = IDB_SUCCESS;
                                NSLog(@"[DEBUG] Tap sent successfully via sendAccessibilityRequestAsync");
                            }
                        } else {
                            result = IDB_SUCCESS;
                            NSLog(@"[DEBUG] Tap sent successfully via sendAccessibilityRequestAsync");
                        }
                    }
                    dispatch_semaphore_signal(semaphore);
                };
                
                [inv setArgument:&completionHandler atIndex:4];
                [inv invoke];
                
                dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
                if (dispatch_semaphore_wait(semaphore, timeout) == 0 && result == IDB_SUCCESS) {
                    return result;
                }
            }
        }
    }
    
    // Fall back to sending separate down/up events
    return idb_mouse_event(x, y, YES) == IDB_SUCCESS && 
           idb_mouse_event(x, y, NO) == IDB_SUCCESS ? IDB_SUCCESS : IDB_ERROR_OPERATION_FAILED;
}

// Enhanced touch event implementation with multiple approaches
static idb_error_t idb_mouse_event(double x, double y, BOOL down) {
    __block id current_device = nil;
    __block id legacy_client = nil;
    IDB_SYNCHRONIZED({
        current_device = g_idb_state.current_device;
        legacy_client = g_idb_state.legacy_client;
    });
    
    if (!current_device) {
        return IDB_ERROR_DEVICE_NOT_FOUND;
    }
    
    @autoreleasepool {
        NSError* error = nil;
        
        // Try multiple approaches to send events
        
        // Approach 1: Try sendAccessibilityRequestAsync (required for Xcode 16+)
        SEL sendAccessibilitySelector = @selector(sendAccessibilityRequestAsync:completionQueue:completionHandler:);
        NSLog(@"[DEBUG] Checking sendAccessibilityRequestAsync on device: %@", current_device);
        
        // List available methods on device for debugging
        unsigned int methodCount = 0;
        Method* methods = class_copyMethodList([current_device class], &methodCount);
        NSLog(@"[DEBUG] Device class methods (%u):", methodCount);
        for (unsigned int i = 0; i < MIN(20, methodCount); i++) {
            SEL selector = method_getName(methods[i]);
            NSLog(@"[DEBUG]   - %@", NSStringFromSelector(selector));
        }
        free(methods);
        
        if ([current_device respondsToSelector:sendAccessibilitySelector]) {
            NSLog(@"[DEBUG] sendAccessibilityRequestAsync found on device");
            
            // Try to create AXPTranslatorRequest
            Class AXPTranslatorRequestClass = NSClassFromString(@"AXPTranslatorRequest");
            NSLog(@"[DEBUG] AXPTranslatorRequest class lookup: %@", AXPTranslatorRequestClass);
            if (AXPTranslatorRequestClass) {
                NSLog(@"[DEBUG] AXPTranslatorRequest class found");
                
                // Create request instance
                id request = [[AXPTranslatorRequestClass alloc] init];
                if (request) {
                    // Set request type to press
                    SEL setRequestTypeSelector = @selector(setRequestType:);
                    if ([request respondsToSelector:setRequestTypeSelector]) {
                        // AXPTranslatorRequestTypePress = 1
                        NSInteger requestType = 1;
                        NSMethodSignature* sig = [request methodSignatureForSelector:setRequestTypeSelector];
                        NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setTarget:request];
                        [inv setSelector:setRequestTypeSelector];
                        [inv setArgument:&requestType atIndex:2];
                        [inv invoke];
                    }
                    
                    // Create event path
                    SEL setEventPathSelector = @selector(setEventPath:);
                    if ([request respondsToSelector:setEventPathSelector]) {
                        // Create event path array with touch event
                        NSMutableDictionary* touchEvent = [NSMutableDictionary dictionary];
                        touchEvent[@"x"] = @(x);
                        touchEvent[@"y"] = @(y);
                        touchEvent[@"phase"] = down ? @1 : @16; // 1=began, 16=ended
                        touchEvent[@"force"] = @1.0;
                        touchEvent[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
                        
                        NSArray* eventPath = @[touchEvent];
                        
                        NSMethodSignature* sig = [request methodSignatureForSelector:setEventPathSelector];
                        NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setTarget:request];
                        [inv setSelector:setEventPathSelector];
                        [inv setArgument:&eventPath atIndex:2];
                        [inv invoke];
                    }
                    
                    // Send the request asynchronously
                    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
                    __block idb_error_t result = IDB_ERROR_OPERATION_FAILED;
                    
                    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
                    
                    NSMethodSignature* sig = [current_device methodSignatureForSelector:sendAccessibilitySelector];
                    NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:current_device];
                    [inv setSelector:sendAccessibilitySelector];
                    [inv setArgument:&request atIndex:2];
                    [inv setArgument:&queue atIndex:3];
                    
                    // Create completion block
                    void (^completionHandler)(id) = ^(id response) {
                        if (response) {
                            NSLog(@"[DEBUG] Received AXPTranslatorResponse: %@", response);
                            
                            // Check if response indicates success
                            SEL errorSelector = @selector(error);
                            if ([response respondsToSelector:errorSelector]) {
                                NSError* responseError = nil;
                                NSMethodSignature* errorSig = [response methodSignatureForSelector:errorSelector];
                                NSInvocation* errorInv = [NSInvocation invocationWithMethodSignature:errorSig];
                                [errorInv setTarget:response];
                                [errorInv setSelector:errorSelector];
                                [errorInv invoke];
                                [errorInv getReturnValue:&responseError];
                                
                                if (!responseError) {
                                    result = IDB_SUCCESS;
                                    NSLog(@"[DEBUG] Touch event sent successfully via sendAccessibilityRequestAsync");
                                } else {
                                    NSLog(@"[DEBUG] AXPTranslatorResponse error: %@", responseError);
                                }
                            } else {
                                // No error method means success
                                result = IDB_SUCCESS;
                                NSLog(@"[DEBUG] Touch event sent successfully via sendAccessibilityRequestAsync");
                            }
                        } else {
                            NSLog(@"[DEBUG] No response from sendAccessibilityRequestAsync");
                        }
                        dispatch_semaphore_signal(semaphore);
                    };
                    
                    [inv setArgument:&completionHandler atIndex:4];
                    [inv invoke];
                    
                    // Wait for completion with timeout
                    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
                    if (dispatch_semaphore_wait(semaphore, timeout) == 0) {
                        if (result == IDB_SUCCESS) {
                            return result;
                        }
                    } else {
                        NSLog(@"[DEBUG] sendAccessibilityRequestAsync timeout");
                        return IDB_ERROR_TIMEOUT;
                    }
                }
            }
        }
        
        // Approach 2: Try legacy accessibility-based touch events
        if (AXPTranslatorClass) {
            NSLog(@"[DEBUG] Falling back to legacy AXPTranslator methods");
            SEL sharedInstanceSelector = @selector(sharedInstance);
            if ([AXPTranslatorClass respondsToSelector:sharedInstanceSelector]) {
                NSLog(@"[DEBUG] sharedInstance selector found");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id translator = [AXPTranslatorClass performSelector:sharedInstanceSelector];
#pragma clang diagnostic pop
                
                if (translator) {
                    NSLog(@"[DEBUG] Got translator instance: %@", translator);
                    SEL pressEventSelector = @selector(_sendPressFingerEvent:location:force:contextId:);
                    if ([translator respondsToSelector:pressEventSelector]) {
                        NSLog(@"[DEBUG] _sendPressFingerEvent selector found");
                        NSMethodSignature* sig = [translator methodSignatureForSelector:pressEventSelector];
                        if (sig && sig.numberOfArguments >= 6) {
                            NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
                            [inv setTarget:translator];
                            [inv setSelector:pressEventSelector];
                            
                            BOOL pressed = down;
                            CGPoint location = CGPointMake(x, y);
                            double force = 1.0;
                            unsigned int contextId = 0;
                            
                            [inv setArgument:&pressed atIndex:2];
                            [inv setArgument:&location atIndex:3];
                            [inv setArgument:&force atIndex:4];
                            [inv setArgument:&contextId atIndex:5];
                            [inv invoke];
                            
                            NSLog(@"[DEBUG] Sent touch via accessibility translator");
                            return IDB_SUCCESS;
                        }
                    } else {
                        NSLog(@"[DEBUG] _sendPressFingerEvent selector NOT found on translator");
                        // Try alternative method
                        SEL simulatePressSelector = @selector(simulatePressAtPoint:withContextId:withDelay:withForce:);
                        if ([translator respondsToSelector:simulatePressSelector]) {
                            NSLog(@"[DEBUG] simulatePressAtPoint selector found");
                            NSMethodSignature* sig2 = [translator methodSignatureForSelector:simulatePressSelector];
                            if (sig2 && sig2.numberOfArguments >= 6) {
                                NSInvocation* inv2 = [NSInvocation invocationWithMethodSignature:sig2];
                                [inv2 setTarget:translator];
                                [inv2 setSelector:simulatePressSelector];
                                
                                CGPoint location = CGPointMake(x, y);
                                unsigned int contextId = 0;
                                float delay = 0.0f;
                                double force = 1.0;
                                
                                [inv2 setArgument:&location atIndex:2];
                                [inv2 setArgument:&contextId atIndex:3];
                                [inv2 setArgument:&delay atIndex:4];
                                [inv2 setArgument:&force atIndex:5];
                                [inv2 invoke];
                                
                                NSLog(@"[DEBUG] Sent touch via simulatePressAtPoint");
                                return IDB_SUCCESS;
                            }
                        }
                    }
                } else {
                    NSLog(@"[DEBUG] Failed to get translator instance");
                }
            } else {
                NSLog(@"[DEBUG] sharedInstance selector NOT found on AXPTranslatorClass");
            }
        } else {
            NSLog(@"[DEBUG] AXPTranslatorClass not available");
        }
        
        // Approach 3: Try postMouseEvent selector (older API)
        SEL mouseEventSelector = NSSelectorFromString(@"postMouseEventWithType:x:y:");
        NSLog(@"[DEBUG] Checking postMouseEvent selector...");
        if ([current_device respondsToSelector:mouseEventSelector]) {
            NSLog(@"[DEBUG] postMouseEvent selector found");
            NSMethodSignature* sig = [current_device methodSignatureForSelector:mouseEventSelector];
            NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:current_device];
            [inv setSelector:mouseEventSelector];
            
            int eventType = down ? 1 : 2; // 1=down, 2=up
            [inv setArgument:&eventType atIndex:2];
            [inv setArgument:&x atIndex:3];
            [inv setArgument:&y atIndex:4];
            [inv invoke];
            
            NSLog(@"[DEBUG] Sent mouse event via postMouseEvent");
            return IDB_SUCCESS;
        } else {
            NSLog(@"[DEBUG] postMouseEvent selector NOT found");
        }
        
        // Approach 4: Try sendEventWithType (newer API)
        SEL sendEventSelector = NSSelectorFromString(@"sendEventWithType:path:error:");
        NSLog(@"[DEBUG] Checking sendEventWithType selector...");
        if ([current_device respondsToSelector:sendEventSelector]) {
            NSLog(@"[DEBUG] sendEventWithType selector found");
            NSMethodSignature* sig = [current_device methodSignatureForSelector:sendEventSelector];
            NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:current_device];
            [inv setSelector:sendEventSelector];
            
            NSString* eventType = @"touch";
            NSArray* path = @[@{
                @"x": @(x),
                @"y": @(y),
                @"type": down ? @"down" : @"up"
            }];
            
            [inv setArgument:&eventType atIndex:2];
            [inv setArgument:&path atIndex:3];
            [inv setArgument:&error atIndex:4];
            [inv invoke];
            
            BOOL result = NO;
            [inv getReturnValue:&result];
            
            if (result) {
                NSLog(@"[DEBUG] Sent touch event via sendEventWithType");
                return IDB_SUCCESS;
            } else {
                NSLog(@"[DEBUG] sendEventWithType returned NO, error: %@", error);
            }
        } else {
            NSLog(@"[DEBUG] sendEventWithType selector NOT found");
        }
        
        // Approach 5: Try HID interface
        SEL hidSelector = NSSelectorFromString(@"hid");
        if ([current_device respondsToSelector:hidSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id hid = [current_device performSelector:hidSelector];
#pragma clang diagnostic pop
            if (hid) {
                // Try various HID methods
                SEL tapSelector = NSSelectorFromString(@"tapAtX:y:");
                if ([hid respondsToSelector:tapSelector]) {
                    NSMethodSignature* sig = [hid methodSignatureForSelector:tapSelector];
                    NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:hid];
                    [inv setSelector:tapSelector];
                    [inv setArgument:&x atIndex:2];
                    [inv setArgument:&y atIndex:3];
                    [inv invoke];
                    
                    NSLog(@"Sent tap via HID interface");
                    return IDB_SUCCESS;
                }
            }
        }
        
        // Approach 6: Try device IO interface for touch events
        SEL ioSelector = @selector(io);
        if ([current_device respondsToSelector:ioSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id ioClient = [current_device performSelector:ioSelector];
#pragma clang diagnostic pop
            
            if (ioClient) {
                SEL sendEventSelector = @selector(sendEvent:completionQueue:completionHandler:);
                if ([ioClient respondsToSelector:sendEventSelector]) {
                    NSLog(@"Found sendEvent method on IO client");
                }
            }
        }
        
        NSLog(@"No compatible touch API found");
        return IDB_ERROR_UNSUPPORTED;
    }
}

idb_error_t idb_touch_event(idb_touch_type_t type, double x, double y) {
    return idb_mouse_event(x, y, type == IDB_TOUCH_DOWN);
}

idb_error_t idb_swipe(idb_point_t from, idb_point_t to, double duration_seconds) {
    __block id current_device = nil;
    IDB_SYNCHRONIZED({
        current_device = g_idb_state.current_device;
    });
    
    if (!current_device) {
        return IDB_ERROR_DEVICE_NOT_FOUND;
    }
    
    // For Xcode 16+, try to send a swipe event via sendAccessibilityRequestAsync
    SEL sendAccessibilitySelector = @selector(sendAccessibilityRequestAsync:completionQueue:completionHandler:);
    if ([current_device respondsToSelector:sendAccessibilitySelector]) {
        Class AXPTranslatorRequestClass = NSClassFromString(@"AXPTranslatorRequest");
        if (AXPTranslatorRequestClass) {
            id request = [[AXPTranslatorRequestClass alloc] init];
            if (request) {
                // Set request type to press
                SEL setRequestTypeSelector = @selector(setRequestType:);
                if ([request respondsToSelector:setRequestTypeSelector]) {
                    NSInteger requestType = 1; // AXPTranslatorRequestTypePress
                    NSMethodSignature* sig = [request methodSignatureForSelector:setRequestTypeSelector];
                    NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:request];
                    [inv setSelector:setRequestTypeSelector];
                    [inv setArgument:&requestType atIndex:2];
                    [inv invoke];
                }
                
                // Create event path for swipe
                SEL setEventPathSelector = @selector(setEventPath:);
                if ([request respondsToSelector:setEventPathSelector]) {
                    NSMutableArray* eventPath = [NSMutableArray array];
                    
                    // Calculate number of points for smooth swipe
                    int numPoints = MAX(10, (int)(duration_seconds * 60)); // 60 points per second
                    double dx = (to.x - from.x) / (numPoints - 1);
                    double dy = (to.y - from.y) / (numPoints - 1);
                    double dt = duration_seconds / (numPoints - 1);
                    double startTime = [[NSDate date] timeIntervalSince1970];
                    
                    for (int i = 0; i < numPoints; i++) {
                        NSMutableDictionary* event = [NSMutableDictionary dictionary];
                        event[@"x"] = @(from.x + dx * i);
                        event[@"y"] = @(from.y + dy * i);
                        
                        if (i == 0) {
                            event[@"phase"] = @1; // began
                        } else if (i == numPoints - 1) {
                            event[@"phase"] = @16; // ended
                        } else {
                            event[@"phase"] = @2; // moved
                        }
                        
                        event[@"force"] = @1.0;
                        event[@"timestamp"] = @(startTime + dt * i);
                        
                        [eventPath addObject:event];
                    }
                    
                    NSMethodSignature* sig = [request methodSignatureForSelector:setEventPathSelector];
                    NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:request];
                    [inv setSelector:setEventPathSelector];
                    [inv setArgument:&eventPath atIndex:2];
                    [inv invoke];
                }
                
                // Send the request asynchronously
                dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
                __block idb_error_t result = IDB_ERROR_OPERATION_FAILED;
                
                dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
                
                NSMethodSignature* sig = [current_device methodSignatureForSelector:sendAccessibilitySelector];
                NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:current_device];
                [inv setSelector:sendAccessibilitySelector];
                [inv setArgument:&request atIndex:2];
                [inv setArgument:&queue atIndex:3];
                
                void (^completionHandler)(id) = ^(id response) {
                    if (response) {
                        SEL errorSelector = @selector(error);
                        if ([response respondsToSelector:errorSelector]) {
                            NSError* responseError = nil;
                            NSMethodSignature* errorSig = [response methodSignatureForSelector:errorSelector];
                            NSInvocation* errorInv = [NSInvocation invocationWithMethodSignature:errorSig];
                            [errorInv setTarget:response];
                            [errorInv setSelector:errorSelector];
                            [errorInv invoke];
                            [errorInv getReturnValue:&responseError];
                            
                            if (!responseError) {
                                result = IDB_SUCCESS;
                                NSLog(@"[DEBUG] Swipe sent successfully via sendAccessibilityRequestAsync");
                            }
                        } else {
                            result = IDB_SUCCESS;
                            NSLog(@"[DEBUG] Swipe sent successfully via sendAccessibilityRequestAsync");
                        }
                    }
                    dispatch_semaphore_signal(semaphore);
                };
                
                [inv setArgument:&completionHandler atIndex:4];
                [inv invoke];
                
                dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (duration_seconds + 5) * NSEC_PER_SEC);
                if (dispatch_semaphore_wait(semaphore, timeout) == 0 && result == IDB_SUCCESS) {
                    return result;
                }
            }
        }
    }
    
    // Fall back to simple implementation using touch down, move, up
    idb_error_t error = idb_touch_event(IDB_TOUCH_DOWN, from.x, from.y);
    if (error != IDB_SUCCESS) return error;
    
    // Sleep for duration
    [NSThread sleepForTimeInterval:duration_seconds];
    
    error = idb_touch_event(IDB_TOUCH_UP, to.x, to.y);
    return error;
}

idb_error_t idb_take_screenshot(idb_screenshot_t* screenshot) {
    if (!screenshot) {
        return IDB_ERROR_INVALID_PARAMETER;
    }
    
    __block id current_device = nil;
    IDB_SYNCHRONIZED({
        current_device = g_idb_state.current_device;
    });
    
    if (!current_device) {
        return IDB_ERROR_DEVICE_NOT_FOUND;
    }
    
    @autoreleasepool {
        NSError* error = nil;
        NSData* imageData = nil;
        
        // Approach 1: Try IO-based screenshot through display port
        SEL ioSelector = @selector(io);
        if ([current_device respondsToSelector:ioSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id ioClient = [current_device performSelector:ioSelector];
#pragma clang diagnostic pop
            
            if (ioClient) {
                SEL ioPortsSelector = @selector(ioPorts);
                if ([ioClient respondsToSelector:ioPortsSelector]) {
                    NSArray* ioPorts = [ioClient performSelector:ioPortsSelector];
                    for (id port in ioPorts) {
                        // Check if this port has a display descriptor
                        SEL descriptorSelector = @selector(descriptor);
                        if ([port respondsToSelector:descriptorSelector]) {
                            id descriptor = [port performSelector:descriptorSelector];
                            if (descriptor) {
                                // Check if this is a main display
                                SEL stateSelector = @selector(state);
                                if ([descriptor respondsToSelector:stateSelector]) {
                                    id descriptorState = [descriptor performSelector:stateSelector];
                                    SEL displayClassSelector = @selector(displayClass);
                                    if ([descriptorState respondsToSelector:displayClassSelector]) {
                                        NSMethodSignature* sig = [descriptorState methodSignatureForSelector:displayClassSelector];
                                        NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
                                        [inv setTarget:descriptorState];
                                        [inv setSelector:displayClassSelector];
                                        [inv invoke];
                                        
                                        unsigned short displayClass = 0;
                                        [inv getReturnValue:&displayClass];
                                        
                                        if (displayClass == 0) { // Main display
                                            NSLog(@"Found main display descriptor");
                                            // Try to get screenshot from this display
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Approach 2: Try different screenshot methods
        SEL screenshotSelector = NSSelectorFromString(@"screenshotWithError:");
        SEL screenshotSelectorNoError = NSSelectorFromString(@"screenshot");
        
        if ([current_device respondsToSelector:screenshotSelector]) {
            NSMethodSignature* sig = [current_device methodSignatureForSelector:screenshotSelector];
            NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:current_device];
            [inv setSelector:screenshotSelector];
            [inv setArgument:&error atIndex:2];
            [inv invoke];
            [inv getReturnValue:&imageData];
        } else if ([current_device respondsToSelector:screenshotSelectorNoError]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            imageData = [current_device performSelector:screenshotSelectorNoError];
#pragma clang diagnostic pop
        }
        
        // Approach 3: Try framebuffer-based screenshot
        if (!imageData) {
            SEL framebufferSelector = NSSelectorFromString(@"framebuffer");
            if ([current_device respondsToSelector:framebufferSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id framebuffer = [current_device performSelector:framebufferSelector];
#pragma clang diagnostic pop
                if (framebuffer) {
                    NSLog(@"Found framebuffer object: %@", framebuffer);
                    // Would need to extract image data from framebuffer
                }
            }
        }
        
        if (!imageData) {
            NSLog(@"Screenshot failed: %@", error ? error : @"No compatible screenshot API found");
            return IDB_ERROR_OPERATION_FAILED;
        }
        
        screenshot->data = malloc(imageData.length);
        if (!screenshot->data) {
            return IDB_ERROR_OUT_OF_MEMORY;
        }
        
        memcpy(screenshot->data, imageData.bytes, imageData.length);
        screenshot->size = imageData.length;
        screenshot->format = strdup("png");
        if (!screenshot->format) {
            free(screenshot->data);
            screenshot->data = NULL;
            return IDB_ERROR_OUT_OF_MEMORY;
        }
        
        // Try to get image dimensions from PNG data
        screenshot->width = 0;
        screenshot->height = 0;
        
        // Use Core Graphics to get dimensions from PNG data
        CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, imageData.bytes, imageData.length, NULL);
        if (provider) {
            CGImageRef image = CGImageCreateWithPNGDataProvider(provider, NULL, false, kCGRenderingIntentDefault);
            if (image) {
                screenshot->width = (uint32_t)CGImageGetWidth(image);
                screenshot->height = (uint32_t)CGImageGetHeight(image);
                NSLog(@"Screenshot dimensions: %dx%d", screenshot->width, screenshot->height);
                CGImageRelease(image);
            }
            CGDataProviderRelease(provider);
        }
        
        return IDB_SUCCESS;
    }
}

void idb_free_screenshot(idb_screenshot_t* screenshot) {
    if (screenshot) {
        free(screenshot->data);
        free(screenshot->format);
        screenshot->data = NULL;
        screenshot->format = NULL;
        screenshot->size = 0;
        screenshot->width = 0;
        screenshot->height = 0;
    }
}

const char* idb_error_string(idb_error_t error) {
    int index = -error;
    if (index >= 0 && index < sizeof(g_error_strings)/sizeof(g_error_strings[0])) {
        return g_error_strings[index];
    }
    
    // Handle extended error codes
    switch (error) {
        case IDB_ERROR_NOT_IMPLEMENTED:
            return "Not implemented";
        case IDB_ERROR_UNSUPPORTED:
            return "Unsupported";
        case IDB_ERROR_PERMISSION_DENIED:
            return "Permission denied";
        case IDB_ERROR_APP_NOT_FOUND:
            return "App not found";
        case IDB_ERROR_INVALID_APP_BUNDLE:
            return "Invalid app bundle";
        default:
            return "Unknown error";
    }
}

const char* idb_version(void) {
#ifdef IDB_VERSION
    return IDB_VERSION;
#else
    return "0.1.0-adaptive-xcode16";
#endif
}