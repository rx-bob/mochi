#import "Native.h"
#import <CommonCrypto/CommonDigest.h>

void DesktopFailure(NSString *reason) {
    @throw [NSException exceptionWithName:@"MochiDesktopError" reason:reason userInfo:nil];
}

BOOL DesktopPrintToolchainInfo(int argc, const char **argv) {
    if (argc != 2 || strcmp(argv[1], "--mochi-toolchain-info") != 0) return NO;
#if defined(__arm64__)
    NSString *architecture = @"arm64";
#elif defined(__x86_64__)
    NSString *architecture = @"x86_64";
#else
#error "Mochi desktop has no toolchain definition for this CPU"
#endif
    NSData *info = [NSJSONSerialization dataWithJSONObject:@{
        @"platform":@"macos", @"target":@"desktop", @"architecture":architecture,
        @"scene_schema":@(MOCHI_DESKTOP_SCENE_SCHEMA), @"native_abi":@(mochi_native_abi_version()),
        @"capacity_fingerprint":@(mochi_native_capacity_fingerprint())
    } options:0 error:NULL];
    fwrite(info.bytes, 1, info.length, stdout);
    putchar('\n');
    return YES;
}

static MochiNativeBytes bytes(NSData *data) {
    return (MochiNativeBytes){data.bytes, data.length};
}

static void failIn(NSDictionary *scene, NSString *method, NSString *detail) {
    NSNumber *line = scene[@"methods"][method];
    DesktopFailure([NSString stringWithFormat:@"%@:%@ (%@, %@): %@", scene[@"source"] ?: @"scene.json",
                    line ?: @1, scene[@"class"] ?: @"unknown component", method, detail]);
}

static void vmFailure(NSDictionary *scene, NSString *method) {
    MochiNativeBytes error = mochi_native_error();
    NSString *detail = [[NSString alloc] initWithBytes:error.data length:error.length encoding:NSUTF8StringEncoding];
    failIn(scene, method, detail.length ? detail : @"VM operation failed");
}

NSDictionary<NSNumber *, NSString *> *DesktopApplyPatches(
    NSDictionary *scene, NSString *method, NSDictionary<NSNumber *, NSString *> *current,
    MochiNativePatches patches) {
    NSMutableDictionary *pending = [current mutableCopy];
    MochiNativeBytes remaining = patches.bytes;
    for (size_t i = 0; i < patches.count; i++) {
        uint16_t key;
        MochiNativeBytes value;
        if (mochi_native_patch_next(&remaining, &key, &value) != 1)
            failIn(scene, method, @"truncated VM patch record");
        NSString *text = [[NSString alloc] initWithBytes:value.data length:value.length encoding:NSUTF8StringEncoding];
        if (!text) failIn(scene, method, @"invalid UTF-8 in VM patch record");
        pending[@(key)] = text;
    }
    if (remaining.length) failIn(scene, method, @"trailing bytes in VM patch batch");
    return [pending copy];
}

static NSArray<NSDictionary *> *takeEffects(NSDictionary *scene, NSString *method) {
    MochiNativeBytes pending = mochi_native_take_effects();
    if (!pending.length) return @[];
    NSString *wire = [[NSString alloc] initWithBytes:pending.data length:pending.length encoding:NSUTF8StringEncoding];
    if (!wire) failIn(scene, method, @"invalid UTF-8 in native effect batch");
    NSMutableArray *effects = [NSMutableArray array];
    for (NSString *line in [wire componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        // Storage's shared wire already escapes LF, CR and TAB. Escape its
        // remaining raw control bytes for native JSON without changing WASM.
        NSMutableString *json = [line mutableCopy];
        for (NSUInteger i = line.length; i > 0; i--) {
            unichar c = [line characterAtIndex:i - 1];
            if (c < 32) [json replaceCharactersInRange:NSMakeRange(i - 1, 1) withString:[NSString stringWithFormat:@"\\u%04x", c]];
        }
        id entry = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if (![entry isKindOfClass:NSDictionary.class]) failIn(scene, method, @"invalid native effect record");
        [effects addObject:entry];
    }
    return effects;
}

static NSURL *storageDirectory(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"MOCHI_DESKTOP_STORAGE_DIR"];
    if (override.length) return [NSURL fileURLWithPath:override isDirectory:YES];
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"Mochi/Storage" isDirectory:YES];
}

@implementation DesktopProgram

