// Integration test linked with the production desktop view and GVM. Input is
// delivered by an actual NSWindow; observations use AppKit's public controls.
#import "../Native.h"
#import "AppKitEvents.h"

extern int32_t mochi_component_count(void);

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
    DesktopProgram *program = [[DesktopProgram alloc] initWithResources:resources];
    check(mochi_component_count() == 0, @"program validation leaves no mounted instances");
    checkFailedMount(program);
    checkPatchBatches(program.scene[@"components"][program.scene[@"root"]]);
    DesktopView *view = [[DesktopView alloc] initWithProgram:program];
    DesktopView *other = [[DesktopView alloc] initWithProgram:program];
    check(mochi_component_count() == 2 && label(other, @"Selected station 01"), @"two independent mounted views");
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
    check(label(other, @"Selected station 01"), @"first selection leaves second view unchanged");
    [window makeFirstResponder:harbor];
    check([button(view, @"Reverse") accessibilityPerformPress], @"accessible press of reverse control");
    check(window.firstResponder == harbor && button(view, @"Harbor") == harbor &&
          harbor.frame.origin.y > button(view, @"West").frame.origin.y, @"keyed focus and ordering");
    check(label(view, @"Selected station 02"), @"selection survives reorder");
    [window makeFirstResponder:button(view, @"Details")];
    press(window, @" ", 49);
    check(label(view, @"Showing details for station 02") && mochi_component_count() == 3, @"Space mounts one details VM");
    NSButton *confirm = button(view, @"Confirm station");
    check([confirm accessibilityPerformPress] && label(view, @"102: Café / 1 / parent"),
          @"child routes exactly one typed event to its owning parent");
    check(label(other, @"Selected station 01"), @"child event stays scoped to the first view");
    press(window, @"\r", 36);
    check(!label(view, @"Showing details for station 02") && mochi_component_count() == 2, @"Return disposes details");
    check(![confirm accessibilityPerformPress], @"disconnected child control cannot dispatch");
    press(window, @" ", 49);
    NSButton *retainedConfirm = button(view, @"Confirm station");
    CGFloat wide = cafe.frame.size.height;
    [window setContentSize:NSMakeSize(285, 540)];
    [window display];
    check(cafe.frame.size.height > wide && cafe.frame.size.width < 285, @"native font measurement and wrapped layout");
    check(window.firstResponder == button(view, @"Details"), @"resize retains keyboard focus");
    press(window, @"\t", 48);
    check(window.firstResponder == button(view, @"West"), @"tab order follows reversed rows");
    press(window, @" ", 49);
    check(label(view, @"Showing details for station 03"), @"keyboard event resolves the moved row");
    check(retainedConfirm != confirm && mochi_component_count() == 3, @"reopening creates exactly one new child");
    check(button(view, @"Confirm station") == retainedConfirm, @"prop updates keep the mounted child control");
    if (capture) {
        NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        check([png writeToFile:capture atomically:YES], @"capture native drawing");
    }
    [view close];
    check(mochi_component_count() == 1, @"closing the view unregisters only its Ruby instance");
    check(!cafe.superview && !cafe.enabled && !cafe.target && !cafe.action &&
          ![cafe accessibilityPerformPress], @"detached native row cannot dispatch");
    check([button(other, @"West") accessibilityPerformPress] && label(other, @"Selected station 03"),
          @"second view stays interactive after the first closes");
    [other close];
    DesktopView *replacement = [[DesktopView alloc] initWithProgram:program];
    window.contentView = replacement;
    check(mochi_component_count() == 1 && button(replacement, @"Café") != cafe &&
          ![cafe accessibilityPerformPress] && label(replacement, @"Selected station 01"),
          @"stale row cannot dispatch after remount");
    [replacement close];
    check(mochi_component_count() == 0, @"remounted instance unregisters on close");
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
            puts("PASS native inspector: click, accessibility, keyed identity and focus, keyboard, resize, drawing, isolated mounts, failure recovery and teardown");
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL %s\n", exception.reason.UTF8String);
            return 1;
        }
    }
    return 0;
}
