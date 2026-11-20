// Integration test linked with the production desktop view and GVM. Input is
// delivered by an actual NSWindow; observations use AppKit's public controls.
#import "../Native.h"

static void check(BOOL ok, NSString *why) {
    if (!ok) DesktopFailure(why);
}

static NSButton *button(DesktopView *view, NSString *prefix) {
    for (NSButton *item in view.subviews) {
        if ([item isKindOfClass:NSButton.class] && [item.title hasPrefix:prefix]) return item;
    }
    DesktopFailure([@"Missing native button " stringByAppendingString:prefix]);
}

static BOOL label(DesktopView *view, NSString *text) {
    for (id item in view.accessibilityChildren)
        if ([[item accessibilityValue] isEqual:text]) return YES;
    return NO;
}

static void click(NSWindow *window, NSButton *target) {
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

static void press(NSWindow *window, NSString *text, unsigned short code) {
    NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
        characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
    [window sendEvent:key];
}

static void inspect(NSURL *resources, NSString *capture) {
    DesktopView *view = [[DesktopView alloc] initWithResources:resources];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:view.bounds
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Mochi desktop regression";
    window.contentView = view;
    window.releasedWhenClosed = NO;
    window.autorecalculatesKeyViewLoop = NO;
    [window makeKeyAndOrderFront:nil];
    [window display];
    check(window.isVisible && label(view, @"Selected station 01"), @"initial native frame");
    NSArray *buttons = [view.subviews filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSView *item, NSDictionary *unused) {
            return [item isKindOfClass:NSButton.class];
        }]];
    check(buttons.count == 5, @"three station buttons and two inspector actions");
    NSButton *harbor = button(view, @"Harbor");
    check([harbor.accessibilityValue boolValue], @"station 01 is initially pressed");
    NSButton *cafe = button(view, @"Café");
    click(window, cafe);
    check(label(view, @"Selected station 02") && [cafe.accessibilityValue boolValue], @"pointer selects using Ruby dataset");
    [window makeFirstResponder:harbor];
    check([button(view, @"Reverse") accessibilityPerformPress], @"accessible press of reverse control");
    check(window.firstResponder == harbor && button(view, @"Harbor") == harbor &&
          harbor.frame.origin.y > button(view, @"West").frame.origin.y, @"keyed focus and ordering");
    check(label(view, @"Selected station 02"), @"selection survives reorder");
    [window makeFirstResponder:button(view, @"Details")];
    press(window, @" ", 49);
    check(label(view, @"Showing details for station 02"), @"Space toggles Ruby details");
    press(window, @"\r", 36);
    check(!label(view, @"Showing details for station 02"), @"Return closes details");
    press(window, @" ", 49);
    CGFloat wide = cafe.frame.size.height;
    [window setContentSize:NSMakeSize(285, 540)];
    [window display];
    check(cafe.frame.size.height > wide && cafe.frame.size.width < 285, @"native font measurement and wrapped layout");
    check(window.firstResponder == button(view, @"Details"), @"resize retains keyboard focus");
    press(window, @"\t", 48);
    check(window.firstResponder == button(view, @"West"), @"tab order follows reversed rows");
    press(window, @" ", 49);
    check(label(view, @"Showing details for station 03"), @"keyboard event resolves the moved row");
    if (capture) {
        NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        check([png writeToFile:capture atomically:YES], @"capture native drawing");
    }
    [view close];
    [window close];
    check(!window.isVisible, @"native window closes");
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) return 2;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        @try {
            inspect([NSURL fileURLWithPath:@(argv[1])], argc > 2 ? @(argv[2]) : nil);
            puts("PASS native inspector: click, accessibility, keyed identity and focus, keyboard, resize, drawing, teardown");
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL %s\n", exception.reason.UTF8String);
            return 1;
        }
    }
    return 0;
}
