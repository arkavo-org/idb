# TODO: Implement proper AXPTranslatorRequest for touch events in Xcode 16+

## Feature Request: Implement AXPTranslatorRequest for Touch Events

### Background
As of Xcode 16, Apple has removed legacy touch injection APIs (`postMouseEventWithType:x:y:`, `sendEventWithType:path:error:`, etc.), making `sendAccessibilityRequestAsync:completionQueue:completionHandler:` the sole method for sending touch events to simulators.

This method has been available since Xcode 12 (when it replaced SimulatorBridge-related accessibility requests), but it's now mandatory in Xcode 16+.

### Current State
PR #5 provides the groundwork by:
- Loading necessary frameworks (AccessibilityPlatformTranslation)
- Implementing method discovery and fallback chains
- Adding debug logging

However, touch events still fail because we need to properly implement the `AXPTranslatorRequest` protocol.

### Required Implementation

To make touch events work in Xcode 16+, we need to:

1. **Create proper `AXPTranslatorRequest` objects**
   - Use type `AXPTranslatorRequestTypePress` for touch events
   - Implement the required protocol methods

2. **Populate `AXPTranslatorEventPath` arrays**
   ```objc
   // Example structure needed:
   AXPTranslatorEventPath eventPath = {
       .location = CGPointMake(x, y),
       .phase = kAXPEventPhaseBegan | kAXPEventPhaseEnded  // For tap
   };
   ```

3. **Handle async responses**
   - Process `AXPTranslatorResponse` from the completion handler
   - Handle errors appropriately

4. **Support different touch types**
   - Tap: Single event with began|ended phases
   - Swipe: Multiple events with proper phase transitions
   - Long press: Delayed phase transitions

### Technical Details

The main implementation would involve:
- Creating request objects conforming to `AXPTranslatorRequest` protocol
- Setting appropriate event types and parameters
- Calling `[device sendAccessibilityRequestAsync:request completionQueue:queue completionHandler:^(AXPTranslatorResponse *response) { ... }]`

### Example Implementation Skeleton

```objc
// In idb_direct_real_adaptive.m

static idb_error_t send_accessibility_touch_event(id device, double x, double y, BOOL down) {
    // Create request
    Class AXPTranslatorRequestClass = NSClassFromString(@"AXPTranslatorRequest");
    if (!AXPTranslatorRequestClass) {
        return IDB_ERROR_UNSUPPORTED;
    }
    
    // Create request of type press
    id request = [[AXPTranslatorRequestClass alloc] init];
    // Set request type to AXPTranslatorRequestTypePress
    // Set event path with coordinates and phases
    
    // Send async request
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block idb_error_t result = IDB_ERROR_OPERATION_FAILED;
    
    SEL sendAccessibilitySelector = @selector(sendAccessibilityRequestAsync:completionQueue:completionHandler:);
    if ([device respondsToSelector:sendAccessibilitySelector]) {
        // Invoke with proper parameters
        // Handle response in completion block
        // Signal semaphore
    }
    
    // Wait for completion with timeout
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    
    return result;
}
```

### References
- AccessibilityPlatformTranslation framework headers
- CoreSimulator private headers showing the method signature
- Existing idb codebase using similar patterns in `FBSimulatorAccessibilityCommands.m`

### Acceptance Criteria
- [ ] Touch events (tap, swipe) work on Xcode 16+ simulators
- [ ] Proper error handling for failed requests
- [ ] Support for basic touch gestures (tap, swipe, long press)
- [ ] Maintains backward compatibility with older Xcode versions

### Priority
High - This is blocking touch automation on modern Xcode versions

### Related
- PR #5 - Groundwork for Xcode 16.2 compatibility
- Original issue: Touch and screenshot API support for libidb_direct v1.3.2-arkavo.1