#import <AppKit/AppKit.h>

static inline void click(NSWindow *window, NSView *target) {
    NSPoint middle = NSMakePoint(NSMidX(target.bounds), NSMidY(target.bounds));
    NSPoint point = [target convertPoint:middle toView:nil];
    NSEvent *(^event)(NSEventType) = ^(NSEventType type) {
        return [NSEvent mouseEventWithType:type location:point modifierFlags:0
            timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
            context:nil eventNumber:1 clickCount:1 pressure:1];
    };
    [NSApp postEvent:event(NSEventTypeLeftMouseUp) atStart:YES];
    [window sendEvent:event(NSEventTypeLeftMouseDown)];
}

static inline void press(NSWindow *window, NSString *text, unsigned short code) {
    NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
        characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
    [window sendEvent:key];
}
