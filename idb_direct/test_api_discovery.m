#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdio.h>
#import "idb_direct.h"

void print_methods_for_class(Class cls, const char* className) {
    printf("\n=== Methods for %s ===\n", className);
    
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    
    for (unsigned int i = 0; i < methodCount; i++) {
        Method method = methods[i];
        SEL selector = method_getName(method);
        const char* name = sel_getName(selector);
        
        // Filter for interesting methods
        if (strstr(name, "event") || strstr(name, "Event") ||
            strstr(name, "touch") || strstr(name, "Touch") ||
            strstr(name, "mouse") || strstr(name, "Mouse") ||
            strstr(name, "tap") || strstr(name, "Tap") ||
            strstr(name, "press") || strstr(name, "Press") ||
            strstr(name, "click") || strstr(name, "Click") ||
            strstr(name, "hid") || strstr(name, "HID") ||
            strstr(name, "screen") || strstr(name, "Screen") ||
            strstr(name, "shot") || strstr(name, "Shot") ||
            strstr(name, "capture") || strstr(name, "Capture") ||
            strstr(name, "send") || strstr(name, "Send")) {
            printf("  %s\n", name);
        }
    }
    
    free(methods);
}

void explore_object_methods(id obj, const char* objName) {
    if (!obj) {
        printf("\n%s is nil\n", objName);
        return;
    }
    
    Class cls = [obj class];
    printf("\n=== Object: %s (class: %s) ===\n", objName, class_getName(cls));
    print_methods_for_class(cls, class_getName(cls));
}

extern id g_idb_state_current_device(void);

int main(int argc, char* argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            printf("Usage: %s <device_udid>\n", argv[0]);
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
        
        // Get the device object
        id device = g_idb_state_current_device();
        explore_object_methods(device, "SimDevice");
        
        // Check for io object
        SEL ioSelector = @selector(io);
        if ([device respondsToSelector:ioSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id ioClient = [device performSelector:ioSelector];
#pragma clang diagnostic pop
            explore_object_methods(ioClient, "SimDevice.io");
            
            // Check IO ports
            SEL ioPortsSelector = @selector(ioPorts);
            if ([ioClient respondsToSelector:ioPortsSelector]) {
                NSArray* ioPorts = [ioClient performSelector:ioPortsSelector];
                printf("\nFound %lu IO ports\n", (unsigned long)ioPorts.count);
                for (id port in ioPorts) {
                    explore_object_methods(port, "IOPort");
                    break; // Just check first port
                }
            }
        }
        
        // Check for AXPTranslator
        Class AXPTranslatorClass = NSClassFromString(@"AXPTranslator_iOS");
        if (AXPTranslatorClass) {
            print_methods_for_class(AXPTranslatorClass, "AXPTranslator_iOS");
            
            SEL sharedInstanceSelector = @selector(sharedInstance);
            if ([AXPTranslatorClass respondsToSelector:sharedInstanceSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id translator = [AXPTranslatorClass performSelector:sharedInstanceSelector];
#pragma clang diagnostic pop
                explore_object_methods(translator, "AXPTranslator_iOS instance");
            }
        }
        
        // Cleanup
        printf("\nDisconnecting...\n");
        idb_disconnect_target();
        idb_shutdown();
        
        return 0;
    }
}