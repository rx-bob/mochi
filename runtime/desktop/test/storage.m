#import "../Native.h"

static void check(BOOL condition, NSString *message) {
    if (!condition) DesktopFailure(message);
}

static BOOL hasText(DesktopView *view, NSString *idName, NSString *expected) {
    for (id element in view.accessibilityChildren) {
        NSDictionary *attrs = [view attributesForAccessibilityElement:element];
        if ([attrs[@"data-view"] isEqual:idName]) return [[element accessibilityValue] isEqual:expected];
    }
    return NO;
}

static NSButton *action(DesktopView *view, NSString *name) {
    for (id element in view.accessibilityChildren) {
        if ([[view attributesForAccessibilityElement:element][@"data-action"] isEqual:name]) return element;
    }
    DesktopFailure([@"missing storage action " stringByAppendingString:name]);
}

@interface StorageSubscriberProbe : DesktopVM
@property(nonatomic) NSUInteger deliveries;
@end

@implementation StorageSubscriberProbe
- (void)deliverStorage:(NSString *)callback payload:(NSDictionary *)payload {
    self.deliveries++;
    [super deliverStorage:callback payload:payload];
}
@end

static void run(NSURL *resources, NSString *phase) {
    DesktopProgram *program = [[DesktopProgram alloc] initWithResources:resources];
    NSMutableArray<NSString *> *diagnostics = [NSMutableArray array];
    DesktopView *writer = [[DesktopView alloc] initWithProgram:program attributes:@{}
                                                   diagnostics:^(NSString *error) { [diagnostics addObject:error]; }];
    if ([phase isEqual:@"seed"]) {
        check(hasText(writer, @"boot", @"Default"), @"no persisted value on first launch");
        DesktopView *reader = [[DesktopView alloc] initWithProgram:program];
        check(hasText(reader, @"receipt", @"initial ok absent absent 1"), @"second view gets one initial receipt");
        StorageSubscriberProbe *disposed = [[StorageSubscriberProbe alloc] initWithProgram:program];
        [program.storage drain];
        check(disposed.deliveries == 1, @"probe receives one initial receipt");
        [disposed close];
        [action(writer, @"save") accessibilityPerformPress];
        check(disposed.deliveries == 1, @"retained but disposed subscriber receives no mutation");
        check(hasText(writer, @"receipt", @"same_tab ok label absent 2") &&
              hasText(reader, @"receipt", @"same_tab ok label absent 2"), @"both live views receive exactly one durable receipt");
        [action(writer, @"equal") accessibilityPerformPress];
        check(hasText(reader, @"receipt", @"same_tab ok label absent 2"), @"equal writes leave subscribers unchanged");

        NSString *directory = NSProcessInfo.processInfo.environment[@"MOCHI_DESKTOP_STORAGE_DIR"];
        NSString *backup = [directory stringByAppendingString:@".held"];
        NSFileManager *files = NSFileManager.defaultManager;
        check([files moveItemAtPath:directory toPath:backup error:NULL], @"move the isolated test store");
        BOOL blocked = [files createFileAtPath:directory contents:[NSData data] attributes:nil];
        @try {
            check(blocked, @"block the test directory with a file");
            [action(writer, @"unavailable") accessibilityPerformPress];
            check(hasText(writer, @"receipt", @"same_tab unavailable label label 3") &&
                  hasText(reader, @"receipt", @"same_tab unavailable label label 3") &&
                  hasText(writer, @"mirror", @"label") && !writer.failureReason,
                  @"failed persistence preserves the durable value and keeps both views interactive");
            check(diagnostics.count == 1 && [diagnostics.firstObject containsString:@"storage storage_set: unavailable"],
                @"one source-located unavailable diagnostic");
        } @finally {
            if (blocked) check([files removeItemAtPath:directory error:NULL], @"remove the directory obstruction");
            check([files moveItemAtPath:backup toPath:directory error:NULL], @"restore the isolated test store");
        }
        [action(writer, @"raw") accessibilityPerformPress];
        check(hasText(reader, @"receipt", @"same_tab ok raw label 4") && hasText(writer, @"mirror", @"raw"),
            @"recover after unavailable and persist raw UTF-8 and control characters");
        NSButton *stale = action(reader, @"save");
        [reader close];
        check(![stale accessibilityPerformPress], @"unmount invalidates controls and subscriptions");
        [action(writer, @"abort") accessibilityPerformPress];
        check([writer.failureReason containsString:@"division by zero"], @"failed Ruby write reports the Ruby error");
        DesktopView *fresh = [[DesktopView alloc] initWithProgram:program];
        check(hasText(fresh, @"boot", @"raw") && hasText(fresh, @"receipt", @"initial ok raw absent 1"),
            @"failed Ruby entry restores the confirmed mirror before a second initialize");
        [fresh close];
    } else if ([phase isEqual:@"reopen"]) {
        check(hasText(writer, @"boot", @"raw") && hasText(writer, @"receipt", @"initial ok raw absent 1"),
            @"fresh process seeds the exact durable value before initialize");
        [action(writer, @"remove") accessibilityPerformPress];
        check(hasText(writer, @"receipt", @"same_tab ok absent raw 2") && hasText(writer, @"mirror", @"Default"),
            @"durable removal restores the default");
    } else if ([phase isEqual:@"cold-unavailable"]) {
        check(hasText(writer, @"boot", @"Default") && hasText(writer, @"receipt", @"initial unavailable absent absent 1"),
            @"unavailable startup delivers a default and failure receipt");
    } else {
        check([phase isEqual:@"absent"], @"unrecognized storage probe phase");
        check(hasText(writer, @"boot", @"Default") && hasText(writer, @"receipt", @"initial ok absent absent 1"),
            @"this app identity has no persisted value");
    }
    [writer close];
}

int main(int argc, const char **argv) {
    if (argc != 3) return 2;
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        @try {
            run([NSURL fileURLWithPath:@(argv[1])], @(argv[2]));
        } @catch (NSException *error) {
            fprintf(stderr, "FAIL native storage %s: %s\n", argv[2], error.reason.UTF8String);
            return 1;
        }
        printf("PASS native storage %s\n", argv[2]);
    }
    return 0;
}
