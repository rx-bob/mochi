#import "Native.h"

void DesktopFailure(NSString *reason) {
    @throw [NSException exceptionWithName:@"MochiDesktopError" reason:reason userInfo:nil];
}

static uint32_t symbol(NSString *name) {
    return mochi_intern((const uint8_t *)name.UTF8String, (int32_t)strlen(name.UTF8String));
}

static void failIn(NSDictionary *scene, NSString *method) {
    NSNumber *line = scene[@"methods"][method];
    DesktopFailure([NSString stringWithFormat:@"%@:%@ (%@): %s", scene[@"source"],
                    line ?: @1, method, desktop_vm_error()]);
}

@implementation DesktopProgram

- (instancetype)initWithResources:(NSURL *)resources {
    if (!(self = [super init])) return nil;
    _resources = resources;
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:[resources URLByAppendingPathComponent:@"scene.json"]
                                        options:0 error:&error];
    if (!data) DesktopFailure(error.localizedDescription);
    _scene = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (!_scene || ![_scene[@"version"] isEqual:@1]) DesktopFailure(@"Unsupported desktop scene version");
    if (strcmp([_scene[@"capacity"] UTF8String], mochi_capacity_fingerprint()))
        DesktopFailure(@"Desktop scene and VM capacity profiles differ");
    static dispatch_once_t once;
    dispatch_once(&once, ^{ goose_init(0, NULL); });
    if (mochi_init_runtime()) failIn(_scene, @"initialize");
    for (NSString *file in _scene[@"packages"]) {
        NSData *body = [NSData dataWithContentsOfURL:[resources URLByAppendingPathComponent:file]];
        if (!body || body.length > INT32_MAX - 10) DesktopFailure([@"Cannot load bytecode " stringByAppendingString:file]);
        NSMutableData *irep = [NSMutableData dataWithBytes:"RITE0400\0\0" length:10];
        [irep appendData:body];
        if (mochi_load_irep(irep.bytes, (int32_t)irep.length)) failIn(_scene, file);
    }
    return self;
}
@end

@implementation DesktopVM {
    uint64_t _instance;
    NSMutableDictionary<NSNumber *, NSString *> *_patches;
}

- (NSDictionary *)values { return _patches; }

- (instancetype)initWithProgram:(DesktopProgram *)program {
    if (!(self = [super init])) return nil;
    _scene = program.scene;
    const char *name = [_scene[@"class"] UTF8String];
    _instance = mochi_mount_component((const uint8_t *)name, (int32_t)strlen(name));
    if (!_instance) failIn(_scene, @"initialize");
    _patches = [NSMutableDictionary dictionary];
    @try {
        NSDictionary *getters = _scene[@"getters"];
        for (NSString *key in getters) {
            if (mochi_register_binding(_instance, key.intValue, symbol(getters[key]))) failIn(_scene, getters[key]);
        }
        [self lifecycle:@"mounted"];
        [self flush:@"initialize"];
    } @catch (NSException *e) {
        mochi_unmount_component(_instance);
        _instance = 0;
        @throw;
    }
    return self;
}

- (void)dealloc {
    if (_instance) mochi_unmount_component(_instance);
}

- (void)flush:(NSString *)method {
    int count = mochi_flush_patches(_instance);
    if (count < 0) failIn(_scene, method);
    if (mochi_fetch_outbox_len() || mochi_emit_outbox_len())
        DesktopFailure([NSString stringWithFormat:@"%@: %@ requested an unsupported desktop host operation", _scene[@"source"], method]);
    const uint8_t *p = desktop_patch_data();
    int left = mochi_patch_buffer_len();
    for (int i = 0; i < count; i++) {
        if (left < 6) DesktopFailure(@"Truncated GVM patch header");
        uint16_t key;
        uint32_t size;
        memcpy(&key, p, 2);
        memcpy(&size, p + 2, 4);
        if (size > (uint32_t)(left - 6)) DesktopFailure(@"Truncated GVM patch");
        NSString *value = [[NSString alloc] initWithBytes:p+6 length:size encoding:NSUTF8StringEncoding];
        if (!value) DesktopFailure(@"Invalid GVM patch encoding");
        _patches[@(key)] = value;
        p += 6 + size;
        left -= 6 + size;
    }
    if (left) DesktopFailure(@"Invalid GVM patch length");
}

- (void)call:(NSString *)method arguments:(NSArray *)args {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:args options:0 error:&error];
    if (!json) DesktopFailure(error.localizedDescription);
    if (mochi_dispatch_event_args(_instance, symbol(method), json.bytes, (int32_t)json.length) != 1)
        failIn(_scene, method);
}

- (void)lifecycle:(NSString *)method {
    const char *s = method.UTF8String;
    if (mochi_has_method(_instance, (const uint8_t *)s, (int32_t)strlen(s))) [self call:method arguments:@[]];
}

- (void)activate:(NSString *)method arguments:(NSArray *)args payload:(NSDictionary *)payload {
    if (!args) args = goose_vm_method_req_argc(_instance, symbol(method)) == 1 ? @[payload] : @[];
    [self call:method arguments:args];
    [self flush:method];
}

- (void)close {
    if (!_instance) return;
    @try { [self lifecycle:@"unmounted"]; }
    @finally { mochi_unmount_component(_instance); _instance = 0; }
}
@end
