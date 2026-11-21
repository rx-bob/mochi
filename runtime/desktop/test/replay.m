#import "../Native.h"
#import "AppKitEvents.h"
#ifdef MOCHI_DESKTOP_CAPTURE
#import "InspectorCapture.h"
#endif

static id readJSON(NSURL *url) {
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    if (!data) DesktopFailure(error.localizedDescription);
    id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (!result) DesktopFailure(error.localizedDescription);
    return result;
}

static NSString *stepLocation(NSDictionary *step, NSUInteger number) {
    NSString *subject = step[@"selector"] ?: step[@"key"];
    if (!subject && [step[@"tag"] isKindOfClass:NSString.class]) subject = step[@"tag"];
    NSString *location = [NSString stringWithFormat:@"%@:%@ (step %lu %@",
        step[@"ruby_file"], step[@"line"], (unsigned long)number, step[@"operation"]];
    return subject ? [location stringByAppendingFormat:@" %@)", subject] : [location stringByAppendingString:@")"];
}

@interface DesktopReplay : NSObject
- (instancetype)initWithProgram:(DesktopProgram *)program;
- (void)runRecordedStep:(NSDictionary *)step;
- (void)finish;
- (void)close;
#ifdef MOCHI_DESKTOP_CAPTURE
@property(nonatomic) NSInteger captureWidth, captureScale;
@property(nonatomic, copy) NSString *captureDirectory;
#endif
@end

@implementation DesktopReplay {
    DesktopProgram *_program;
    DesktopView *_view;
    NSWindow *_window;
    NSString *_lastTag;
    NSString *_expectedError;
    NSMutableArray<NSString *> *_diagnostics;
}

- (instancetype)initWithProgram:(DesktopProgram *)program {
    if ((self = [super init])) {
        _program = program;
        _diagnostics = [NSMutableArray array];
    }
    return self;
}

- (void)mount:(NSString *)tag props:(NSDictionary *)props {
    if (![tag isEqual:_program.scene[@"root"]])
        DesktopFailure([NSString stringWithFormat:@"unknown root '%@'; expected '%@'", tag, _program.scene[@"root"]]);
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    for (NSString *name in props) {
        id value = props[name];
        if (value == NSNull.null) continue;
        if ([value isKindOfClass:NSString.class]) attributes[name] = value;
        else {
            NSData *json = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:NULL];
            if (!json) DesktopFailure(@"invalid component input attribute");
            attributes[name] = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        }
    }

    NSMutableArray *diagnostics = _diagnostics;
    _view = [[DesktopView alloc] initWithProgram:_program attributes:attributes
                                    diagnostics:^(NSString *reason) { [diagnostics addObject:reason]; }];
    _window = [[NSWindow alloc] initWithContentRect:_view.bounds styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    _window.releasedWhenClosed = NO;
    _window.autorecalculatesKeyViewLoop = NO;
    _window.title = tag;
    _window.contentView = _view;
#ifdef MOCHI_DESKTOP_CAPTURE
    if (self.captureDirectory) {
        _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        [_window setContentSize:NSMakeSize(self.captureWidth, 780)];
    }
#endif
    [_window makeKeyAndOrderFront:nil];
    [_window display];
    _lastTag = tag;
}

- (void)close {
    @try { [_view close]; }
    @finally {
        [_window close];
        _view = nil;
        _window = nil;
    }
}

static BOOL matchesSelector(NSString *selector, NSString *tag, NSDictionary *attributes) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:
            @"\\A\\[(data-[a-z][a-z0-9-]*)(?:=(['\\x22])([^'\\x22]*)\\2)?\\]\\z" options:0 error:NULL];
    });
    if (tag && [selector isEqual:tag]) return YES;
    NSTextCheckingResult *match = [pattern firstMatchInString:selector options:0 range:NSMakeRange(0, selector.length)];
    if (!match) {
        if (tag && [selector rangeOfString:@"\\A[a-z][a-z0-9-]*-[a-z0-9-]+\\z"
                              options:NSRegularExpressionSearch].location != NSNotFound) return NO;
        DesktopFailure(@"unsupported desktop selector; use a single [data-name] or [data-name='value']");
    }
    NSString *name = [selector substringWithRange:[match rangeAtIndex:1]];
    NSRange range = [match rangeAtIndex:3];
    NSString *value = range.location == NSNotFound ? nil : [selector substringWithRange:range];
    return attributes[name] && (!value || [attributes[name] isEqual:value]);
}

