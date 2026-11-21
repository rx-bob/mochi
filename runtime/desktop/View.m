#import "Native.h"
#import <CoreText/CoreText.h>

@class DesktopBox;
@interface DesktopButton : NSButton
@property(nonatomic, strong) DesktopBox *item;
@property(nonatomic) BOOL checkbox;
@end

@implementation DesktopButton
- (BOOL)acceptsFirstResponder { return self.enabled; }
- (id)accessibilityValue {
    return self.checkbox ? @(self.state == NSControlStateValueOn) : [super accessibilityValue];
}
- (BOOL)canBecomeKeyView { return self.enabled && !self.hidden; }
- (BOOL)accessibilityPerformPress {
    if (!self.enabled) return NO;
    if (self.checkbox) {
        [self performClick:nil];
        return YES;
    }
    return [self sendAction:self.action to:self.target];
}
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    [super mouseDown:event];
}
- (void)keyDown:(NSEvent *)event {
    if ((!self.checkbox && [event.characters isEqual:@"\r"]) || [event.characters isEqual:@" "]) [self performClick:nil];
    else if (event.keyCode == 48) {
        NSView *next = (event.modifierFlags & NSEventModifierFlagShift) ? self.previousKeyView : self.nextKeyView;
        [self.window makeFirstResponder:next];
    } else [super keyDown:event];
}
- (void)drawRect:(NSRect)dirty {
    if (self.checkbox) { [super drawRect:dirty]; return; }
    if (self.window.firstResponder == self) {
        [NSColor.keyboardFocusIndicatorColor setStroke];
        [NSBezierPath strokeRect:NSInsetRect(self.bounds, 2, 2)];
    }
}
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return [super becomeFirstResponder]; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return [super resignFirstResponder]; }
@end

@interface DesktopField : NSTextField
@property(nonatomic, strong) DesktopBox *item;
@property(nonatomic, copy) NSString *renderedValue, *committedValue;
- (void)applyValue:(NSString *)value;
@end

@implementation DesktopField
- (void)applyValue:(NSString *)value {
    if ([self.renderedValue isEqual:value]) return;
    NSTextView *editor = (NSTextView *)self.currentEditor;
    if (editor.hasMarkedText) return;
    self.renderedValue = value;
    self.committedValue = value;
    if (!editor) {
        if (![self.stringValue isEqual:value]) self.stringValue = value;
        return;
    }
    if ([editor.string isEqual:value]) return;
    NSRange selection = editor.selectedRange;
    editor.string = value;
    selection.location = MIN(selection.location, value.length);
    selection.length = MIN(selection.length, value.length - selection.location);
    editor.selectedRange = selection;
}

- (id)accessibilityValue {
    return self.currentEditor ? self.currentEditor.string : self.stringValue;
}
@end

