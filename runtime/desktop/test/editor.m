#import "../Native.h"
#import "AppKitEvents.h"

static void check(BOOL condition, NSString *message) {
    if (!condition) DesktopFailure(message);
}

static id find(DesktopView *view, NSString *attribute, NSString *value) {
    for (id element in view.accessibilityChildren) {
        if ([[view attributesForAccessibilityElement:element][attribute] isEqual:value]) return element;
    }
    DesktopFailure([@"Missing editor element " stringByAppendingString:value]);
}

static void inspect(NSURL *resources) {
    DesktopView *view = [[DesktopView alloc] initWithResources:resources];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:view.bounds
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.autorecalculatesKeyViewLoop = NO;
    window.contentView = view;
    [window makeKeyAndOrderFront:nil];
    NSTextField *field = find(view, @"data-field", @"name");
    NSButton *checkbox = find(view, @"data-field", @"open");
    NSButton *refresh = find(view, @"data-action", @"refresh");
    NSButton *lock = find(view, @"data-action", @"lock");
    check([field.accessibilityRole isEqual:NSAccessibilityTextFieldRole] &&
        [field.accessibilityLabel isEqual:@"Station name"] && [field.accessibilityValue isEqual:@"Harbor"] &&
        field.accessibilityEnabled, [NSString stringWithFormat:@"field AX role %@, label %@, value %@, enabled %d, control enabled %d",
        field.accessibilityRole, field.accessibilityLabel, field.accessibilityValue, field.accessibilityEnabled, field.enabled]);
    check([checkbox.accessibilityRole isEqual:NSAccessibilityCheckBoxRole] &&
        [checkbox.accessibilityLabel isEqual:@"Open to public"] &&
        ![checkbox.accessibilityValue boolValue] && checkbox.accessibilityEnabled,
        [NSString stringWithFormat:@"checkbox AX role %@, label %@, value %@, enabled %d",
        checkbox.accessibilityRole, checkbox.accessibilityLabel, checkbox.accessibilityValue, checkbox.accessibilityEnabled]);

    [field selectText:nil];
    NSTextView *editor = (NSTextView *)field.currentEditor;
    check(editor && window.firstResponder == editor, @"AppKit is using the actual field editor");
    editor.selectedRange = NSMakeRange(1, 3);
    [refresh accessibilityPerformPress];
    check(field == find(view, @"data-field", @"name") && field.currentEditor == editor &&
        NSEqualRanges(editor.selectedRange, NSMakeRange(1, 3)), @"unrelated patches retain text identity and selection");

    NSPasteboard *clipboard = [NSPasteboard pasteboardWithUniqueName];
    [clipboard clearContents];
    [clipboard setString:@"orth" forType:NSPasteboardTypeString];
    check([editor readSelectionFromPasteboard:clipboard], @"native field editor reads the pasteboard");
    [clipboard releaseGlobally];
    check([editor.string isEqual:@"Horthor"], @"paste replaces exactly the selected text");
    check([[find(view, @"data-view", @"history") accessibilityValue] isEqual:@"input=Horthor"],
        @"paste commits once");

    NSMenuItem *selectAll = [[NSApp.mainMenu itemWithTitle:@"Edit"].submenu itemWithTitle:@"Select All"];
    check([selectAll.keyEquivalent isEqual:@"a"] && selectAll.keyEquivalentModifierMask == NSEventModifierFlagCommand &&
        selectAll.action == @selector(selectAll:) && !selectAll.target, @"Command-A is registered on the Edit menu");
    // Replay windows use an accessory process. Resolve the nil-target menu
    // action through this window's real first responder even in the background.
    check([window.firstResponder tryToPerform:selectAll.action with:selectAll] &&
        NSEqualRanges(editor.selectedRange, NSMakeRange(0, editor.string.length)),
        @"the AppKit field editor handles the Edit menu's Select All action");
    [editor setMarkedText:@"e" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    NSRange marked = editor.markedRange, selected = editor.selectedRange;
    check(editor.hasMarkedText && [editor.string isEqual:@"e"], @"AppKit has a marked composition draft");
    [refresh accessibilityPerformPress];
    CGFloat wide = field.frame.size.width;
    [window setContentSize:NSMakeSize(335, 560)];
    check(field.frame.size.width < wide && field.currentEditor == editor &&
        window.firstResponder == editor && editor.hasMarkedText &&
        NSEqualRanges(editor.markedRange, marked) && NSEqualRanges(editor.selectedRange, selected),
        @"unrelated Ruby updates and resize retain marked text and selection");
    check([[find(view, @"data-view", @"history") accessibilityValue] isEqual:@"input=Horthor"],
        @"marked text did not run the Ruby handler");

    [editor insertText:@"é" replacementRange:NSMakeRange(NSNotFound, 0)];
    check(!editor.hasMarkedText && [editor.string isEqual:@"é"] && NSEqualRanges(editor.selectedRange, NSMakeRange(1, 0)),
        @"committed accent retains the caret");
    [window setContentSize:NSMakeSize(500, 560)];
    check(field.currentEditor == editor && [field.accessibilityValue isEqual:@"é"] &&
        NSEqualRanges(editor.selectedRange, NSMakeRange(1, 0)), @"field value and caret survive resize after commit");

    press(window, @"\t", 48);
    check(window.firstResponder == checkbox, @"Tab moves from the field editor to the checkbox");
    press(window, @" ", 49);
    check([checkbox.accessibilityValue boolValue], @"Space checks the native switch");
    check([[find(view, @"data-view", @"history") accessibilityValue] isEqual:@"input=Horthor | input=é | change=true"],
        @"Ruby sees each committed edit exactly once in order");

    [lock accessibilityPerformPress];
    check(!field.accessibilityEnabled && !checkbox.accessibilityEnabled, @"AX exposes both controls as disabled");
    click(window, field);
    click(window, checkbox);
    check(![checkbox accessibilityPerformPress] && [checkbox.accessibilityValue boolValue] &&
        [field.accessibilityValue isEqual:@"é"] && window.firstResponder != field.currentEditor &&
        [[find(view, @"data-view", @"history") accessibilityValue] isEqual:@"input=Horthor | input=é | change=true"],
        @"disabled controls reject pointer and accessibility activation");

    [view close];
    [window close];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSMenu *menu = [NSMenu new];
        NSMenuItem *application = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
        application.submenu = [NSMenu new];
        [application.submenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        DesktopInstallEditMenu(menu);
        NSApp.mainMenu = menu;
        [NSApp finishLaunching];
        @try {
            inspect([NSURL fileURLWithPath:@(argv[1])]);
        } @catch (NSException *error) {
            fprintf(stderr, "FAIL native editor: %s\n", error.reason.UTF8String);
            return 1;
        }
        puts("PASS native editor selection, paste, marked text, resize, keyboard and accessibility");
    }
    return 0;
}
