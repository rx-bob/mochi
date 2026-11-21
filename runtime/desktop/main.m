#import "Native.h"

@interface DesktopApp : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic) BOOL verifyLaunch;
@end
@implementation DesktopApp
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    @try {
        DesktopView *view = [[DesktopView alloc] initWithResources:NSBundle.mainBundle.resourceURL];
        self.window = [[NSWindow alloc] initWithContentRect:view.frame
                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                            backing:NSBackingStoreBuffered defer:NO];
        self.window.title = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"];
        self.window.minSize = NSMakeSize(220, 180);
        self.window.delegate = self;
        self.window.releasedWhenClosed = NO;
        self.window.autorecalculatesKeyViewLoop = NO;
        self.window.contentView = view;
        [self.window center];
        [self.window makeKeyAndOrderFront:nil];
        if (self.verifyLaunch) {
            [self.window display];
            [NSApp terminate:nil];
            return;
        }
        [NSApp activateIgnoringOtherApps:YES];
    } @catch (NSException *e) {
        fprintf(stderr, "Mochi desktop: %s\n", e.reason.UTF8String);
        exit(1);
    }
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (void)applicationWillTerminate:(NSNotification *)n { [(DesktopView *)self.window.contentView close]; }
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (DesktopPrintToolchainInfo(argc, argv)) return 0;
        BOOL verify = argc == 2 && strcmp(argv[1], "--mochi-verify-app") == 0;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:(verify ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular)];
        NSMenu *menu = [NSMenu new];
        NSMenuItem *app = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
        app.submenu = [NSMenu new];
        [app.submenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        DesktopInstallEditMenu(menu);
        NSApp.mainMenu = menu;
        DesktopApp *delegate = [DesktopApp new];
        delegate.verifyLaunch = verify;
        NSApp.delegate = delegate;
        [NSApp run];
        (void)delegate.window;
    }
    return 0;
}
