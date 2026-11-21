#import "Native.h"
#import <CommonCrypto/CommonDigest.h>

void DesktopFailure(NSString *reason) {
    @throw [NSException exceptionWithName:@"MochiDesktopError" reason:reason userInfo:nil];
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
    if (![_scene[@"version"] isEqual:@5]) failIn(root, @"initialize", @"unsupported desktop scene version");
    if (mochi_native_abi_version() != MOCHI_DESKTOP_NATIVE_ABI)
        failIn(root, @"initialize", @"incompatible native GVM ABI version");
    id fingerprint = _scene[@"capacity"];
    NSString *runtimeFingerprint = @(mochi_native_capacity_fingerprint());
    if (![fingerprint isEqual:runtimeFingerprint])
        failIn(root, @"initialize", [NSString stringWithFormat:@"capacity profile mismatch (scene %@, VM %@)",
                                       fingerprint ?: @"missing", runtimeFingerprint]);
    if (mochi_native_open() != 0) vmFailure(root, @"initialize");
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
        if (mochi_native_load(bytes(irep)) != 0) vmFailure(root, file);
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
}

- (NSDictionary *)values { return _patches; }

- (instancetype)initWithProgram:(DesktopProgram *)program {
    return [self initWithScene:program.scene[@"components"][program.scene[@"root"]] attributes:@{}];
}

static NSData *jsonData(NSDictionary *scene, NSString *method, id value) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
    if (!json) failIn(scene, method, error.localizedDescription);
    return json;
}

- (instancetype)initWithScene:(NSDictionary *)scene attributes:(NSDictionary *)attributes {
    if (!(self = [super init])) return nil;
    _scene = scene;
    if (!_scene) DesktopFailure(@"Missing desktop component descriptor");
    _events = [NSMutableArray array];
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
    if (result != 0) vmFailure(_scene, @"initialize");
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
                vmFailure(_scene, getter);
        }
        ranMounted = YES;
        [self lifecycle:@"mounted"];
        _patches = @{};
        [self flush:@"initialize"];
        _attributes = [attributes copy];
    } @catch (NSException *e) {
        mochi_native_take_child_events();
        if (ranMounted) {
            @try { [self lifecycle:@"unmounted"]; }
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
        mochi_native_unmount(instance);
        mochi_native_take_child_events();
    }
}

- (void)dealloc {
    [self releaseInstance];
}

- (void)flush:(NSString *)method {
    MochiNativePatches patches;
    if (mochi_native_flush(_instance, &patches) != 0) vmFailure(_scene, method);
    @try {
        _patches = DesktopApplyPatches(_scene, method, _patches, patches);
    } @finally {
        MochiNativeBytes pending = mochi_native_take_child_events();
        if (pending.length) [self captureEvents:pending method:method];
    }
}

- (void)captureEvents:(MochiNativeBytes)pending method:(NSString *)method {
    NSString *wire = [[NSString alloc] initWithBytes:pending.data length:pending.length encoding:NSUTF8StringEncoding];
    if (!wire) failIn(_scene, method, @"invalid UTF-8 in child event batch");
    NSString *ownHandle = [NSString stringWithFormat:@"%llu", (unsigned long long)_instance];
    for (NSString *line in [wire componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        id entry = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"__child_event"] isKindOfClass:NSString.class] ||
            ![entry[@"instance"] isEqual:ownHandle] || !entry[@"payload"])
            failIn(_scene, method, @"invalid native child event record");
        [_events addObject:@{@"name":entry[@"__child_event"], @"payload":entry[@"payload"], @"method":method}];
    }
}

- (NSArray<NSDictionary *> *)takeEvents {
    NSArray *events = [_events copy];
    [_events removeAllObjects];
    return events;
}

- (void)updateAttributes:(NSDictionary *)attributes {
    if ([_attributes isEqual:attributes]) return;
    NSDictionary *props = DesktopProps(_scene, _attributes, attributes);
    if (props.count) {
        NSData *json __attribute__((objc_precise_lifetime)) = jsonData(_scene, @"props", props);
        if (mochi_native_set_props(_instance, bytes(json)) != 0) vmFailure(_scene, @"props");
    }
    _attributes = [attributes copy];
    if (props.count) [self flush:@"props"];
}

- (int64_t)arity:(NSString *)method {
    NSData *name __attribute__((objc_precise_lifetime)) = [method dataUsingEncoding:NSUTF8StringEncoding];
    int64_t arity;
    if (mochi_native_method_arity(_instance, bytes(name), &arity) != 0) vmFailure(_scene, method);
    return arity;
}

- (void)call:(NSString *)method arguments:(NSArray *)args {
    NSData *json __attribute__((objc_precise_lifetime)) = jsonData(_scene, method, args);
    NSData *name __attribute__((objc_precise_lifetime)) = [method dataUsingEncoding:NSUTF8StringEncoding];
    if (mochi_native_dispatch(_instance, bytes(name), bytes(json)) != 0) vmFailure(_scene, method);
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
    @try { [self lifecycle:@"unmounted"]; }
    @finally { [self releaseInstance]; }
}
@end