- (instancetype)initWithResources:(NSURL *)resources {
    if (!(self = [super init])) return nil;
    _resources = resources;
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:[resources URLByAppendingPathComponent:@"scene.json"]
                                        options:0 error:&error];
    if (!data) DesktopFailure(error.localizedDescription);
    id scene = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![scene isKindOfClass:NSDictionary.class]) DesktopFailure(@"Invalid desktop scene");
    _scene = scene;
    NSDictionary *root = _scene[@"components"][_scene[@"root"] ?: @""] ?: _scene;
    if (![_scene[@"version"] isEqual:@(MOCHI_DESKTOP_SCENE_SCHEMA)]) failIn(root, @"initialize", @"unsupported desktop scene version");
    if (mochi_native_abi_version() != MOCHI_DESKTOP_NATIVE_ABI)
        failIn(root, @"initialize", @"incompatible native GVM ABI version");
    id fingerprint = _scene[@"capacity"];
    NSString *runtimeFingerprint = @(mochi_native_capacity_fingerprint());
    if (![fingerprint isEqual:runtimeFingerprint])
        failIn(root, @"initialize", [NSString stringWithFormat:@"capacity profile mismatch (scene %@, VM %@)",
                                       fingerprint ?: @"missing", runtimeFingerprint]);
    if (mochi_native_open() != 0) vmFailure(root, @"initialize");
    if ([_scene[@"storage"] boolValue]) {
        NSString *identity = _scene[@"app_id"];
        if (![identity isKindOfClass:NSString.class] || !identity.length) failIn(root, @"initialize", @"missing storage app identity");
        static NSString *activeIdentity;
        static NSURL *activeDirectory;
        static DesktopStorage *activeStorage;
        NSURL *directory = storageDirectory();
        if (activeStorage && (![identity isEqual:activeIdentity] ||
            (directory != activeDirectory && ![directory isEqual:activeDirectory])))
            failIn(root, @"initialize", @"the native VM already owns a different app storage");
        if (!activeStorage) {
            activeStorage = [[DesktopStorage alloc] initWithIdentity:identity directory:directory];
            activeIdentity = [identity copy];
            activeDirectory = directory;
        }
        _storage = activeStorage;
    }
    // The bridge owns a process-wide VM. Content-identical packages are
    // already loaded when another view or bundle uses the same Ruby package.
    static NSMutableSet<NSData *> *loaded;
    if (!loaded) loaded = [NSMutableSet set];
    for (NSString *file in _scene[@"packages"]) {
        NSData *body = [NSData dataWithContentsOfURL:[resources URLByAppendingPathComponent:file]];
        if (!body || body.length > INT32_MAX - 10)
            failIn(root, file, @"cannot read bytecode");
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(body.bytes, (CC_LONG)body.length, digest);
        NSData *identity = [NSData dataWithBytes:digest length:sizeof(digest)];
        if ([loaded containsObject:identity]) continue;
        NSMutableData *irep __attribute__((objc_precise_lifetime)) =
            [NSMutableData dataWithBytes:"RITE0400\0\0" length:10];
        [irep appendData:body];
        if (mochi_native_load(bytes(irep)) != 0) {
            [_storage restoreMirror];
            vmFailure(root, file);
        }
        NSArray *effects = takeEffects(root, file);
        for (NSDictionary *entry in effects) {
            NSString *error = [_storage applyEffect:entry from:nil];
            if (error) NSLog(@"Mochi desktop: %@ storage: %@", file, error);
        }
        if (effects.count) [_storage restoreMirror];
        [loaded addObject:identity];
    }
    return self;
}
@end

@implementation DesktopVM {
    MochiNativeInstance _instance;
    NSDictionary<NSNumber *, NSString *> *_patches;
    NSDictionary *_attributes;
    NSMutableArray<NSDictionary *> *_events;
    NSMutableArray<NSString *> *_focusRequests;
    NSMutableArray<NSString *> *_hostErrors;
    DesktopStorage *_storage;
    BOOL _closing;
}

- (NSDictionary *)values { return _patches; }

- (instancetype)initWithProgram:(DesktopProgram *)program {
    return [self initWithScene:program.scene[@"components"][program.scene[@"root"]] attributes:@{} storage:program.storage];
}

static NSData *jsonData(NSDictionary *scene, NSString *method, id value) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
    if (!json) failIn(scene, method, error.localizedDescription);
    return json;
}

