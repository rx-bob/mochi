#import "Native.h"
#import <CoreText/CoreText.h>

@class DesktopBox;
@interface DesktopButton : NSButton
@property(nonatomic, strong) DesktopBox *item;
@end

@implementation DesktopButton
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return self.enabled && !self.hidden; }
- (BOOL)accessibilityPerformPress {
    return self.enabled && [self sendAction:self.action to:self.target];
}
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    [super mouseDown:event];
}
- (void)keyDown:(NSEvent *)event {
    if ([event.characters isEqual:@"\r"] || [event.characters isEqual:@" "]) [self performClick:nil];
    else if (event.keyCode == 48) {
        NSView *next = (event.modifierFlags & NSEventModifierFlagShift) ? self.previousKeyView : self.nextKeyView;
        [self.window makeFirstResponder:next];
    } else [super keyDown:event];
}
- (void)drawRect:(NSRect)dirty {
    if (self.window.firstResponder == self) {
        [NSColor.keyboardFocusIndicatorColor setStroke];
        [NSBezierPath strokeRect:NSInsetRect(self.bounds, 2, 2)];
    }
}
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return [super becomeFirstResponder]; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return [super resignFirstResponder]; }
@end

@interface DesktopLabel : NSAccessibilityElement
@property(nonatomic, copy) NSDictionary *attributes;
@end
@implementation DesktopLabel
@end

@interface DesktopTypography : NSObject
@property(nonatomic, copy) NSArray *fonts;
@property(nonatomic, copy) NSArray<NSCharacterSet *> *coverage;
@property(nonatomic) CGFloat ascent, descent;
- (id)line:(NSString *)text color:(NSColor *)color;
@end

@implementation DesktopTypography
- (id)line:(NSString *)text color:(NSColor *)color {
    NSMutableAttributedString *run = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        (__bridge NSString *)kCTFontAttributeName: self.fonts.firstObject,
        (__bridge NSString *)kCTForegroundColorAttributeName: (__bridge id)color.CGColor
    }];
    if (self.fonts.count > 1) {
        [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
             options:NSStringEnumerationByComposedCharacterSequences
             usingBlock:^(NSString *cluster, NSRange range, NSRange enclosing, BOOL *stop) {
            for (NSUInteger i = 0; i < self.fonts.count; i++) {
                if ([cluster rangeOfCharacterFromSet:self.coverage[i]].location != NSNotFound) continue;
                if (i) [run addAttribute:(__bridge NSString *)kCTFontAttributeName value:self.fonts[i] range:range];
                break;
            }
        }];
    }
    return CFBridgingRelease(CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)run));
}
@end

@interface DesktopBox : NSObject
@property(nonatomic) NSRect frame;
@property(nonatomic, strong) DesktopTypography *typography;
@property(nonatomic, strong) NSColor *color, *background;
@property(nonatomic, copy) NSString *key, *label;
@property(nonatomic, copy) NSDictionary *attrs, *definition;
@property(nonatomic, copy) NSArray *rowArguments;
#ifdef MOCHI_DESKTOP_CAPTURE
@property(nonatomic, strong) NSMutableArray<NSString *> *lines;
@property(nonatomic, strong) NSMutableArray<NSArray<NSNumber *> *> *lineFrames;
@property(nonatomic, strong) NSMutableArray<NSArray<NSString *> *> *lineFaces;
#endif
@end
@implementation DesktopBox
@end

// Clay invokes the host synchronously, on the AppKit thread, during one layout.
static NSMutableArray<DesktopBox *> *frameBoxes;
static NSMutableArray *paintCommands;

