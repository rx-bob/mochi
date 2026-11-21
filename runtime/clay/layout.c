// Native layout bridge. clay.h is based on Clay v0.14
// (b25a31c1a152915cd7dd6796e6592273e5a10aac) with local word-wrap and fixed-zero sizing fixes.
#define CLAY_IMPLEMENTATION
#include "clay.h"

float mochi_clay_measure(const char *text, int length, int font);
void mochi_clay_rectangle(int node, float x, float y, float width, float height);
void mochi_clay_line(const char *text, int length, int font, float x, float y, float height);
void mochi_clay_fail(const char *message, int length);

enum { ELEMENT_CAPACITY = 512 };
static unsigned char arena[1024 * 1024];
static char strings[64 * 1024];
static Clay_RenderCommandArray commands;

static Clay_Dimensions measure_text(Clay_StringSlice text, Clay_TextElementConfig *config, void *unused) {
    return (Clay_Dimensions){mochi_clay_measure(text.chars, text.length, config->fontId), config->lineHeight};
}

static void layout_error(Clay_ErrorData error) {
    mochi_clay_fail(error.errorText.chars, error.errorText.length);
}

void mochi_clay_init(void) {
    Clay_SetMaxElementCount(ELEMENT_CAPACITY);
    Clay_SetMaxMeasureTextCacheWordCount(4096);
    if (Clay_MinMemorySize() > sizeof(arena)) {
        Clay_String msg = CLAY_STRING("Clay arena too small");
        mochi_clay_fail(msg.chars, msg.length);
    }
    Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(sizeof(arena), arena),
                    (Clay_Dimensions){1, 1}, (Clay_ErrorHandler){.errorHandlerFunction = layout_error});
    Clay_SetMeasureTextFunction(measure_text, NULL);
    Clay_SetCullingEnabled(false);
}

char *mochi_clay_string_buffer(void) { return strings; }
int mochi_clay_string_capacity(void) { return sizeof(strings); }

void mochi_clay_begin(float width) {
    // node and font indices are local to the current traversal.
    Clay_ResetMeasureTextCache();
    // The host owns scroll position. Clay only measures the content for this frame.
    Clay_GetCurrentContext()->scrollContainerDatas.length = 0;
    Clay_SetLayoutDimensions((Clay_Dimensions){width, 65535});
    Clay_BeginLayout();
}

static void require_element(void) {
    // Clay reserves the last slot and opens one implicit window element.
    if (Clay_GetCurrentContext()->layoutElements.length >= ELEMENT_CAPACITY - 1) {
        Clay_String message = CLAY_STRING("Clay layout element limit exceeded (510 boxes and text leaves per frame, including the app wrapper)");
        mochi_clay_fail(message.chars, message.length);
    }
}

void mochi_clay_open_box(int node, int column, int stretch, float width, float height, float max_height, int scroll,
                               int left, int right, int top, int bottom, int gap) {
    require_element();
    Clay__OpenElement();
    Clay__ConfigureOpenElement((Clay_ElementDeclaration){
        .id = CLAY_IDI("node", node),
        .layout = {
            .sizing = {width >= 0 ? CLAY_SIZING_FIXED(width) : stretch ? CLAY_SIZING_GROW(0) : CLAY_SIZING_FIT(0),
                       height >= 0 ? CLAY_SIZING_FIXED(height) : CLAY_SIZING_FIT(0, max_height)},
            .layoutDirection = column ? CLAY_TOP_TO_BOTTOM : CLAY_LEFT_TO_RIGHT,
            .padding = {left, right, top, bottom}, .childGap = gap
        },
        .clip = {.vertical = scroll},
        // The painter resolves CSS colors. Emit bounds even for transparent boxes.
        .backgroundColor = {0, 0, 0, 255}, .userData = (void *)(uintptr_t)node
    });
}

void mochi_clay_text_leaf(int offset, int length, int font, int line_height) {
    require_element();
    CLAY_TEXT(((Clay_String){false, length, strings + offset}),
              CLAY_TEXT_CONFIG({.fontId = font, .lineHeight = line_height}));
}

float mochi_clay_content_height(int node) {
    return Clay_GetScrollContainerData(CLAY_IDI("node", node)).contentDimensions.height;
}

void mochi_clay_close_box(void) { Clay__CloseElement(); }

float mochi_clay_end(void) {
    commands = Clay_EndLayout();
    return Clay_GetElementData(CLAY_IDI("node", 0)).boundingBox.height;
}

void mochi_clay_paint(void) {
    for (int i = 0; i < commands.length; i++) {
        Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, i);
        Clay_BoundingBox b = command->boundingBox;
        if (command->commandType == CLAY_RENDER_COMMAND_TYPE_RECTANGLE) {
            mochi_clay_rectangle((int)(uintptr_t)command->userData, b.x, b.y, b.width, b.height);
        } else if (command->commandType == CLAY_RENDER_COMMAND_TYPE_TEXT) {
            Clay_TextRenderData data = command->renderData.text;
            mochi_clay_line(data.stringContents.chars, data.stringContents.length, data.fontId, b.x, b.y, b.height);
        }
    }
}