- (instancetype)initWithScene:(NSDictionary *)scene attributes:(NSDictionary *)attributes {
    return [self initWithScene:scene attributes:attributes storage:nil];
}

- (instancetype)initWithScene:(NSDictionary *)scene attributes:(NSDictionary *)attributes storage:(DesktopStorage *)storage {
    if (!(self = [super init])) return nil;
    _storage = storage;
    _hostErrors = [NSMutableArray array];
    _scene = scene;
    if (!_scene) DesktopFailure(@"Missing desktop component descriptor");
    _events = [NSMutableArray array];
    _focusRequests = [NSMutableArray array];
    NSDictionary *props = DesktopProps(_scene, nil, attributes);
    NSString *name = _scene[@"class"];
    NSData *className __attribute__((objc_precise_lifetime)) = [name dataUsingEncoding:NSUTF8StringEncoding];
    int result;
    if ([_scene[@"props"] count]) {
        NSData *json __attribute__((objc_precise_lifetime)) = jsonData(_scene, @"initialize", props);
        result = mochi_native_mount_props(bytes(className), bytes(json), &_instance);
    } else {
        result = mochi_native_mount(bytes(className), &_instance);
    }
    if (result != 0) [self failedEntry:@"initialize"];
    BOOL ranMounted = NO;
    @try {
        NSDictionary *getters = _scene[@"getters"];
        for (NSString *key in getters) {
            NSScanner *scanner = [NSScanner scannerWithString:key];
            unsigned long long idValue;
            if (![scanner scanUnsignedLongLong:&idValue] || !scanner.isAtEnd || idValue > UINT16_MAX)
                failIn(_scene, @"initialize", [@"invalid binding ID " stringByAppendingString:key]);
            NSString *getter = getters[key];
            NSData *getterName __attribute__((objc_precise_lifetime)) = [getter dataUsingEncoding:NSUTF8StringEncoding];
            if (mochi_native_bind(_instance, (uint16_t)idValue, bytes(getterName)) != 0)
                [self failedEntry:getter];
        }
        ranMounted = YES;
        [self lifecycle:@"mounted"];
        _patches = @{};
        [self flush:@"initialize"];
        _attributes = [attributes copy];
    } @catch (NSException *e) {
        mochi_native_take_effects();
        [_storage restoreMirror];
        _closing = YES;
        if (ranMounted) {
            @try { [self lifecycle:@"unmounted"]; [self consumeEffects:@"unmounted"]; }
            @catch (NSException *cleanupError) { NSLog(@"Mochi desktop: %@", cleanupError.reason); }
        }
        [self releaseInstance];
        @throw;
    }
    return self;
}

- (void)releaseInstance {
    MochiNativeInstance instance = _instance;
    _instance = 0;
    if (instance) {
        [_storage removeSubscriptions:self];
        mochi_native_unmount(instance);
        mochi_native_take_effects();
    }
}

- (void)dealloc {
    [self releaseInstance];
}

- (void)failedEntry:(NSString *)method {
    // The shared Ruby API updates an optimistic mirror within a running entry.
    // A rejected entry has discarded its outbox, so restore the durable view.
    [_storage restoreMirror];
    vmFailure(_scene, method);
}

- (void)flush:(NSString *)method {
    // Commit completed Ruby effects before evaluating binding getters.
    [self consumeEffects:method];
    MochiNativePatches patches;
    if (mochi_native_flush(_instance, &patches) != 0) [self failedEntry:method];
    @try {
        _patches = DesktopApplyPatches(_scene, method, _patches, patches);
    } @catch (NSException *error) {
        mochi_native_take_effects();
        [_storage restoreMirror];
        @throw;
    }
    [self consumeEffects:method];
}