void DesktopInstallEditMenu(NSMenu *mainMenu) {
    NSMenuItem *item = [mainMenu addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    item.submenu = edit;
    [edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [edit addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
}

@class DesktopMount;
@interface DesktopLabel : NSAccessibilityElement
@property(nonatomic, copy) NSDictionary *attributes;
@property(nonatomic, strong) DesktopMount *owner;
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

@interface DesktopMount : NSObject
@property(nonatomic, strong) DesktopVM *vm;
@property(nonatomic, weak) DesktopMount *parent;
@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) NSDictionary *connections, *attemptedAttributes;
@end
@implementation DesktopMount
@end

@interface DesktopBox : NSObject
@property(nonatomic) NSRect frame;
@property(nonatomic, strong) DesktopTypography *typography;
@property(nonatomic, strong) NSColor *color, *background;
@property(nonatomic, copy) NSString *key, *label, *formValue;
@property(nonatomic, copy) NSDictionary *attrs, *definition;
@property(nonatomic, copy) NSArray *rowArguments;
@property(nonatomic, strong) DesktopMount *owner;
#ifdef MOCHI_DESKTOP_CAPTURE
@property(nonatomic, strong) NSMutableArray<NSString *> *lines;
@property(nonatomic, strong) NSMutableArray<NSArray<NSNumber *> *> *lineFrames;
@property(nonatomic, strong) NSMutableArray<NSArray<NSString *> *> *lineFaces;
#endif
@end
@implementation DesktopBox
@end

static DesktopBox *controlBox(id control) {
    if ([control isKindOfClass:DesktopButton.class]) return ((DesktopButton *)control).item;
    if ([control isKindOfClass:DesktopField.class]) return ((DesktopField *)control).item;
    return nil;
}

@interface DesktopView () <NSTextFieldDelegate>
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
    DesktopProgram *_program;
    DesktopMount *_root;
    NSMutableDictionary<NSString *, DesktopMount *> *_children;
    NSMutableArray<NSDictionary *> *_pendingEvents;
    void (^_diagnostics)(NSString *);
    NSDictionary *_graphicsFonts;
    NSMutableDictionary<NSArray *, DesktopTypography *> *_typography;
    NSMutableDictionary<NSString *, NSControl *> *_controls;
    NSArray<NSDictionary *> *_labelTargets;
    NSArray *_commands, *_accessibles;
    int _textUsed;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    for (id item in _accessibles) {
        if ([item isKindOfClass:NSControl.class] && [item isEnabled]) { self.window.initialFirstResponder = item; break; }
    }
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isAccessibilityElement { return NO; }
- (NSArray *)accessibilityChildren { return _accessibles; }

- (instancetype)initWithResources:(NSURL *)resources {
    return [self initWithProgram:[[DesktopProgram alloc] initWithResources:resources]];
}

- (instancetype)initWithProgram:(DesktopProgram *)program {
    return [self initWithProgram:program attributes:@{} diagnostics:nil];
}

- (instancetype)initWithProgram:(DesktopProgram *)program attributes:(NSDictionary *)attributes
                    diagnostics:(void (^)(NSString *))diagnostics {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 560, 560)])) return nil;
    _program = program;
    _diagnostics = [diagnostics copy];
    _controls = [NSMutableDictionary dictionary];
    _children = [NSMutableDictionary dictionary];
    _pendingEvents = [NSMutableArray array];
    NSMutableDictionary *fonts = [NSMutableDictionary dictionary];
    for (NSString *face in program.scene[@"fonts"]) {
        NSURL *url = [program.resources URLByAppendingPathComponent:program.scene[@"fonts"][face]];
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
    _root = [DesktopMount new];
    _root.vm = [[DesktopVM alloc] initWithScene:program.scene[@"components"][program.scene[@"root"]]
                                         attributes:attributes storage:program.storage];
    _root.vm.hostView = self;
    [self enqueueEvents:_root];
    @try { [self refresh]; }
    @catch (NSException *e) {
        [self close];
        @throw;
    }
    return self;
}

- (NSDictionary *)attributesForAccessibilityElement:(id)element {
    DesktopBox *box = controlBox(element);
    if (box) return box.attrs;
    if ([element isKindOfClass:DesktopLabel.class]) return ((DesktopLabel *)element).attributes;
    return nil;
}

- (NSArray<NSDictionary *> *)componentAncestorsForAccessibilityElement:(id)element {
    DesktopMount *owner = [element isKindOfClass:DesktopLabel.class] ? ((DesktopLabel *)element).owner : controlBox(element).owner;
    NSMutableArray *ancestors = [NSMutableArray array];
    for (; owner.parent; owner = owner.parent) {
        [ancestors insertObject:@{@"tag":owner.vm.scene[@"tag"], @"attributes":owner.attemptedAttributes} atIndex:0];
    }
    return ancestors;
}

static id partValue(id part, NSArray *slots, DesktopVM *vm) {
    if ([part isKindOfClass:NSString.class]) return part;
    if (part[@"binding"]) return vm.values[part[@"binding"]];
    return slots[[part[@"slot"] unsignedIntegerValue]];
}

