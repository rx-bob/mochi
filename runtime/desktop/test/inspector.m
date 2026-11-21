// Integration test linked with the production desktop view and GVM. Input is
// delivered by an actual NSWindow; observations use AppKit's public controls.
#import "../Native.h"
#import "AppKitEvents.h"

extern int32_t mochi_component_count(void);

static void check(BOOL ok, NSString *why) {
    if (!ok) DesktopFailure(why);
}

static NSButton *button(DesktopView *view, NSString *prefix) {
    for (NSButton *item in view.accessibilityChildren) {
        if ([item isKindOfClass:NSButton.class] && [item.title hasPrefix:prefix]) return item;
    }
    DesktopFailure([@"Missing native button " stringByAppendingString:prefix]);
}

static BOOL label(DesktopView *view, NSString *text) {
    for (id item in view.accessibilityChildren)
        if ([[item accessibilityValue] isEqual:text]) return YES;
    return NO;
}

static id element(DesktopView *view, NSString *name) {
    for (id item in view.accessibilityChildren) {
        if ([[view attributesForAccessibilityElement:item][@"data-view"] isEqual:name]) return item;
    }
    DesktopFailure([@"Missing native element " stringByAppendingString:name]);
}

@interface DesktopView (AnnouncementProbe)
- (void)announce:(NSString *)text priority:(NSAccessibilityPriorityLevel)priority;
@end

@interface EditorProbeView : DesktopView
@property(nonatomic, strong) NSMutableArray<NSString *> *announcements;
@end

@implementation EditorProbeView
- (void)announce:(NSString *)text priority:(NSAccessibilityPriorityLevel)priority {
    check(priority == NSAccessibilityPriorityMedium, @"editor uses polite announcements");
    [self.announcements addObject:text];
    [super announce:text priority:priority];
}
@end

static void fillField(NSTextField *field, NSWindow *window, NSString *text) {
    check([window makeFirstResponder:field], @"focus the native station name field");
    NSTextView *editor = (NSTextView *)field.currentEditor;
    [editor insertText:text replacementRange:NSMakeRange(0, editor.string.length)];
}

static void checkEditor(NSURL *resources, NSString *persistedName, BOOL persistedOpen) {
    DesktopProgram *program = [[DesktopProgram alloc] initWithResources:resources];
    NSMutableArray *diagnostics = [NSMutableArray array];
    EditorProbeView *view = [[EditorProbeView alloc] initWithProgram:program attributes:@{}
                                                         diagnostics:^(NSString *error) { [diagnostics addObject:error]; }];
    view.announcements = [NSMutableArray array];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 560)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.autorecalculatesKeyViewLoop = NO;
    window.contentView = view;
    [window makeKeyAndOrderFront:nil];
    @try {
        NSButton *edit = button(view, @"Edit station");
        NSButton *row = button(view, persistedName ?: @"Café");
        [row accessibilityPerformPress];
        [edit accessibilityPerformPress];
        NSTextField *field = element(view, @"name-field");
        NSButton *open = element(view, @"open-field");
        NSButton *save = button(view, @"Save station");
        check([field.accessibilityRole isEqual:NSAccessibilityTextFieldRole] &&
              [field.accessibilityLabel isEqual:@"Station name"] && field.currentEditor == window.firstResponder,
              @"the editor exposes and focuses the named native text field");
        check([open.accessibilityRole isEqual:NSAccessibilityCheckBoxRole] &&
              [open.accessibilityLabel isEqual:@"Open to public"] &&
              [open.accessibilityValue boolValue] == persistedOpen && !save.enabled && ![save accessibilityPerformPress],
              @"the native checkbox state and disabled save are accessible");
        if (persistedName) {
            check([field.accessibilityValue isEqual:persistedName], @"a fresh process opens the durable name and checkbox");
            return;
        }
        fillField(field, window, @" ");
        [window makeFirstResponder:save];
        press(window, @" ", 49);
        check(field.currentEditor == window.firstResponder &&
              [view.announcements isEqual:@[@"Enter a station name."]] &&
              label(view, @"Enter a station name."), @"announce validation once and return focus to the invalid field");
        press(window, @"\t", 48);
        check(window.firstResponder == open, @"native reading order reaches the checkbox after the text field");
        fillField(field, window, @"Café Saved");
        click(window, save);
        check(button(view, @"Café Saved") == row && window.firstResponder == edit, @"save updates the retained row and restores focus");
        [edit accessibilityPerformPress];
        field = element(view, @"name-field");
        open = element(view, @"open-field");
        save = button(view, @"Save station");
        fillField(field, window, @"North gate");
        [open accessibilityPerformPress];
        [window makeFirstResponder:save];
        NSString *directory = NSProcessInfo.processInfo.environment[@"MOCHI_DESKTOP_STORAGE_DIR"];
        NSString *backup = [directory stringByAppendingString:@".held"];
        NSFileManager *files = NSFileManager.defaultManager;
        check(directory.length && [files moveItemAtPath:directory toPath:backup error:NULL], @"hold the isolated station store");
        BOOL blocked = [files createFileAtPath:directory contents:[NSData data] attributes:nil];
        @try {
            check(blocked, @"block writes to the isolated store");
            press(window, @" ", 49);
            check(diagnostics.count == 1 && [diagnostics.firstObject containsString:@"unavailable"] &&
                  field == element(view, @"name-field") && [field.accessibilityValue isEqual:@"North gate"] &&
                  [open.accessibilityValue boolValue] && window.firstResponder == save && save.enabled &&
                  [view.announcements.lastObject isEqual:@"Could not save station. Try again."] &&
                  view.announcements.count == 2 && button(view, @"Café Saved") == row,
                  @"write failure announces once and retains draft, focus and the confirmed row");
        } @finally {
            if (blocked) check([files removeItemAtPath:directory error:NULL], @"remove the test write obstruction");
            check([files moveItemAtPath:backup toPath:directory error:NULL], @"restore the isolated station store");
        }
        NSTask *fresh = [NSTask new];
        fresh.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments.firstObject];
        fresh.arguments = @[resources.path, @"--confirmed-editor"];
        check([fresh launchAndReturnError:NULL], @"relaunch the inspector after the failed write");
        [fresh waitUntilExit];
        check(fresh.terminationStatus == 0, @"a fresh process retains the previously confirmed station");
        press(window, @" ", 49);
        check(window.firstResponder == edit && button(view, @"North gate") == row &&
              diagnostics.count == 1, @"retry saves the exact draft and restores focus");
    } @finally {
        [view close];
        [window close];
    }
}

