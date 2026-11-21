#import "Native.h"
#import <errno.h>
#import <math.h>

static BOOL matches(NSString *text, NSString *pattern) {
    return [text rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

static BOOL integerText(NSString *text) {
    if (!matches(text, @"\\A-?[0-9]+\\z")) return NO;
    errno = 0;
    strtoll(text.UTF8String, NULL, 10);
    return errno != ERANGE;
}

static BOOL floatText(NSString *text) {
    return [@[@"Infinity", @"-Infinity", @"NaN"] containsObject:text] ||
        matches(text, @"\\A-?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?\\z");
}

static BOOL boolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static NSString *numberKind(id value) {
    if (![value isKindOfClass:NSDictionary.class] || [value count] != 2 ||
        ![value[@"value"] isKindOfClass:NSString.class]) return nil;
    NSString *kind = value[@"__mochi_number"];
    return [@[@"i64", @"f64"] containsObject:kind ?: NSNull.null] ? kind : nil;
}

static BOOL validTransport(id value) {
    NSString *kind = numberKind(value);
    if (kind) return [kind isEqual:@"i64"] ? integerText(value[@"value"]) : floatText(value[@"value"]);
    if ([value isKindOfClass:NSNumber.class] && !boolean(value)) {
        double number = [value doubleValue];
        return isfinite(number) && (trunc(number) != number || fabs(number) <= 9007199254740991.0);
    }
    if ([value isKindOfClass:NSArray.class]) {
        for (id item in value) if (!validTransport(item)) return NO;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        for (NSString *key in value) if (!validTransport(value[key])) return NO;
    }
    return YES;
}

static void contractError(NSDictionary *scene, NSString *method, NSDictionary *schema, NSString *message) {
    NSDictionary *source = schema[@"source"];
    DesktopFailure([NSString stringWithFormat:@"%@:%@ (%@, %@): %@", source[@"file"] ?: scene[@"source"],
                    source[@"line"] ?: scene[@"methods"][method] ?: @1, scene[@"class"], method, message]);
}

static void propError(NSDictionary *scene, NSDictionary *prop, BOOL mounting, NSString *detail) {
    contractError(scene, mounting ? @"initialize" : @"props", prop,
                  [NSString stringWithFormat:@"prop \"%@\" %@", prop[@"name"], detail]);
}

static id decodeAttribute(NSDictionary *scene, NSDictionary *prop, BOOL mounting, NSString *text) {
    NSString *type = prop[@"type"];
    if ([type isEqual:@"string"]) return text;
    if ([type isEqual:@"boolean"]) {
        if (!text.length || [text isEqual:@"true"]) return @YES;
        if ([text isEqual:@"false"]) return @NO;
    } else if ([type isEqual:@"integer"]) {
        if (integerText(text)) return @{@"__mochi_number":@"i64", @"value":text};
    } else if ([type isEqual:@"float"]) {
        if (floatText(text)) return @{@"__mochi_number":@"f64", @"value":text};
    } else if ([type isEqual:@"array"] || [type isEqual:@"hash"]) {
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        id collection = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        Class shape = [type isEqual:@"array"] ? NSArray.class : NSDictionary.class;
        if ([collection isKindOfClass:shape] && validTransport(collection)) return collection;
    }
    propError(scene, prop, mounting, [NSString stringWithFormat:@"expects %@, got \"%@\"", type, text]);
    return nil;
}

NSDictionary *DesktopProps(NSDictionary *scene, NSDictionary *previous, NSDictionary *attributes) {
    BOOL mounting = previous == nil;
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSDictionary *prop in scene[@"props"]) {
        NSString *name = prop[@"name"];
        NSString *attribute = [name stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
        NSString *raw = attributes[attribute];
        NSString *old = previous[attribute];
        if (!raw && [prop[@"required"] boolValue])
            propError(scene, prop, mounting, mounting ? @"is required but no attribute was provided" :
                      @"is required but the attribute was removed");
        if (raw == old || [raw isEqual:old]) continue;
        values[name] = raw ? decodeAttribute(scene, prop, mounting, raw) : NSNull.null;
    }
    return values;
}

static BOOL validField(id value, NSString *type) {
    NSString *kind = numberKind(value);
    if ([type isEqual:@"boolean"]) return boolean(value);
    if ([type isEqual:@"string"]) return [value isKindOfClass:NSString.class];
    if ([type isEqual:@"array"]) return [value isKindOfClass:NSArray.class] && validTransport(value);
    if ([type isEqual:@"hash"]) return !kind && [value isKindOfClass:NSDictionary.class] && validTransport(value);
    if ([type isEqual:@"integer"]) {
        if (kind) return [kind isEqual:@"i64"] && validTransport(value);
        return [value isKindOfClass:NSNumber.class] && !boolean(value) &&
            trunc([value doubleValue]) == [value doubleValue] && validTransport(value);
    }
    if ([type isEqual:@"float"])
        return (kind || ([value isKindOfClass:NSNumber.class] && !boolean(value))) && validTransport(value);
    return NO;
}

static void eventError(NSDictionary *scene, NSString *method, NSDictionary *schema, NSString *name, NSString *detail) {
    contractError(scene, method, schema, [NSString stringWithFormat:@"event \"%@\" %@", name, detail]);
}

void DesktopValidateChildEvent(NSDictionary *scene, NSString *method, NSString *name, NSDictionary *payload) {
    NSDictionary *schema = nil;
    for (NSDictionary *candidate in scene[@"emits"]) {
        if ([candidate[@"name"] isEqual:name]) { schema = candidate; break; }
    }
    if (!schema) eventError(scene, method, nil, name, @"is not declared by this component");
    if (![payload isKindOfClass:NSDictionary.class]) eventError(scene, method, schema, name, @"expects an object payload");

    NSMutableSet *unknown = [NSMutableSet setWithArray:payload.allKeys];
    for (NSDictionary *field in schema[@"payload"]) {
        NSString *key = field[@"name"];
        NSString *type = field[@"type"];
        id value = payload[key];
        if (!value)
            eventError(scene, method, schema, name, [NSString stringWithFormat:@"requires payload field \"%@\"", key]);
        if (!validField(value, type))
            eventError(scene, method, schema, name, [NSString stringWithFormat:@"payload field \"%@\" expects %@", key, type]);
        [unknown removeObject:key];
    }
    if (unknown.count)
        eventError(scene, method, schema, name,
                   [NSString stringWithFormat:@"does not declare payload field \"%@\"", [unknown.allObjects sortedArrayUsingSelector:@selector(compare:)].firstObject]);
}