- (NSString *)renderParts:(NSArray *)parts slots:(NSArray *)slots vm:(DesktopVM *)vm {
    NSMutableString *result = [NSMutableString string];
    for (id part in parts) [result appendString:displayValue(partValue(part, slots, vm))];
    return result;
}

- (NSDictionary *)attributesForNode:(NSDictionary *)node slots:(NSArray *)slots vm:(DesktopVM *)vm {
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    for (NSString *name in node[@"attrs"]) {
        NSArray *parts = node[@"attrs"][name];
        NSDictionary *operand = nil;
        for (id part in parts) {
            if ([part isKindOfClass:NSString.class]) {
                if (![part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) continue;
            } else if (!operand) {
                operand = part;
                continue;
            }
            operand = nil;
            break;
        }
        if (operand) {
            id value = partValue(operand, slots, vm);
            if (!value || value == NSNull.null || [value isEqual:@"\uE004"]) continue;
        }
        NSString *value = [self renderParts:parts slots:slots vm:vm];
        if ([name isEqual:@"disabled"]) {
            BOOL dynamic = [parts indexOfObjectPassingTest:^BOOL(id part, NSUInteger idx, BOOL *stop) {
                return ![part isKindOfClass:NSString.class];
            }] != NSNotFound;
            NSString *boolean = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
            if (dynamic && (!boolean.length || [boolean isEqual:@"false"])) continue;
        }
        attributes[name] = value;
    }
    return attributes;
}

- (NSDictionary *)styleFor:(NSDictionary *)node slots:(NSArray *)slots parent:(NSDictionary *)parent vm:(DesktopVM *)vm {
    NSMutableDictionary *style = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"face", @"size", @"weight", @"leading", @"ink"]) style[key] = parent[key];
    NSArray *rules = vm.scene[@"styles"];
    if (node[@"style_names"]) {
        NSString *classes = [self renderParts:node[@"style_names"] slots:slots vm:vm];
        NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@" \t\n\r\f"];
        NSDictionary *lookup = vm.scene[@"style_lookup"];
        NSMutableIndexSet *matched = [NSMutableIndexSet indexSet];
        for (NSString *name in [classes componentsSeparatedByCharactersInSet:separators]) {
            for (NSNumber *index in lookup[name]) [matched addIndex:index.unsignedIntegerValue];
        }
        [matched enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
            [style addEntriesFromDictionary:rules[index]];
        }];
    } else {
        for (NSNumber *index in node[@"styles"])
            [style addEntriesFromDictionary:rules[index.unsignedIntegerValue]];
    }
    return style;
}

- (DesktopTypography *)typographyFor:(NSDictionary *)style scene:(NSDictionary *)scene {
    NSString *family = style[@"face"] ?: @"sans-serif";
    NSNumber *weight = style[@"weight"] ?: @400;
    NSNumber *size = style[@"size"] ?: @16;
    NSArray *key = @[scene[@"tag"], family, weight, size];
    DesktopTypography *cached = _typography[key];
    if (cached) return cached;

    DesktopTypography *type = [DesktopTypography new];
    NSDictionary *stack = scene[@"font_stacks"][family][weight.stringValue];
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
                            scene[@"source"], family, weight]);
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

- (void)reportComponentFailure:(NSString *)reason {
    NSLog(@"Mochi desktop: %@", reason);
    if (_diagnostics) _diagnostics(reason);
}

- (void)enqueueEvents:(DesktopMount *)owner {
    for (NSString *reason in [owner.vm takeHostErrors]) [self reportComponentFailure:reason];
    for (NSDictionary *event in [owner.vm takeEvents])
        [_pendingEvents addObject:@{@"owner":owner, @"event":event}];
}