- (id)find:(NSString *)selector {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [selector componentsSeparatedByString:@">>>"])
        [parts addObject:[part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    // Validate the leaf selector even if the current screen has no matching scope.
    matchesSelector(parts.lastObject, nil, @{});
    for (id element in _view.accessibilityChildren) {
        NSDictionary *attrs = [_view attributesForAccessibilityElement:element];
        if (!matchesSelector(parts.lastObject, nil, attrs)) continue;
        NSArray *ancestors = [_view componentAncestorsForAccessibilityElement:element];
        if (ancestors.count + 1 != parts.count) continue;
        BOOL matches = YES;
        for (NSUInteger i = 0; i < ancestors.count; i++) {
            NSDictionary *ancestor = ancestors[i];
            if (!matchesSelector(parts[i], ancestor[@"tag"], ancestor[@"attributes"])) {
                matches = NO;
                break;
            }
        }
        if (matches) return element;
    }
    DesktopFailure(@"selector matched no accessible control or text");
}

- (NSButton *)requireButton:(id)element {
    if (![element isKindOfClass:NSButton.class])
        DesktopFailure(@"selector must identify an accessible button");
    NSButton *button = element;
    if (button.window != _window || button.hidden || NSIsEmptyRect(button.visibleRect))
        DesktopFailure(@"button must be visible");
    return button;
}

- (NSString *)attribute:(NSString *)name ofElement:(id)element {
    NSDictionary *attrs = [_view attributesForAccessibilityElement:element];
    if ([name hasPrefix:@"data-"]) return attrs[name];
    if ([element isKindOfClass:NSButton.class]) {
        if ([name isEqual:@"aria-label"]) return attrs[name] ? [element accessibilityLabel] : nil;
        if ([name isEqual:@"aria-pressed"] || [name isEqual:@"aria-expanded"]) {
            if (!attrs[name]) return nil;
            NSNumber *value = [name isEqual:@"aria-expanded"] ? @([element isAccessibilityExpanded]) :
                [element accessibilityValue];
            return value ? (value.boolValue ? @"true" : @"false") : nil;
        }
    }
    DesktopFailure([NSString stringWithFormat:@"unsupported desktop attribute '%@' on this element", name]);
}

- (void)runRecordedStep:(NSDictionary *)step {
    if ([step[@"operation"] isEqual:@"expect_error"]) {
        if (_expectedError) DesktopFailure(@"expect_error must be followed by an action");
        _expectedError = step[@"message"];
        return;
    }
    @try { [self runStep:step]; }
    @catch (NSException *error) {
        // Root mount diagnostics are thrown before an application view exists.
        if (!_expectedError || ![step[@"operation"] isEqual:@"mount"] ||
            ![error.reason containsString:_expectedError]) @throw;
        [_diagnostics addObject:error.reason];
    }
    for (NSString *reason in _diagnostics) {
        if (!_expectedError || ![reason containsString:_expectedError]) DesktopFailure(reason);
    }
    if (_expectedError && !_diagnostics.count)
        DesktopFailure([NSString stringWithFormat:@"expected desktop error containing '%@', but no error occurred", _expectedError]);
    [_diagnostics removeAllObjects];
    _expectedError = nil;
}

- (void)finish {
    if (_expectedError) DesktopFailure(@"expect_error must be followed by an action");
}

- (void)runStep:(NSDictionary *)step {
    NSString *operation = step[@"operation"];
    if ([operation isEqual:@"wait"]) return;
    if ([operation isEqual:@"wait_for"]) {
        if (!_view) DesktopFailure(@"mount a component before waiting for a control");
        [self find:step[@"selector"]];
        return;
    }
    if ([operation isEqual:@"checkpoint"]) {
#ifdef MOCHI_DESKTOP_CAPTURE
        if (self.captureDirectory) {
            if (!_view) DesktopFailure(@"mount a component before capturing a checkpoint");
            captureInspector(_view, self.captureDirectory, self.captureWidth, self.captureScale, step[@"name"]);
        }
#endif
        return;
    }
    if ([operation isEqual:@"mount"] || [operation isEqual:@"remount"]) {
        if (_view && [operation isEqual:@"mount"]) DesktopFailure(@"each test can mount one root component");
        NSString *tag = [step[@"tag"] isKindOfClass:NSString.class] ? step[@"tag"] : _lastTag;
        if (!tag) DesktopFailure(@"specify a component tag before mounting");
        [self close];
        [self mount:tag props:step[@"props"]];
        return;
    }
    if (![@[@"unmount", @"press", @"click", @"focus", @"assert_focused", @"assert_text", @"assert_attribute", @"fill", @"assert_value"] containsObject:operation])
        DesktopFailure(@"unsupported desktop test operation");
    if (!_view) DesktopFailure(@"mount a component before interacting with it");
    if ([operation isEqual:@"unmount"]) {
        [self close];
        return;
    }
    if ([operation isEqual:@"press"]) {
        NSString *key = step[@"key"];
        if (![_window.firstResponder isKindOfClass:NSTextView.class]) [self requireButton:_window.firstResponder];
        if ([key isEqual:@"Enter"]) press(_window, @"\r", 36);
        else if ([key isEqual:@"Space"]) press(_window, @" ", 49);
        else if ([key isEqual:@"Tab"]) press(_window, @"\t", 48);
        else DesktopFailure(@"unsupported desktop key; use Enter, Space or Tab");
    } else {
        id element = [self find:step[@"selector"]];
        if ([operation isEqual:@"click"]) {
            if ([element isKindOfClass:NSTextField.class]) click(_window, element);
            else click(_window, [self requireButton:element]);
        } else if ([operation isEqual:@"focus"] || [operation isEqual:@"assert_focused"]) {
            NSControl *control = [element isKindOfClass:NSTextField.class] ? element : [self requireButton:element];
            if ([operation isEqual:@"focus"]) [_window makeFirstResponder:control];
            id focused = control.currentEditor ?: control;
            if (_window.firstResponder != focused) DesktopFailure(@"expected the selected control to have focus");
        } else if ([operation isEqual:@"fill"] || [operation isEqual:@"assert_value"]) {
            if (![element isKindOfClass:NSTextField.class]) DesktopFailure(@"selector must identify an accessible text field");
            NSTextField *field = element;
            if ([operation isEqual:@"fill"]) {
                if (!field.enabled || ![_window makeFirstResponder:field]) DesktopFailure(@"text field must be enabled");
                NSTextView *editor = (NSTextView *)field.currentEditor;
                [editor insertText:step[@"value"] replacementRange:NSMakeRange(0, editor.string.length)];
            } else if (![[field accessibilityValue] isEqual:step[@"expected"]]) {
                DesktopFailure([NSString stringWithFormat:@"expected value '%@', got '%@'", step[@"expected"], field.accessibilityValue]);
            }
        } else {
            NSString *actual = [operation isEqual:@"assert_text"]
                ? ([element isKindOfClass:NSButton.class] ? [element title] : [element accessibilityValue])
                : [self attribute:step[@"name"] ofElement:element];
            if (![actual isEqual:step[@"expected"]]) {
                NSString *subject = [operation isEqual:@"assert_text"] ? @"text" :
                    [NSString stringWithFormat:@"attribute '%@'", step[@"name"]];
                DesktopFailure([NSString stringWithFormat:@"expected %@ '%@', got %@",
                    subject, step[@"expected"], actual ? [NSString stringWithFormat:@"'%@'", actual] : @"absent"]);
            }
        }
    }
    if (_view.failureReason) DesktopFailure(_view.failureReason);
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (DesktopPrintToolchainInfo(argc, argv)) return 0;
#ifdef MOCHI_DESKTOP_CAPTURE
        if (argc != 3 && argc != 6) return 2;
#else
        if (argc != 3) return 2;
#endif
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        BOOL failed = NO;
        @try {
            NSDictionary *plan = readJSON([NSURL fileURLWithPath:@(argv[2])]);
            DesktopProgram *program = [[DesktopProgram alloc] initWithResources:[NSURL fileURLWithPath:@(argv[1])]];
            for (NSDictionary *test in plan[@"tests"]) {
                DesktopReplay *replay = [[DesktopReplay alloc] initWithProgram:program];
#ifdef MOCHI_DESKTOP_CAPTURE
                if (argc == 6) {
                    replay.captureDirectory = @(argv[3]);
                    replay.captureWidth = [@(argv[4]) integerValue];
                    replay.captureScale = [@(argv[5]) integerValue];
                    if (replay.captureWidth <= 0 || (replay.captureScale != 1 && replay.captureScale != 2)) return 2;
                }
#endif
                NSString *origin = [NSString stringWithFormat:@"%@:%@", test[@"ruby_file"], test[@"line"]];
                NSUInteger number = 0;
                @try {
                    @try {
                        for (NSDictionary *step in test[@"steps"]) {
                            origin = stepLocation(step, ++number);
                            [replay runRecordedStep:step];
                        }
                        [replay finish];
                    } @finally { [replay close]; }
                    printf("PASS [desktop] %s\n", [test[@"name"] UTF8String]);
                } @catch (NSException *exception) {
                    fprintf(stderr, "FAIL [desktop] %s: %s: %s\n",
                        [test[@"name"] UTF8String], origin.UTF8String, exception.reason.UTF8String);
                    failed = YES;
                }
            }
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL [desktop] %s\n", exception.reason.UTF8String);
            return 1;
        }
        return failed ? 1 : 0;
    }
}