static void expectComponentFailure(NSString *message, void (^operation)(void)) {
    @try {
        operation();
    } @catch (NSException *exception) {
        check([exception.reason containsString:@"lib/RecordInspector.rb:"] &&
              [exception.reason containsString:@"RecordInspector"] &&
              [exception.reason containsString:message], exception.reason);
        return;
    }
    DesktopFailure([@"Expected component failure: " stringByAppendingString:message]);
}

static void checkSceneCompatibility(NSURL *resources) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *temp = [files.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    check([files createDirectoryAtURL:temp withIntermediateDirectories:NO attributes:nil error:NULL],
          @"create scene validation test directory");
    @try {
        NSData *original = [NSData dataWithContentsOfURL:[resources URLByAppendingPathComponent:@"scene.json"]];
        NSMutableDictionary *scene = [NSJSONSerialization JSONObjectWithData:original
            options:NSJSONReadingMutableContainers error:NULL];
        NSURL *sceneURL = [temp URLByAppendingPathComponent:@"scene.json"];
        NSArray *cases = @[
            @[@"capacity", @"wrong fingerprint", @"capacity profile mismatch"],
            @[@"version", @2, @"unsupported desktop scene version"]
        ];
        for (NSArray *entry in cases) {
            NSMutableDictionary *bad = [scene mutableCopy];
            bad[entry[0]] = entry[1];
            NSData *altered = [NSJSONSerialization dataWithJSONObject:bad options:0 error:NULL];
            check([altered writeToURL:sceneURL atomically:YES], @"write mismatched scene");
            expectComponentFailure(entry[2], ^{
                __unused DesktopProgram *program = [[DesktopProgram alloc] initWithResources:temp];
            });
        }
    } @finally {
        [files removeItemAtURL:temp error:NULL];
    }
}

static void checkFailedMount(DesktopProgram *program) {
    NSMutableDictionary *scene = [program.scene[@"components"][program.scene[@"root"]] mutableCopy];
    scene[@"getters"] = @{@"0": @"__missing_probe_getter"};
    expectComponentFailure(@"__missing_probe_getter", ^{
        __unused DesktopVM *vm = [[DesktopVM alloc] initWithScene:scene attributes:@{}];
    });
    check(mochi_component_count() == 0, @"first flush failure disposes the mounted instance");
}

static NSDictionary *probeNode(NSInteger identifier, NSString *text) {
    return @{@"id":@(identifier), @"type":text ? @"label" : @"box",
             @"nodes":text ? @[@{@"parts":@[text]}] : @[]};
}