- (DesktopMount *)reconcileChild:(NSDictionary *)node key:(NSString *)key owner:(DesktopMount *)owner
                     attributes:(NSDictionary *)attributes {
    DesktopMount *mount = _children[key];
    if (!mount) {
        mount = [DesktopMount new];
        mount.parent = owner;
        mount.key = key;
        mount.connections = node[@"connections"];
        _children[key] = mount;
    }
    if ([mount.attemptedAttributes isEqual:attributes]) return mount;
    mount.attemptedAttributes = attributes;
    @try {
        if (mount.vm) {
            [mount.vm updateAttributes:attributes];
        } else {
            NSDictionary *scene = _program.scene[@"components"][node[@"tag"]];
            mount.vm = [[DesktopVM alloc] initWithScene:scene attributes:attributes storage:_program.storage];
            mount.vm.hostView = self;
        }
        [self enqueueEvents:mount];
    } @catch (NSException *e) { [self reportComponentFailure:e.reason]; }
    return mount;
}

- (void)disposeChildrenExcept:(NSSet<NSString *> *)seen {
    // Drop routing before unmounting, with descendants closed first.
    NSArray *keys = [_children.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if (a.length != b.length) return a.length > b.length ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];
    for (NSString *key in keys) {
        if ([seen containsObject:key]) continue;
        DesktopMount *mount = _children[key];
        [_children removeObjectForKey:key];
        @try { [mount.vm close]; }
        @catch (NSException *e) { [self reportComponentFailure:e.reason]; }
    }
}

- (BOOL)dispatchNextChildEvent {
    while (_pendingEvents.count) {
        NSDictionary *pending = _pendingEvents.firstObject;
        [_pendingEvents removeObjectAtIndex:0];
        DesktopMount *owner = pending[@"owner"];
        if (owner != _root && _children[owner.key] != owner) continue;
        NSDictionary *event = pending[@"event"];
        NSString *name = event[@"name"];
        NSDictionary *payload = event[@"payload"];
        @try {
            DesktopValidateChildEvent(owner.vm.scene, event[@"method"], name, payload);
            NSDictionary *connection = owner.connections[name];
            if (!connection) continue;
            DesktopMount *parent = owner.parent;
            NSArray *args = [connection[@"args"] boolValue] ? @[payload] : nil;
            [parent.vm activate:connection[@"method"] arguments:args payload:payload];
            [self enqueueEvents:parent];
            // The handler may have removed the sender. Reconcile before
            // delivering another event to a possibly stale connection.
            return YES;
        } @catch (NSException *e) { [self reportComponentFailure:e.reason]; }
    }
    return NO;
}