static NSString *utf8(const char *bytes, int length) {
    return [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
}
void mochi_clay_fail(const char *message, int length) { DesktopFailure(utf8(message, length)); }
float mochi_clay_measure(const char *text, int length, int font) {
    DesktopBox *box = frameBoxes[font];
    id line = [box.typography line:utf8(text, length) color:box.color];
    return CTLineGetTypographicBounds((__bridge CTLineRef)line, NULL, NULL, NULL);
}
void mochi_clay_rectangle(int node, float x, float y, float width, float height) {
    DesktopBox *box = frameBoxes[node];
    box.frame = NSMakeRect(x, y, width, height);
    if (box.background) [paintCommands addObject:@{@"rect":[NSValue valueWithRect:box.frame], @"fill":box.background}];
}
void mochi_clay_line(const char *text, int length, int font, float x, float y, float height) {
    DesktopBox *box = frameBoxes[font];
    NSString *label = [utf8(text, length) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    id line = [box.typography line:label color:box.color];
    // Use a logical-pixel baseline for the CSS line box. All glyph runs,
    // including fallback runs, retain the same baseline.
    CGFloat baseline = round(y + (height + box.typography.ascent - box.typography.descent) / 2);
#ifdef MOCHI_DESKTOP_CAPTURE
    [box.lines addObject:label];
    double width = CTLineGetTypographicBounds((__bridge CTLineRef)line, NULL, NULL, NULL);
    [box.lineFrames addObject:@[@(x), @(y), @(width), @(height), @(baseline)]];
    NSMutableArray *faces = [NSMutableArray array];
    for (id glyphRun in (__bridge NSArray *)CTLineGetGlyphRuns((__bridge CTLineRef)line)) {
        NSDictionary *attributes = (__bridge NSDictionary *)CTRunGetAttributes((__bridge CTRunRef)glyphRun);
        id usedFont = attributes[(__bridge NSString *)kCTFontAttributeName];
        NSUInteger index = [box.typography.fonts indexOfObjectIdenticalTo:usedFont];
        [faces addObject:index == NSNotFound ? @"system" : @(index).stringValue];
    }
    [box.lineFaces addObject:faces];
#endif
    [paintCommands addObject:@{@"point":[NSValue valueWithPoint:NSMakePoint(x, baseline)], @"line":line}];
}

static NSColor *color(NSNumber *rgb) {
    unsigned int n = rgb.unsignedIntValue;
    return [NSColor colorWithSRGBRed:((n >> 16) & 255)/255.0 green:((n >> 8) & 255)/255.0
                                blue:(n & 255)/255.0 alpha:1];
}

static NSString *displayValue(id value) {
    if (!value || value == NSNull.null || [value isEqual:@"\uE004"]) return @"";
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return [value boolValue] ? @"true" : @"false";
    return [value description];
}

@implementation DesktopView {
    DesktopVM *_vm;
    NSDictionary *_graphicsFonts;
    NSMutableDictionary<NSArray *, DesktopTypography *> *_typography;
    NSMutableDictionary<NSString *, DesktopButton *> *_buttons;
    NSArray *_commands, *_accessibles;
    int _textUsed;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    for (id item in _accessibles) {
        if ([item isKindOfClass:NSButton.class]) { self.window.initialFirstResponder = item; break; }
    }
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isAccessibilityElement { return NO; }
- (NSArray *)accessibilityChildren { return _accessibles; }

- (instancetype)initWithResources:(NSURL *)resources {
    return [self initWithProgram:[[DesktopProgram alloc] initWithResources:resources]];
}

- (instancetype)initWithProgram:(DesktopProgram *)program {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 560, 400)])) return nil;
    _vm = [[DesktopVM alloc] initWithProgram:program];
    _buttons = [NSMutableDictionary dictionary];
    NSMutableDictionary *fonts = [NSMutableDictionary dictionary];
    for (NSString *face in _vm.scene[@"fonts"]) {
        NSURL *url = [program.resources URLByAppendingPathComponent:_vm.scene[@"fonts"][face]];
        CGDataProviderRef provider = CGDataProviderCreateWithURL((__bridge CFURLRef)url);
        if (!provider) DesktopFailure([@"Cannot read bundled font " stringByAppendingString:face]);
        CGFontRef font = CGFontCreateWithDataProvider(provider);
        CGDataProviderRelease(provider);
        if (!font) DesktopFailure([@"Cannot open bundled font " stringByAppendingString:face]);
        fonts[face] = CFBridgingRelease(font);
    }
    _graphicsFonts = [fonts copy];
    _typography = [NSMutableDictionary dictionary];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mochi_clay_init(); });
    [self refresh];
    return self;
}

