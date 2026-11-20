#import "../Native.h"

static void captureInspector(DesktopView *view, NSString *directory, NSInteger width, NSInteger scale, NSString *name) {
    if ([name rangeOfString:@"\\A[a-z][a-z0-9-]*\\z" options:NSRegularExpressionSearch].location == NSNotFound)
        DesktopFailure(@"invalid inspector checkpoint name");
    NSArray *observations = view.layoutObservations;
    NSDictionary *panel = observations.firstObject;
    NSArray *rect = panel[@"rect"];
    if (![panel[@"id"] isEqual:@"panel"] || rect.count != 4)
        DesktopFailure(@"missing inspector panel bounds");
    NSInteger height = (NSInteger)ceil(2 * [rect[1] doubleValue] + [rect[3] doubleValue]);
    NSRect crop = NSMakeRect(0, 0, width, height);
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:width * scale pixelsHigh:height * scale
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    bitmap.size = crop.size;
    [view displayIfNeeded];
    [view cacheDisplayInRect:crop toBitmapImageRep:bitmap];
    NSBitmapImageRep *srgb = [bitmap bitmapImageRepByConvertingToColorSpace:NSColorSpace.sRGBColorSpace
        renderingIntent:NSColorRenderingIntentRelativeColorimetric];
    NSData *png = [srgb representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *stem = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld-%@", (long)width, name]];
    if (![png writeToFile:[stem stringByAppendingPathExtension:@"png"] atomically:YES])
        DesktopFailure(@"cannot write native inspector PNG");

    id focus = NSNull.null;
    NSDictionary *attrs = [view attributesForAccessibilityElement:view.window.firstResponder];
    if (attrs[@"data-action"]) focus = [@"action-" stringByAppendingString:attrs[@"data-action"]];
    if (attrs[@"data-id"]) focus = [@"station-" stringByAppendingString:attrs[@"data-id"]];
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{
        @"width":@(width), @"height":@(height), @"scale":@(scale), @"focus":focus, @"controls":observations
    } options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!json || ![json writeToFile:[stem stringByAppendingPathExtension:@"json"] options:NSDataWritingAtomic error:&error])
        DesktopFailure(error.localizedDescription);
}