- (void)layoutNodes:(NSArray *)nodes parent:(NSDictionary *)parent stretch:(BOOL)stretch
              scope:(NSString *)scope slots:(NSArray *)slots arguments:(NSArray *)rowArgs
              owner:(DesktopMount *)owner seen:(NSMutableSet<NSString *> *)seen {
    DesktopVM *vm = owner.vm;
    for (NSDictionary *node in nodes) {
        NSString *type = node[@"type"];
        NSString *key = [scope stringByAppendingFormat:@"/%@", node[@"id"]];
        if ([type isEqual:@"cond"]) {
            NSString *value = vm.values[node[@"binding"]];
            NSInteger index = [value isEqual:@"true"] ? 0 : value.integerValue;
            if (([value isEqual:@"true"] || [value isEqual:@(index).stringValue]) && index >= 0 && index < (NSInteger)[node[@"branches"] count])
                [self layoutNodes:node[@"branches"][index] parent:parent stretch:stretch scope:key slots:slots arguments:rowArgs owner:owner seen:seen];
            continue;
        }
        if ([type isEqual:@"each"]) {
            NSString *value = vm.values[node[@"binding"]];
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
                if ([keys containsObject:identity]) DesktopFailure([NSString stringWithFormat:@"%@: duplicate row key %@", vm.scene[@"source"], row[3]]);
                [keys addObject:identity];
                [self layoutNodes:node[@"nodes"] parent:parent stretch:stretch
                            scope:[key stringByAppendingFormat:@":%@", identity] slots:row[1] arguments:@[row[0], @(index++)] owner:owner seen:seen];
            }
            continue;
        }
        NSDictionary *attrs = [self attributesForNode:node slots:slots vm:vm];
        BOOL childNode = [type isEqual:@"child"];
        DesktopMount *child = nil;
        if (childNode) {
            [seen addObject:key];
            child = [self reconcileChild:node key:key owner:owner attributes:attrs];
        }
        NSDictionary *style = [self styleFor:node slots:slots parent:parent vm:vm];
        DesktopBox *box = [DesktopBox new];
        box.key = key;
        box.definition = node;
        box.attrs = attrs;
        box.rowArguments = rowArgs;
        box.owner = owner;
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
        BOOL column = [(style[@"vertical"] ?: @(![style[@"flex"] boolValue])) boolValue];
        float width = [(style[@"width"] ?: @-1) floatValue];
        float height = [(style[@"height"] ?: @-1) floatValue];
        NSDictionary *edit = node[@"edit"];
        if (edit) {
            box.formValue = [self renderParts:edit[@"value"] slots:slots vm:vm];
            BOOL checkbox = [edit[@"property"] isEqual:@"checked"];
            if (width < 0 && (checkbox || !stretch)) width = checkbox ? 18 : 180;
            if (height < 0) height = checkbox ? 18 : 30;
            if (!checkbox) box.typography = [self typographyFor:style scene:vm.scene];
        }
        if (width >= 0) width = MAX(width, 2 * pad);
        if (height >= 0) height = MAX(height, 2 * pad);
        mochi_clay_open_box(font, column, stretch, width, height,
                            pad, pad, pad, pad, [style[@"gap"] intValue]);
        if (childNode) {
            [self layoutNodes:child.vm.scene[@"nodes"] parent:@{} stretch:column
                        scope:key slots:@[] arguments:nil owner:child seen:seen];
        } else if ([type isEqual:@"box"]) {
            [self layoutNodes:node[@"nodes"] parent:style stretch:column scope:key slots:slots arguments:rowArgs owner:owner seen:seen];
        } else if (!edit) {
            box.typography = [self typographyFor:style scene:vm.scene];
            NSMutableString *label = [NSMutableString string];
            for (NSDictionary *child in node[@"nodes"])
                [label appendString:[self renderParts:child[@"parts"] slots:slots vm:vm]];
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

- (void)storageUpdated:(DesktopVM *)vm {
    DesktopMount *owner = _root.vm == vm ? _root : nil;
    if (!owner) {
        for (DesktopMount *child in _children.allValues) {
            if (child.vm == vm) { owner = child; break; }
        }
    }
    if (!owner) return;
    [self enqueueEvents:owner];
    [self refresh];
}

- (void)refresh {
    if (!_root || self.failureReason || self.bounds.size.width <= 0) return;
    // A cascade may mount new event sources. Bound synchronous work even
    // when an application's mounted handler keeps recreating its emitter.
    for (NSUInteger draws = 0; ; draws++) {
        [self renderFrame];
        if (!_pendingEvents.count) break;
        if (draws == 511) {
            [_pendingEvents removeAllObjects];
            [self reportComponentFailure:@"Desktop child event cascade exceeded 512 renders"];
            break;
        }
        if (![self dispatchNextChildEvent]) break;
    }
    // Storage callbacks can add/remove components or redraw a different
    // window. Drain only after Clay releases its global frame scratch.
    [_program.storage drain];
}

- (void)renderFrame {
    frameBoxes = [NSMutableArray arrayWithObject:[DesktopBox new]];
    paintCommands = [NSMutableArray array];
    @try {
        CGFloat width = self.bounds.size.width;
        mochi_clay_begin(width);
        NSDictionary *window = _program.scene[@"window"];
        int inset = [window[@"inset"] intValue];
        CGFloat available = MAX(0, width - 2 * inset);
        NSNumber *cap = window[@"max_width"];
        CGFloat content = [cap isKindOfClass:NSNumber.class] ? MIN(available, cap.doubleValue) : available;
        mochi_clay_open_box(0, 1, 1, content + 2 * inset, -1, inset, inset, inset, inset, 0);
        _textUsed = 0;
        NSMutableSet *seen = [NSMutableSet set];
        [self layoutNodes:_root.vm.scene[@"nodes"] parent:@{} stretch:YES scope:@"" slots:@[] arguments:nil owner:_root seen:seen];
        mochi_clay_close_box();
        mochi_clay_end();
        mochi_clay_paint();
        [self disposeChildrenExcept:seen];
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
        id element = (box.label || box.formValue) ? _accessibles[leaf++] : nil;
        NSDictionary *attrs = box.attrs;
        NSString *key = attrs[@"data-view"];
        if (attrs[@"data-action"]) key = [@"action-" stringByAppendingString:attrs[@"data-action"]];
        if (attrs[@"data-id"]) key = [@"station-" stringByAppendingString:attrs[@"data-id"]];
        if (!key) continue;
        NSRect frame = box.frame;
        NSString *role = nil;
        NSString *name = nil;
        if ([element isKindOfClass:NSControl.class]) {
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
            @"ink":@[@(lround(box.color.redComponent * 255)),
                @(lround(box.color.greenComponent * 255)), @(lround(box.color.blueComponent * 255))],
            @"fill":box.background ? @[@(lround(box.background.redComponent * 255)),
                @(lround(box.background.greenComponent * 255)), @(lround(box.background.blueComponent * 255))] : NSNull.null,
            @"lineFrames":box.lineFrames, @"lineFaces":box.lineFaces,
        };
        [controls addObject:control];
    }
    _layoutObservations = [controls copy];
}
#endif

static void detachControl(NSControl *control) {
    control.enabled = NO;
    control.target = nil;
    control.action = NULL;
    if ([control isKindOfClass:DesktopField.class]) {
        DesktopField *field = (DesktopField *)control;
        field.delegate = nil;
        [field abortEditing];
        field.item = nil;
    } else {
        ((DesktopButton *)control).item = nil;
    }
    control.nextKeyView = nil;
    [control removeFromSuperview];
}

static NSArray *labelKey(DesktopBox *box, NSString *identifier) {
    return @[box.owner.key ?: @"", identifier];
}

- (NSControl *)controlForBox:(DesktopBox *)box title:(NSString *)title {
    NSDictionary *edit = box.definition[@"edit"];
    BOOL checkbox = [edit[@"property"] isEqual:@"checked"];
    NSControl *control = _controls[box.key];
    if (box.formValue && !checkbox) {
        DesktopField *field = (DesktopField *)control;
        if (!field) {
            field = [[DesktopField alloc] initWithFrame:box.frame];
            field.editable = YES;
            field.selectable = YES;
            field.bordered = YES;
            field.bezelStyle = NSTextFieldSquareBezel;
            field.usesSingleLineMode = YES;
            field.accessibilityRole = NSAccessibilityTextFieldRole;
            field.delegate = self;
            [self addSubview:field];
        }
        field.item = box;
        NSFont *font = box.typography.fonts.firstObject;
        if (![field.font isEqual:font]) field.font = font;
        if (![field.textColor isEqual:box.color]) field.textColor = box.color;
        [field applyValue:box.formValue];
        field.accessibilityLabel = title;
        control = field;
    } else {
        DesktopButton *button = (DesktopButton *)control;
        if (!button) {
            button = [[DesktopButton alloc] initWithFrame:box.frame];
            button.checkbox = checkbox;
            if (checkbox) {
                [button setButtonType:NSButtonTypeSwitch];
                button.accessibilityRole = NSAccessibilityCheckBoxRole;
            }
            else {
                button.bordered = NO;
                button.focusRingType = NSFocusRingTypeNone;
                button.accessibilityRole = NSAccessibilityButtonRole;
            }
            button.target = self;
            button.action = @selector(activate:);
            [self addSubview:button];
        }
        button.item = box;
        button.title = box.label ?: @"";
        button.accessibilityLabel = title;
        if (checkbox) {
            BOOL checked = [@[@"true", @"checked", @"1"] containsObject:box.formValue];
            NSControlStateValue state = checked ? NSControlStateValueOn : NSControlStateValueOff;
            if (button.state != state) button.state = state;
        } else {
            button.accessibilityValue = box.attrs[@"aria-pressed"] ? @([box.attrs[@"aria-pressed"] isEqual:@"true"]) : nil;
        }
        control = button;
    }
    BOOL enabled = !box.attrs[@"disabled"];
    if (control.enabled != enabled) {
        control.enabled = enabled;
        if (!enabled && [control isKindOfClass:DesktopField.class]) [control abortEditing];
    }
    if (!NSEqualRects(control.frame, box.frame)) control.frame = box.frame;
    return control;
}

- (void)syncControls:(NSArray<DesktopBox *> *)boxes {
    NSMutableDictionary *retained = [NSMutableDictionary dictionary];
    NSMutableDictionary *labels = [NSMutableDictionary dictionary];
    NSMutableArray *targets = [NSMutableArray array];
    NSMutableArray *accessible = [NSMutableArray array];
    NSMutableArray<NSControl *> *order = [NSMutableArray array];
    for (DesktopBox *box in boxes) {
        NSString *identifier = box.attrs[@"for"];
        if (!identifier) continue;
        NSArray *key = labelKey(box, identifier);
        NSMutableArray *associated = labels[key];
        if (!associated) labels[key] = associated = [NSMutableArray array];
        [associated addObject:box];
    }
    for (DesktopBox *box in boxes) {
        if (box.formValue || [box.definition[@"type"] isEqual:@"button"]) {
            NSArray<DesktopBox *> *associated = box.attrs[@"id"] ? labels[labelKey(box, box.attrs[@"id"])] : nil;
            NSString *name = box.attrs[@"aria-label"];
            if (!name.length) name = [[associated valueForKey:@"label"] componentsJoinedByString:@" "] ?: box.label;
            NSControl *control = [self controlForBox:box title:name];
            retained[box.key] = control;
            if (control.enabled) [order addObject:control];
            else control.nextKeyView = nil;
            [accessible addObject:control];
            for (DesktopBox *label in associated)
                [targets addObject:@{@"frame":[NSValue valueWithRect:label.frame], @"control":control}];
        } else if (box.label) {
            DesktopLabel *label = [DesktopLabel new];
            label.accessibilityRole = NSAccessibilityStaticTextRole;
            label.accessibilityValue = box.label;
            label.accessibilityParent = self;
            label.accessibilityFrameInParentSpace = box.frame;
            label.attributes = box.attrs;
            label.owner = box.owner;
            [accessible addObject:label];
        }
    }
    for (NSString *key in _controls) if (!retained[key]) detachControl(_controls[key]);
    _controls = retained;
    _labelTargets = [targets copy];
    _accessibles = accessible;
    for (NSUInteger i = 0; i < order.count; i++) order[i].nextKeyView = order[(i+1) % order.count];
    self.window.initialFirstResponder = order.firstObject;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    for (NSDictionary *label in _labelTargets) {
        if (!NSPointInRect(point, [label[@"frame"] rectValue])) continue;
        NSControl *control = label[@"control"];
        if (!control.enabled) return;
        [self.window makeFirstResponder:control];
        if ([control isKindOfClass:DesktopButton.class]) [(NSButton *)control performClick:nil];
        return;
    }
    [super mouseDown:event];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    DesktopField *field = notification.object;
    NSTextView *editor = (NSTextView *)field.currentEditor;
    if (!field.enabled || !editor || editor.hasMarkedText || [field.committedValue isEqual:editor.string]) return;
    field.committedValue = editor.string;
    [self dispatchControl:field type:@"input" value:field.committedValue checked:NO];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)editor doCommandBySelector:(SEL)command {
    if (command == @selector(insertTab:) || command == @selector(insertBacktab:)) {
        NSView *next = command == @selector(insertTab:) ? control.nextKeyView : control.previousKeyView;
        return [self.window makeFirstResponder:next];
    }
    return NO;
}

- (void)activate:(DesktopButton *)button {
    [self dispatchControl:button type:button.checkbox ? @"change" : @"click"
                    value:button.checkbox ? @"on" : nil checked:button.checkbox && button.state == NSControlStateValueOn];
}

- (void)dispatchControl:(NSControl *)control type:(NSString *)eventType value:(NSString *)value checked:(BOOL)checked {
    DesktopBox *box = controlBox(control);
    if (!_root || self.failureReason || !box || !control.enabled || _controls[box.key] != control) return;
    NSDictionary *edit = box.definition[@"edit"];
    NSString *method = edit ? edit[@"method"] : box.definition[@"action"];
    if (!method) return;
    NSMutableDictionary *dataset = [NSMutableDictionary dictionary];
    for (NSString *name in box.attrs) {
        if (![name hasPrefix:@"data-"]) continue;
        NSArray *parts = [[name substringFromIndex:5] componentsSeparatedByString:@"-"];
        NSMutableString *field = [parts.firstObject mutableCopy];
        for (NSUInteger i = 1; i < parts.count; i++) [field appendString:[parts[i] capitalizedString]];
        dataset[field] = box.attrs[name];
    }
    NSMutableDictionary *payload = [@{@"type":eventType, @"dataset":dataset, @"target_dataset":dataset,
        @"current_target_dataset":dataset} mutableCopy];
    if (edit) {
        [payload addEntriesFromDictionary:@{@"value":value, @"checked":@(checked), @"target_tag":@"input",
            @"current_target_tag":@"input", @"target_id":box.attrs[@"id"] ?: @"", @"current_target_id":box.attrs[@"id"] ?: @""}];
    }
    NSDictionary *entry = edit ?: box.definition;
    NSArray *args = nil;
    if ([entry[@"row_context"] boolValue] && box.rowArguments) args = [box.rowArguments arrayByAddingObject:payload];
    else if (edit || [entry[@"event_args"] intValue]) args = @[payload];
    @try {
        [box.owner.vm activate:method arguments:args payload:payload];
        [self enqueueEvents:box.owner];
    } @catch (NSException *e) {
        if (box.owner == _root) [self showFailure:e.reason];
        else [self reportComponentFailure:e.reason];
        return;
    }
    @try { [self refresh]; }
    @catch (NSException *e) { [self showFailure:e.reason]; }
}

- (void)showFailure:(NSString *)reason {
    _failureReason = [reason copy];
    NSLog(@"Mochi desktop: %@", reason);
    for (NSControl *control in _controls.allValues) control.enabled = NO;
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
// Snap each edge independently using the actual drawing target's transform.
static NSRect deviceAlignedRect(CGContextRef context, NSRect rect) {
    CGRect pixels = CGContextConvertRectToDeviceSpace(context, rect);
    CGFloat left = floor(CGRectGetMinX(pixels) + 0.5), right = floor(CGRectGetMaxX(pixels) + 0.5);
    CGFloat top = floor(CGRectGetMinY(pixels) + 0.5), bottom = floor(CGRectGetMaxY(pixels) + 0.5);
    return CGContextConvertRectToUserSpace(context, CGRectMake(left, top, right - left, bottom - top));
}

- (void)drawRect:(NSRect)dirty {
    [(_program.scene[@"window"] ? NSColor.whiteColor : NSColor.windowBackgroundColor) setFill];
    NSRectFill(dirty);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    for (NSDictionary *command in _commands) {
        if (command[@"rect"]) {
            [command[@"fill"] setFill];
            NSRectFill(deviceAlignedRect(context, [command[@"rect"] rectValue]));
        } else {
            NSPoint point = [command[@"point"] pointValue];
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
    DesktopVM *vm = _root.vm;
    _root = nil;
    [_pendingEvents removeAllObjects];
    self.window.initialFirstResponder = nil;
    for (NSControl *control in _controls.allValues) detachControl(control);
    _labelTargets = nil;
    [_controls removeAllObjects];
    _accessibles = nil;
    _commands = nil;
#ifdef MOCHI_DESKTOP_CAPTURE
    _layoutObservations = nil;
#endif
    [self disposeChildrenExcept:nil];
    @try { [vm close]; }
    @finally { [_program.storage drain]; }
}
@end