- (NSDictionary *)attributesForAccessibilityElement:(id)element {
    if ([element isKindOfClass:DesktopButton.class]) return ((DesktopButton *)element).item.attrs;
    if ([element isKindOfClass:DesktopLabel.class]) return ((DesktopLabel *)element).attributes;
    return nil;
}

- (NSString *)renderParts:(NSArray *)parts slots:(NSArray *)slots {
    NSMutableString *result = [NSMutableString string];
    for (id part in parts) {
        if ([part isKindOfClass:NSString.class]) [result appendString:part];
        else if (part[@"binding"]) [result appendString:displayValue(_vm.values[part[@"binding"]])];
        else [result appendString:displayValue(slots[[part[@"slot"] unsignedIntegerValue]])];
    }
    return result;
}

- (NSDictionary *)styleFor:(NSDictionary *)node slots:(NSArray *)slots parent:(NSDictionary *)parent {
    NSMutableDictionary *style = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"face", @"size", @"weight", @"leading", @"ink"]) style[key] = parent[key];
    NSArray *rules = _vm.scene[@"styles"];
    if (node[@"style_names"]) {
        NSString *classes = [self renderParts:node[@"style_names"] slots:slots];
        NSArray *names = [classes componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        for (NSDictionary *rule in rules) {
            if ([names containsObject:rule[@"name"]]) [style addEntriesFromDictionary:rule[@"values"]];
        }
    } else {
        for (NSNumber *index in node[@"styles"])
            [style addEntriesFromDictionary:rules[index.unsignedIntegerValue][@"values"]];
    }
    return style;
}

- (DesktopTypography *)typographyFor:(NSDictionary *)style {
    NSString *family = style[@"face"] ?: @"sans-serif";
    NSNumber *weight = style[@"weight"] ?: @400;
    NSNumber *size = style[@"size"] ?: @16;
    NSArray *key = @[family, weight, size];
    DesktopTypography *cached = _typography[key];
    if (cached) return cached;

    DesktopTypography *type = [DesktopTypography new];
    NSDictionary *stack = _vm.scene[@"font_stacks"][family][weight.stringValue];
    NSMutableArray *fonts = [NSMutableArray array];
    if (stack) {
        NSMutableArray *coverage = [NSMutableArray array];
        for (NSString *face in stack[@"faces"]) {
            CGFontRef graphics = (__bridge CGFontRef)_graphicsFonts[face];
            if (!graphics) DesktopFailure([@"Missing bundled font " stringByAppendingString:face]);
            CTFontRef font = CTFontCreateWithGraphicsFont(graphics, size.doubleValue, NULL, NULL);
            NSCharacterSet *characters = CFBridgingRelease(CTFontCopyCharacterSet(font));
            [coverage addObject:characters.invertedSet];
            [fonts addObject:CFBridgingRelease(font)];
        }
        type.coverage = coverage;
        type.ascent = [stack[@"ascent"] doubleValue] * size.doubleValue;
        type.descent = [stack[@"descent"] doubleValue] * size.doubleValue;
    } else {
        if (![family isEqual:@"monospace"] && ![family isEqual:@"sans-serif"])
            DesktopFailure([NSString stringWithFormat:@"%@: unresolved font stack %@ weight %@",
                            _vm.scene[@"source"], family, weight]);
        NSFontWeight platformWeight = weight.intValue >= 600 ? NSFontWeightBold : NSFontWeightRegular;
        NSFont *font = [family isEqual:@"monospace"]
            ? [NSFont monospacedSystemFontOfSize:size.doubleValue weight:platformWeight]
            : [NSFont systemFontOfSize:size.doubleValue weight:platformWeight];
        type.ascent = font.ascender;
        type.descent = -font.descender;
        [fonts addObject:font];
    }
    type.fonts = fonts;
    _typography[key] = type;
    return type;
}

