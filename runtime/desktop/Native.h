#import <AppKit/AppKit.h>

#include <mochi_native.h>

#define MOCHI_DESKTOP_NATIVE_ABI 1
#if MOCHI_NATIVE_ABI_VERSION != MOCHI_DESKTOP_NATIVE_ABI
#error "Mochi desktop requires native GVM ABI version 1"
#endif

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
NSDictionary<NSNumber *, NSString *> *DesktopApplyPatches(
    NSDictionary *scene, NSString *method, NSDictionary<NSNumber *, NSString *> *current,
    MochiNativePatches patches);

@interface DesktopProgram : NSObject
@property(nonatomic, readonly) NSURL *resources;
@property(nonatomic, readonly) NSDictionary *scene;
- (instancetype)initWithResources:(NSURL *)resources;
@end

@interface DesktopVM : NSObject
@property(nonatomic, readonly) NSDictionary *scene;
@property(nonatomic, readonly) NSDictionary<NSNumber *, NSString *> *values;
- (instancetype)initWithProgram:(DesktopProgram *)program;
- (void)activate:(NSString *)method arguments:(NSArray *)args payload:(NSDictionary *)payload;
- (void)close;
@end

@interface DesktopView : NSView
#ifdef MOCHI_DESKTOP_CAPTURE
@property(nonatomic, readonly) NSArray<NSDictionary *> *layoutObservations;
#endif
@property(nonatomic, readonly) NSString *failureReason;
- (instancetype)initWithResources:(NSURL *)resources;
- (instancetype)initWithProgram:(DesktopProgram *)program;
- (NSDictionary *)attributesForAccessibilityElement:(id)element;
- (void)close;
@end