static void checkLayoutLimits(NSURL *resources) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *scratch = [files.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    check([files copyItemAtURL:resources toURL:scratch error:nil], @"copy layout limit fixture");
    @try {
        NSURL *sceneURL = [scratch URLByAppendingPathComponent:@"scene.json"];
        NSMutableDictionary *scene = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:sceneURL]
            options:NSJSONReadingMutableContainers error:nil];
        NSMutableDictionary *root = scene[@"components"][scene[@"root"]];
        DesktopView *(^mount)(NSArray *) = ^DesktopView *(NSArray *nodes) {
            root[@"nodes"] = nodes;
            NSData *json = [NSJSONSerialization dataWithJSONObject:scene options:0 error:nil];
            check([json writeToURL:sceneURL atomically:YES], @"write layout limit fixture");
            return [[DesktopView alloc] initWithResources:scratch];
        };

        NSMutableArray *boxes = [NSMutableArray array];
        for (NSInteger i = 0; i < 507; i++) [boxes addObject:probeNode(i, nil)];
        [boxes addObject:probeNode(507, @"Exact element limit")];
        DesktopView *exact = mount(boxes);
        check(label(exact, @"Exact element limit"), @"510 elements render including the app wrapper");
        [exact close];
        [boxes addObject:probeNode(508, nil)];
        expectComponentFailure(@"510 boxes and text leaves", ^{ mount(boxes); });
        check(mochi_component_count() == 0, @"element overflow disposes the failed mount");

        NSMutableArray *text = [NSMutableArray array];
        NSString *kilobyte = [@"" stringByPaddingToLength:512 withString:@"é" startingAtIndex:0];
        for (NSInteger i = 0; i < 64; i++) [text addObject:probeNode(i, kilobyte)];
        exact = mount(text);
        check(exact.accessibilityChildren.count == 64, @"65,536 bytes of text render after an element overflow");
        [exact close];
        text[63] = probeNode(63, [kilobyte stringByAppendingString:@"x"]);
        expectComponentFailure(@"65536 bytes per frame", ^{ mount(text); });
        check(mochi_component_count() == 0, @"text overflow disposes the failed mount");
        text[63] = probeNode(63, kilobyte);
        exact = mount(text);
        check(exact.accessibilityChildren.count == 64, @"a fresh mount renders after text overflow");
        [exact close];
    } @finally {
        [files removeItemAtURL:scratch error:nil];
    }
}

static CGFloat scrollOffset(NSScrollView *scroll) { return scroll.contentView.bounds.origin.y; }

static void checkScrolling(DesktopView *view, NSWindow *window) {
    [window setContentSize:NSMakeSize(364, 540)];
    NSButton *reverse = button(view, @"Reverse");
    NSButton *details = button(view, @"Details");
    check(details.frame.origin.x > reverse.frame.origin.x, @"actions stay in a row above 315 content points");
    [window setContentSize:NSMakeSize(363, 540)];
    check(details.frame.origin.x == reverse.frame.origin.x && details.frame.origin.y > reverse.frame.origin.y,
          @"actions stack at 315 content points");

    NSScrollView *scroll = button(view, @"Harbor").enclosingScrollView;
    check([button(view, @"Show more stations") accessibilityPerformPress], @"expand station list");
    check(scroll && scroll.contentView.bounds.size.height == 200 && scrollOffset(scroll) == 0,
          @"expanded list keeps its bounded viewport");
    NSButton *last = button(view, @"Station 24");
    NSButton *clipped = button(view, @"Station 11");
    NSPoint center = NSMakePoint(NSMidX(clipped.bounds), NSMidY(clipped.bounds));
    NSPoint point = [clipped convertPoint:center toView:view];
    check(NSPointInRect(point, view.bounds) && !NSPointInRect(point, scroll.frame) &&
          [view hitTest:[view convertPoint:point toView:view.superview]] != clipped,
          @"clipped station inside the window cannot receive a pointer hit");

    [window makeFirstResponder:button(view, @"Station 23")];
    press(window, @"\t", 48);
    NSClipView *clip = scroll.contentView;
    check(window.firstResponder == last && NSContainsRect(clip.documentVisibleRect, last.frame),
          @"Tab reveals the last station");
    CGFloat offset = scrollOffset(scroll);
    check(offset == NSHeight(scroll.documentView.frame) - NSHeight(clip.bounds), @"last station reaches the end of the list");
    press(window, @" ", 49);
    check(label(view, @"Selected station 24") && scrollOffset(scroll) == offset, @"selection keeps scroll and focus");
    check([details accessibilityPerformPress] && scrollOffset(scroll) == offset && window.firstResponder == last,
          @"an unrelated component update keeps the offset");
    [window setContentSize:NSMakeSize(364, 525)];
    check(button(view, @"Station 24") == last && window.firstResponder == last &&
          scrollOffset(scroll) <= NSHeight(scroll.documentView.frame) - NSHeight(clip.bounds), @"resize preserves keyed focus and clamps offset");
    check([button(view, @"Show fewer stations") accessibilityPerformPress] && scrollOffset(scroll) == 0,
          @"shortening clamps scroll to zero");
}