- (void)layoutNodes:(NSArray *)nodes parent:(NSDictionary *)parent stretch:(BOOL)stretch
              scope:(NSString *)scope slots:(NSArray *)slots arguments:(NSArray *)rowArgs {
    for (NSDictionary *node in nodes) {
        NSString *type = node[@"type"];
        NSString *key = [scope stringByAppendingFormat:@"/%@", node[@"id"]];
        if ([type isEqual:@"cond"]) {
            NSString *value = _vm.values[node[@"binding"]];
            NSInteger index = [value isEqual:@"true"] ? 0 : value.integerValue;
            if (([value isEqual:@"true"] || [value isEqual:@(index).stringValue]) && index >= 0 && index < (NSInteger)[node[@"branches"] count])
                [self layoutNodes:node[@"branches"][index] parent:parent stretch:stretch scope:key slots:slots arguments:rowArgs];
            continue;
        }
        if ([type isEqual:@"each"]) {
            NSString *value = _vm.values[node[@"binding"]];
            NSData *json = [value dataUsingEncoding:NSUTF8StringEncoding];
            NSError *error = nil;
            NSArray *rows = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:&error] : nil;
            if (![rows isKindOfClass:NSArray.class]) DesktopFailure(error.localizedDescription ?: @"Invalid Ruby row patch");
            NSMutableSet *keys = [NSMutableSet set];
            NSUInteger index = 0;
            for (NSArray *row in rows) {
                if (![row isKindOfClass:NSArray.class] || row.count < 4 || ![row[1] isKindOfClass:NSArray.class])
                    DesktopFailure(@"Invalid keyed row from GVM");
                NSData *encoded = [NSJSONSerialization dataWithJSONObject:@[row[3]] options:NSJSONWritingSortedKeys error:&error];
                NSString *identity = [encoded base64EncodedStringWithOptions:0];
                if ([keys containsObject:identity]) DesktopFailure([NSString stringWithFormat:@"%@: duplicate row key %@", _vm.scene[@"source"], row[3]]);
                [keys addObject:identity];
                [self layoutNodes:node[@"nodes"] parent:parent stretch:stretch
                            scope:[key stringByAppendingFormat:@":%@", identity] slots:row[1] arguments:@[row[0], @(index++)]];
            }
            continue;
        }
        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        for (NSString *name in node[@"attrs"]) attrs[name] = [self renderParts:node[@"attrs"][name] slots:slots];
        NSDictionary *style = [self styleFor:node slots:slots parent:parent];
        DesktopBox *box = [DesktopBox new];
        box.key = key;
        box.definition = node;
        box.attrs = attrs;
        box.rowArguments = rowArgs;
#ifdef MOCHI_DESKTOP_CAPTURE
        box.lines = [NSMutableArray array];
        box.lineFrames = [NSMutableArray array];
        box.lineFaces = [NSMutableArray array];
#endif
        box.color = color(style[@"ink"] ?: @0);
        if (style[@"fill"]) box.background = color(style[@"fill"]);
        int font = (int)frameBoxes.count;
        [frameBoxes addObject:box];
        int pad = [style[@"padding"] intValue];
        BOOL column = ![style[@"flex"] boolValue] || [style[@"vertical"] boolValue];
        mochi_clay_open_box(font, column, stretch, [(style[@"width"] ?: @-1) floatValue], [(style[@"height"] ?: @-1) floatValue],
                            pad, pad, pad, pad, [style[@"gap"] intValue]);
        if ([type isEqual:@"box"]) {
            [self layoutNodes:node[@"nodes"] parent:style stretch:column scope:key slots:slots arguments:rowArgs];
        } else {
            box.typography = [self typographyFor:style];
            NSMutableString *label = [NSMutableString string];
            for (NSDictionary *child in node[@"nodes"])
                [label appendString:[self renderParts:child[@"parts"] slots:slots]];
            NSArray *words = [label componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\n\r\f"]];
            box.label = [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
            NSData *text = [box.label dataUsingEncoding:NSUTF8StringEncoding];
            if (text.length > mochi_clay_string_capacity() - _textUsed) DesktopFailure(@"Clay frame exceeds its UTF-8 text capacity");
            if (text.length) {
                memcpy(mochi_clay_string_buffer() + _textUsed, text.bytes, text.length);
                mochi_clay_text_leaf(_textUsed, (int)text.length, font, [(style[@"leading"] ?: @20) intValue]);
                _textUsed += (int)text.length;
            }
        }
        mochi_clay_close_box();
    }
}

- (void)refresh {
    if (!_vm || self.failureReason || self.bounds.size.width <= 0) return;
    frameBoxes = [NSMutableArray arrayWithObject:[DesktopBox new]];
    paintCommands = [NSMutableArray array];
    @try {
        CGFloat width = self.bounds.size.width;
        mochi_clay_begin(width);
        mochi_clay_open_box(0, 1, 1, width, -1, 0, 0, 0, 0, 0);
        _textUsed = 0;
        [self layoutNodes:_vm.scene[@"nodes"] parent:@{} stretch:YES scope:@"" slots:@[] arguments:nil];
        mochi_clay_close_box();
        mochi_clay_end();
        mochi_clay_paint();
        _commands = [paintCommands copy];
        [self syncControls:frameBoxes];
#ifdef MOCHI_DESKTOP_CAPTURE
        [self observeLayout:frameBoxes];
#endif
        self.needsDisplay = YES;
    } @finally {
        frameBoxes = nil;
        paintCommands = nil;
    }
}

#ifdef MOCHI_DESKTOP_CAPTURE
- (void)observeLayout:(NSArray<DesktopBox *> *)boxes {
    NSMutableArray *controls = [NSMutableArray array];
    NSUInteger leaf = 0;
    for (DesktopBox *box in boxes) {
        id element = box.label ? _accessibles[leaf++] : nil;
        NSDictionary *attrs = box.attrs;
        NSString *key = attrs[@"data-view"];
        if (attrs[@"data-action"]) key = [@"action-" stringByAppendingString:attrs[@"data-action"]];
        if (attrs[@"data-id"]) key = [@"station-" stringByAppendingString:attrs[@"data-id"]];
        if (!key) continue;
        NSRect frame = box.frame;
        NSString *role = nil;
        NSString *name = nil;
        if (element && [element isKindOfClass:NSButton.class]) {
            frame = [element frame];
            role = [[element accessibilityRole] isEqual:NSAccessibilityButtonRole] ? @"button" : [element accessibilityRole];
            name = [element accessibilityLabel];
        } else if (element) {
            frame = [element accessibilityFrameInParentSpace];
            role = [[element accessibilityRole] isEqual:NSAccessibilityStaticTextRole] ? @"text" : [element accessibilityRole];
            name = [element accessibilityValue];
        }
        NSDictionary *control = @{
            @"id":key, @"rect":@[@(frame.origin.x), @(frame.origin.y), @(frame.size.width), @(frame.size.height)],
            @"lines":box.lines, @"role":role ?: NSNull.null, @"name":name ?: NSNull.null,
            @"pressed":attrs[@"aria-pressed"] ? [element accessibilityValue] ?: NSNull.null : NSNull.null,
            @"fill":box.background ? @[@(lround(box.background.redComponent * 255)),
                @(lround(box.background.greenComponent * 255)), @(lround(box.background.blueComponent * 255))] : NSNull.null,
            @"lineFrames":box.lineFrames, @"lineFaces":box.lineFaces,
        };
        [controls addObject:control];
    }
    _layoutObservations = [controls copy];
}
#endif

static void detachButton(DesktopButton *button) {
    button.enabled = NO;
    button.target = nil;
    button.action = NULL;
    button.item = nil;
    button.nextKeyView = nil;
    [button removeFromSuperview];
}

- (void)syncControls:(NSArray<DesktopBox *> *)boxes {
    NSMutableDictionary *retained = [NSMutableDictionary dictionary];
    NSMutableArray *accessible = [NSMutableArray array];
    NSMutableArray<NSButton *> *order = [NSMutableArray array];
    for (DesktopBox *box in boxes) {
        if (!box.label) continue;
        if ([box.definition[@"type"] isEqual:@"button"]) {
            DesktopButton *button = _buttons[box.key];
            if (!button) {
                button = [[DesktopButton alloc] initWithFrame:box.frame];
                button.bordered = NO;
                button.focusRingType = NSFocusRingTypeNone;
                button.accessibilityRole = NSAccessibilityButtonRole;
                button.target = self;
                button.action = @selector(activate:);
                [self addSubview:button];
            }
            button.title = box.label;
            button.accessibilityLabel = box.attrs[@"aria-label"] ?: box.label;
            button.accessibilityValue = box.attrs[@"aria-pressed"] ? @([box.attrs[@"aria-pressed"] isEqual:@"true"]) : nil;
            button.frame = box.frame;
            button.item = box;
            retained[box.key] = button;
            [order addObject:button];
            [accessible addObject:button];
        } else {
            DesktopLabel *label = [DesktopLabel new];
            label.accessibilityRole = NSAccessibilityStaticTextRole;
            label.accessibilityValue = box.label;
            label.accessibilityParent = self;
            label.accessibilityFrameInParentSpace = box.frame;
            label.attributes = box.attrs;
            [accessible addObject:label];
        }
    }
    for (NSString *key in _buttons) if (!retained[key]) detachButton(_buttons[key]);
    _buttons = retained;
    _accessibles = accessible;
    for (NSUInteger i = 0; i < order.count; i++) order[i].nextKeyView = order[(i+1) % order.count];
    self.window.initialFirstResponder = order.firstObject;
}

- (void)activate:(DesktopButton *)button {
    DesktopBox *box = button.item;
    if (!_vm || self.failureReason || !box || _buttons[box.key] != button) return;
    NSString *method = box.definition[@"action"];
    if (!method) return;
    NSMutableDictionary *dataset = [NSMutableDictionary dictionary];
    for (NSString *name in box.attrs) {
        if (![name hasPrefix:@"data-"]) continue;
        NSArray *parts = [[name substringFromIndex:5] componentsSeparatedByString:@"-"];
        NSMutableString *field = [parts.firstObject mutableCopy];
        for (NSUInteger i = 1; i < parts.count; i++) [field appendString:[parts[i] capitalizedString]];
        dataset[field] = box.attrs[name];
    }
    NSDictionary *payload = @{@"type":@"click", @"dataset":dataset, @"current_target_dataset":dataset};
    NSArray *args = nil;
    if ([box.definition[@"row_context"] boolValue] && box.rowArguments) args = [box.rowArguments arrayByAddingObject:payload];
    else if ([box.definition[@"event_args"] intValue]) args = @[payload];
    @try {
        [_vm activate:method arguments:args payload:payload];
        [self refresh];
    } @catch (NSException *e) {
        [self showFailure:e.reason];
    }
}

- (void)showFailure:(NSString *)reason {
    _failureReason = [reason copy];
    NSLog(@"Mochi desktop: %@", reason);
    for (NSButton *button in _buttons.allValues) button.enabled = NO;
    NSTextField *error = [NSTextField wrappingLabelWithString:reason];
    error.frame = self.bounds;
    error.drawsBackground = YES;
    error.backgroundColor = NSColor.windowBackgroundColor;
    [self addSubview:error];
}

- (void)setFrameSize:(NSSize)size {
    BOOL resized = self.frame.size.width != size.width;
    [super setFrameSize:size];
    if (resized) {
        @try { [self refresh]; }
        @catch (NSException *e) { [self showFailure:e.reason]; }
    }
}
- (void)drawRect:(NSRect)dirty {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirty);
    for (NSDictionary *command in _commands) {
        if (command[@"rect"]) {
            [command[@"fill"] setFill];
            NSRectFill([command[@"rect"] rectValue]);
        } else {
            NSPoint point = [command[@"point"] pointValue];
            CGContextRef context = NSGraphicsContext.currentContext.CGContext;
            CGContextSaveGState(context);
            CGContextTranslateCTM(context, point.x, point.y);
            CGContextScaleCTM(context, 1, -1);
            CGContextSetTextMatrix(context, CGAffineTransformIdentity);
            CGContextSetTextPosition(context, 0, 0);
            CTLineDraw((__bridge CTLineRef)command[@"line"], context);
            CGContextRestoreGState(context);
        }
    }
}
- (void)close {
    DesktopVM *vm = _vm;
    _vm = nil;
    self.window.initialFirstResponder = nil;
    for (DesktopButton *button in _buttons.allValues) detachButton(button);
    [_buttons removeAllObjects];
    _accessibles = nil;
    _commands = nil;
#ifdef MOCHI_DESKTOP_CAPTURE
    _layoutObservations = nil;
#endif
    [vm close];
}
@end
