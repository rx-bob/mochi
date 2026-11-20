#import "../Native.h"
#import "AppKitEvents.h"

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
- (void)runStep:(NSDictionary *)step;
- (void)close;
@end

@implementation DesktopReplay {
    DesktopProgram *_program;
    DesktopView *_view;
    NSWindow *_window;
    NSString *_lastTag;
}

- (instancetype)initWithProgram:(DesktopProgram *)program {
    if ((self = [super init])) _program = program;
    return self;
}

- (void)mount:(NSString *)tag props:(NSDictionary *)props {
    if (![tag isEqual:_program.scene[@"tag"]])
        DesktopFailure([NSString stringWithFormat:@"unknown root '%@'; expected '%@'", tag, _program.scene[@"tag"]]);
    if (![props isKindOfClass:NSDictionary.class] || props.count)
        DesktopFailure(@"desktop root props are unsupported");

    _view = [[DesktopView alloc] initWithProgram:_program];
    _window = [[NSWindow alloc] initWithContentRect:_view.bounds styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    _window.releasedWhenClosed = NO;
    _window.autorecalculatesKeyViewLoop = NO;
    _window.title = tag;
    _window.contentView = _view;
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

- (id)find:(NSString *)selector {
    static NSRegularExpression *attribute;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        attribute = [NSRegularExpression regularExpressionWithPattern:
            @"\\A\\[(data-[a-z][a-z0-9-]*)(?:=(['\"])([^'\"]*)\\2)?\\]\\z" options:0 error:NULL];
    });
    NSTextCheckingResult *match = [attribute firstMatchInString:selector options:0 range:NSMakeRange(0, selector.length)];
    if (!match) DesktopFailure(@"unsupported desktop selector; use a single [data-name] or [data-name='value']");
    NSString *name = [selector substringWithRange:[match rangeAtIndex:1]];
    NSRange range = [match rangeAtIndex:3];
    NSString *value = range.location == NSNotFound ? nil : [selector substringWithRange:range];
    for (id element in _view.accessibilityChildren) {
        NSString *actual = [_view attributesForAccessibilityElement:element][name];
        if (actual && (!value || [value isEqual:actual])) return element;
    }
    DesktopFailure(@"selector matched no accessible control or text");
}

- (NSButton *)requireButton:(id)element {
    if (![element isKindOfClass:NSButton.class] || ![[element accessibilityRole] isEqual:NSAccessibilityButtonRole])
        DesktopFailure(@"selector must identify an accessible button");
    NSButton *button = element;
    if (button.window != _window || button.hidden || !button.enabled || NSIsEmptyRect(button.bounds))
        DesktopFailure(@"button must be visible and enabled");
    return button;
}

- (NSString *)attribute:(NSString *)name ofElement:(id)element {
    NSDictionary *attrs = [_view attributesForAccessibilityElement:element];
    if ([name hasPrefix:@"data-"]) return attrs[name];
    if ([element isKindOfClass:NSButton.class]) {
        if ([name isEqual:@"aria-label"]) return attrs[name] ? [element accessibilityLabel] : nil;
        if ([name isEqual:@"aria-pressed"]) {
            NSNumber *value = [element accessibilityValue];
            return value ? (value.boolValue ? @"true" : @"false") : nil;
        }
    }
    DesktopFailure([NSString stringWithFormat:@"unsupported desktop attribute '%@' on this element", name]);
}

- (void)runStep:(NSDictionary *)step {
    NSString *operation = step[@"operation"];
    if ([operation isEqual:@"mount"] || [operation isEqual:@"remount"]) {
        if (_view && [operation isEqual:@"mount"]) DesktopFailure(@"each test can mount one root component");
        NSString *tag = [step[@"tag"] isKindOfClass:NSString.class] ? step[@"tag"] : _lastTag;
        if (!tag) DesktopFailure(@"specify a component tag before mounting");
        [self close];
        [self mount:tag props:step[@"props"]];
        return;
    }
    if (![@[@"unmount", @"press", @"click", @"focus", @"assert_focused", @"assert_text", @"assert_attribute"] containsObject:operation])
        DesktopFailure(@"unsupported desktop test operation");
    if (!_view) DesktopFailure(@"mount a component before interacting with it");
    if ([operation isEqual:@"unmount"]) {
        [self close];
        return;
    }
    if ([operation isEqual:@"press"]) {
        NSString *key = step[@"key"];
        [self requireButton:_window.firstResponder];
        if ([key isEqual:@"Enter"]) press(_window, @"\r", 36);
        else if ([key isEqual:@"Space"]) press(_window, @" ", 49);
        else if ([key isEqual:@"Tab"]) press(_window, @"\t", 48);
        else DesktopFailure(@"unsupported desktop key; use Enter, Space or Tab");
    } else {
        id element = [self find:step[@"selector"]];
        if ([operation isEqual:@"click"]) {
            click(_window, [self requireButton:element]);
        } else if ([operation isEqual:@"focus"] || [operation isEqual:@"assert_focused"]) {
            NSButton *button = [self requireButton:element];
            if ([operation isEqual:@"focus"]) [_window makeFirstResponder:button];
            if (_window.firstResponder != button) DesktopFailure(@"expected the selected button to have focus");
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
        if (argc != 3) return 2;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        BOOL failed = NO;
        @try {
            NSDictionary *plan = readJSON([NSURL fileURLWithPath:@(argv[2])]);
            DesktopProgram *program = [[DesktopProgram alloc] initWithResources:[NSURL fileURLWithPath:@(argv[1])]];
            for (NSDictionary *test in plan[@"tests"]) {
                DesktopReplay *replay = [[DesktopReplay alloc] initWithProgram:program];
                NSString *origin = [NSString stringWithFormat:@"%@:%@", test[@"ruby_file"], test[@"line"]];
                NSUInteger number = 0;
                @try {
                    @try {
                        for (NSDictionary *step in test[@"steps"]) {
                            origin = stepLocation(step, ++number);
                            [replay runStep:step];
                        }
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
