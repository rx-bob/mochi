#import <AppKit/AppKit.h>

// Mochi GVM uses real, pointer-width buffers in the native host.
void goose_init(int argc, char **argv);
int32_t mochi_init_runtime(void);
const char *mochi_capacity_fingerprint(void);
int32_t mochi_load_irep(const uint8_t *, int32_t);
uint64_t mochi_mount_component(const uint8_t *, int32_t);
int32_t mochi_unmount_component(uint64_t);
uint32_t mochi_intern(const uint8_t *, int32_t);
int32_t mochi_register_binding(uint64_t, uint32_t, uint32_t);
int32_t mochi_dispatch_event_args(uint64_t, uint32_t, const uint8_t *, int32_t);
int32_t mochi_has_method(uint64_t, const uint8_t *, int32_t);
int64_t goose_vm_method_req_argc(uint64_t, uint32_t);
int32_t mochi_flush_patches(uint64_t);
int32_t mochi_patch_buffer_len(void);
int32_t mochi_fetch_outbox_len(void);
int32_t mochi_emit_outbox_len(void);
const uint8_t *desktop_patch_data(void);
const char *desktop_vm_error(void);

void mochi_clay_init(void);
void mochi_clay_begin(float width);
void mochi_clay_open_box(int node, int column, int stretch, float width, float height,
                        int left, int right, int top, int bottom, int gap);
void mochi_clay_close_box(void);
char *mochi_clay_string_buffer(void);
int mochi_clay_string_capacity(void);
void mochi_clay_text_leaf(int offset, int length, int font, int line_height);
float mochi_clay_end(void);
void mochi_clay_paint(void);

void DesktopFailure(NSString *reason) __attribute__((noreturn));

@interface DesktopVM : NSObject
@property(nonatomic, readonly) NSDictionary *scene;
@property(nonatomic, readonly) NSDictionary<NSNumber *, NSString *> *values;
- (instancetype)initWithResources:(NSURL *)resources;
- (void)activate:(NSString *)method arguments:(NSArray *)args payload:(NSDictionary *)payload;
- (void)close;
@end

@interface DesktopView : NSView
- (instancetype)initWithResources:(NSURL *)resources;
- (void)close;
@end