- (void)consumeEffects:(NSString *)method {
    NSArray *effects;
    @try { effects = takeEffects(_scene, method); }
    @catch (NSException *error) { [_storage restoreMirror]; @throw; }
    NSString *ownHandle = [NSString stringWithFormat:@"%llu", (unsigned long long)_instance];
    BOOL mutatedStorage = NO;
    for (NSDictionary *entry in effects) {
        NSString *kind = entry[@"__host"];
        if ([kind isEqual:@"focus"]) {
            if (![entry[@"instance"] isEqual:ownHandle] || ![entry[@"name"] isKindOfClass:NSString.class] ||
                ![entry[@"name"] length]) failIn(_scene, method, @"invalid native focus request");
            if (!_closing) [_focusRequests addObject:entry[@"name"]];
            continue;
        }
        if (kind) {
            if (!_storage || ![entry[@"key"] isKindOfClass:NSString.class])
                failIn(_scene, method, @"invalid native storage record");
            BOOL subscribing = [kind isEqual:@"storage_subscribe"];
            if (subscribing && (![entry[@"instance"] isEqual:ownHandle] ||
                                ![entry[@"callback"] isKindOfClass:NSString.class]))
                failIn(_scene, method, @"invalid native storage subscriber");
            if ([kind isEqual:@"storage_set"] && ![entry[@"value"] isKindOfClass:NSString.class])
                failIn(_scene, method, @"invalid native storage value");
            mutatedStorage |= !subscribing;
            NSString *error = [_storage applyEffect:entry from:_closing ? nil : self];
            if (error) {
                NSNumber *line = _scene[@"methods"][method] ?: @1;
                [self reportHostError:[NSString stringWithFormat:@"%@:%@ (%@, %@) storage %@: %@",
                    _scene[@"source"], line, _scene[@"class"], method, kind, error]];
            }
        } else {
            if (![entry[@"__child_event"] isKindOfClass:NSString.class] ||
                ![entry[@"instance"] isEqual:ownHandle] || !entry[@"payload"])
                failIn(_scene, method, @"invalid native child event record");
            if (!_closing)
                [_events addObject:@{@"name":entry[@"__child_event"], @"payload":entry[@"payload"], @"method":method}];
        }
    }
    if (mutatedStorage) [_storage restoreMirror];
}

- (void)reportHostError:(NSString *)reason {
    if (self.hostView) [self.hostView reportComponentFailure:reason];
    else [_hostErrors addObject:reason];
}

- (NSArray<NSString *> *)takeHostErrors {
    NSArray *errors = [_hostErrors copy];
    [_hostErrors removeAllObjects];
    return errors;
}

- (void)deliverStorage:(NSString *)callback payload:(NSDictionary *)payload {
    if (!_instance || _closing) return;
    int64_t arity = [self arity:callback];
    if (arity < 0) return;
    [self activate:callback arguments:(arity == 1 ? @[payload] : @[]) payload:payload];
    [self.hostView storageUpdated:self];
}

- (NSArray<NSDictionary *> *)takeEvents {
    NSArray *events = [_events copy];
    [_events removeAllObjects];
    return events;
}

- (NSArray<NSString *> *)takeFocusRequests {
    NSArray *requests = [_focusRequests copy];
    [_focusRequests removeAllObjects];
    return requests;
}

- (void)updateAttributes:(NSDictionary *)attributes {
    if ([_attributes isEqual:attributes]) return;
    NSDictionary *props = DesktopProps(_scene, _attributes, attributes);
    if (props.count) {
        NSData *json __attribute__((objc_precise_lifetime)) = jsonData(_scene, @"props", props);
        if (mochi_native_set_props(_instance, bytes(json)) != 0) [self failedEntry:@"props"];
    }
    _attributes = [attributes copy];
    if (props.count) [self flush:@"props"];
}

- (int64_t)arity:(NSString *)method {
    NSData *name __attribute__((objc_precise_lifetime)) = [method dataUsingEncoding:NSUTF8StringEncoding];
    int64_t arity;
    if (mochi_native_method_arity(_instance, bytes(name), &arity) != 0) [self failedEntry:method];
    return arity;
}

- (void)call:(NSString *)method arguments:(NSArray *)args {
    NSData *json __attribute__((objc_precise_lifetime)) = jsonData(_scene, method, args);
    NSData *name __attribute__((objc_precise_lifetime)) = [method dataUsingEncoding:NSUTF8StringEncoding];
    if (mochi_native_dispatch(_instance, bytes(name), bytes(json)) != 0) [self failedEntry:method];
}

- (void)lifecycle:(NSString *)method {
    if ([self arity:method] >= 0) [self call:method arguments:@[]];
}

- (void)activate:(NSString *)method arguments:(NSArray *)args payload:(NSDictionary *)payload {
    if (!_instance) return;
    if (!args) args = [self arity:method] == 1 ? @[payload] : @[];
    [self call:method arguments:args];
    [self flush:method];
}

- (void)close {
    if (!_instance) return;
    _closing = YES;
    [_storage removeSubscriptions:self];
    @try {
        [self lifecycle:@"unmounted"];
        [self consumeEffects:@"unmounted"];
    } @finally { [self releaseInstance]; }
}
@end