static void checkPatchBatches(NSDictionary *scene) {
    static const uint8_t payload[] = {
        1, 0, 3, 0, 0, 0, 'n', 'e', 'w',
        2, 0, 2, 0, 0, 0, 0xc3, 0x28
    };
    NSMutableDictionary *prior = [@{@1: @"old"} mutableCopy];
    expectComponentFailure(@"truncated VM patch record", ^{
        DesktopApplyPatches(scene, @"select_record", prior, (MochiNativePatches){{payload, sizeof(payload) - 1}, 2});
    });
    expectComponentFailure(@"invalid UTF-8", ^{
        DesktopApplyPatches(scene, @"select_record", prior, (MochiNativePatches){{payload, sizeof(payload)}, 2});
    });
    expectComponentFailure(@"trailing bytes", ^{
        DesktopApplyPatches(scene, @"select_record", prior, (MochiNativePatches){{payload, sizeof(payload)}, 1});
    });
    check([prior isEqual:@{@1: @"old"}], @"invalid batches publish no records");
}

static void inspect(NSURL *resources, NSString *capture) {
    checkSceneCompatibility(resources);
    checkLayoutLimits(resources);
    DesktopProgram *program = [[DesktopProgram alloc] initWithResources:resources];
    check(mochi_component_count() == 0, @"program validation leaves no mounted instances");
    checkFailedMount(program);
    checkPatchBatches(program.scene[@"components"][program.scene[@"root"]]);
    DesktopView *view = [[DesktopView alloc] initWithProgram:program];
    DesktopView *other = [[DesktopView alloc] initWithProgram:program];
    check(mochi_component_count() == 8 && label(other, @"Selected station 01"), @"two independent inspector roots with three row VMs each");
    NSWindow *window = [[NSWindow alloc] initWithContentRect:view.bounds
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Mochi desktop regression";
    window.contentView = view;
    window.releasedWhenClosed = NO;
    window.autorecalculatesKeyViewLoop = NO;
    [window makeKeyAndOrderFront:nil];
    [window display];
    check(window.isVisible && label(view, @"Selected station 01"), @"initial native frame");
    NSArray *buttons = [view.accessibilityChildren filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSView *item, NSDictionary *unused) {
            return [item isKindOfClass:NSButton.class];
        }]];
    check(buttons.count == 7, @"three station buttons and four inspector actions");
    NSButton *harbor = button(view, @"Harbor");
    check([harbor.accessibilityValue boolValue], @"station 01 is initially pressed");
    NSButton *cafe = button(view, @"Café");
    click(window, cafe);
    check(label(view, @"Selected station 02") && [cafe.accessibilityValue boolValue], @"pointer selects using Ruby dataset");
    check(label(other, @"Selected station 01"), @"first selection leaves second view unchanged");
    [window makeFirstResponder:harbor];
    check([button(view, @"Reverse") accessibilityPerformPress], @"accessible press of reverse control");
    check(window.firstResponder == harbor && button(view, @"Harbor") == harbor &&
          harbor.frame.origin.y > button(view, @"West").frame.origin.y, @"keyed focus and ordering");
    check(label(view, @"Selected station 02"), @"selection survives reorder");
    [window makeFirstResponder:button(view, @"Details")];
    press(window, @" ", 49);
    check(label(view, @"Showing details for station 02") && mochi_component_count() == 9, @"Space mounts one details VM");
    NSButton *confirm = button(view, @"Confirm station");
    check([confirm accessibilityPerformPress] && label(view, @"102: Café / 1 / parent"),
          @"child routes exactly one typed event to its owning parent");
    check(label(other, @"Selected station 01"), @"child event stays scoped to the first view");
    press(window, @"\r", 36);
    check(!label(view, @"Showing details for station 02") && mochi_component_count() == 8, @"Return disposes details");
    check(![confirm accessibilityPerformPress], @"disconnected child control cannot dispatch");
    press(window, @" ", 49);
    NSButton *retainedConfirm = button(view, @"Confirm station");
    CGFloat wide = cafe.frame.size.height;
    [window setContentSize:NSMakeSize(285, 540)];
    [window display];
    check(cafe.frame.size.height > wide && cafe.frame.size.width < 285, @"native font measurement and wrapped layout");
    check(window.firstResponder == button(view, @"Details"), @"resize retains keyboard focus");
    press(window, @"\t", 48);
    check(window.firstResponder == button(view, @"Edit station"), @"Tab reaches the edit action next");
    press(window, @"\t", 48);
    check(window.firstResponder == button(view, @"West"), @"tab order follows reversed rows");
    press(window, @" ", 49);
    check(label(view, @"Showing details for station 03"), @"keyboard event resolves the moved row");
    check(retainedConfirm != confirm && mochi_component_count() == 9, @"reopening creates exactly one new child");
    check(button(view, @"Confirm station") == retainedConfirm, @"prop updates keep the mounted child control");
    if (capture) {
        NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        check([png writeToFile:capture atomically:YES], @"capture native drawing");
    }
    [window setContentSize:NSMakeSize(560, 620)];
    [window makeFirstResponder:harbor];
    press(window, @" ", 49);
    press(window, @" ", 49);
    check(harbor.isAccessibilityExpanded, @"station expands in its own VM");
    NSButton *hide = button(view, @"Hide Harbor");
    NSButton *reverse = button(view, @"Reverse");
    check([reverse accessibilityPerformPress] && window.firstResponder == harbor &&
          button(view, @"Hide Harbor") == hide, @"first move retains focus and expanded controls");
    press(window, @"\t", 48);
    check(window.firstResponder == hide, @"Tab follows the expanded station");
    press(window, @"\t", 48);
    check(window.firstResponder == cafe, @"Tab continues in the reordered list");
    [window makeFirstResponder:harbor];
    check([reverse accessibilityPerformPress] && window.firstResponder == harbor &&
          button(view, @"Hide Harbor") == hide, @"second move retains focus and expanded controls");
    press(window, @"\t", 48);
    check(window.firstResponder == hide, @"Tab reaches the moved remove control");
    press(window, @" ", 49);
    check(window.firstResponder == cafe && mochi_component_count() == 8 &&
          ![hide accessibilityPerformPress] && ![harbor accessibilityPerformPress], @"removal focuses the preceding row and releases the removed VM");
    [view close];
    check(mochi_component_count() == 4, @"closing the view unregisters its root and remaining child VMs");
    check(!cafe.superview && !cafe.enabled && !cafe.target && !cafe.action &&
          ![cafe accessibilityPerformPress], @"detached native row cannot dispatch");
    check([button(other, @"West") accessibilityPerformPress] && label(other, @"Selected station 03"),
          @"second view stays interactive after the first closes");
    [other close];
    DesktopView *replacement = [[DesktopView alloc] initWithProgram:program];
    window.contentView = replacement;
    check(mochi_component_count() == 4 && button(replacement, @"Café") != cafe &&
          ![cafe accessibilityPerformPress] && label(replacement, @"Selected station 01"),
          @"stale row cannot dispatch after remount");
    checkScrolling(replacement, window);
    [replacement close];
    check(mochi_component_count() == 0, @"remounted instance unregisters on close");
    [window close];
    check(!window.isVisible, @"native window closes");
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) return 2;
        if (!NSProcessInfo.processInfo.environment[@"MOCHI_DESKTOP_STORAGE_DIR"].length) {
            fputs("The inspector test requires an isolated MOCHI_DESKTOP_STORAGE_DIR.\n", stderr);
            return 2;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        @try {
            NSURL *resources = [NSURL fileURLWithPath:@(argv[1])];
            if (argc == 3 && [@(argv[2]) isEqual:@"--confirmed-editor"]) {
                checkEditor(resources, @"Café Saved", NO);
                puts("PASS native inspector relaunch after failed save");
                return 0;
            }
            if (argc == 3 && [@(argv[2]) isEqual:@"--reopen-editor"]) {
                checkEditor(resources, @"North gate", YES);
                puts("PASS native inspector editor relaunch");
                return 0;
            }
            inspect(resources, argc > 2 ? @(argv[2]) : nil);
            checkEditor(resources, nil, NO);
            puts("PASS native inspector: input, scroll, resize, keyed focus, layout limits, recovery and teardown");
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL %s\n", exception.reason.UTF8String);
            return 1;
        }
    }
    return 0;
}
