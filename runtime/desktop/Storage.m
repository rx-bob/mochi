#import "Native.h"
#import <CommonCrypto/CommonDigest.h>
#include <mochi_capacity_profile.h>
#include <sqlite3.h>

@interface DesktopStorageSubscription : NSObject
@property(nonatomic, weak) DesktopVM *vm;
@property(nonatomic, copy) NSString *callback;
@end
@implementation DesktopStorageSubscription
@end

static NSString *storeName(NSString *identity) {
    NSData *data = [identity dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *name = [NSMutableString stringWithCapacity:sizeof(digest) * 2 + 8];
    for (size_t i = 0; i < sizeof(digest); i++) [name appendFormat:@"%02x", digest[i]];
    return [name stringByAppendingString:@".sqlite3"];
}

static NSDictionary *receipt(NSString *key, NSString *value, NSString *previous, NSString *source, NSString *error) {
    return @{@"key":key, @"value":value ?: NSNull.null, @"previous":previous ?: NSNull.null,
             @"source":source, @"ok":@((BOOL)(error == nil)), @"error":error ?: @""};
}

static BOOL fitsReceipt(NSString *key, NSString *value) {
    // A failed write may include the previous value twice. Reserve space for
    // the callback's field names, source and status in the VM argument array.
    id text = value ?: NSNull.null;
    NSData *wire = [NSJSONSerialization dataWithJSONObject:@[key, text, text] options:0 error:NULL];
    return wire && wire.length <= MOCHI_EVENT_ARGS_CAPACITY - 256;
}

static int bindText(sqlite3_stmt *statement, int index, NSString *text) {
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8) return SQLITE_MISMATCH;
    return sqlite3_bind_text64(statement, index, utf8.length ? utf8.bytes : "", utf8.length, SQLITE_TRANSIENT, SQLITE_UTF8);
}

static NSString *columnText(sqlite3_stmt *statement, int column) {
    const unsigned char *text = sqlite3_column_text(statement, column);
    return text ? [[NSString alloc] initWithBytes:text length:sqlite3_column_bytes(statement, column)
        encoding:NSUTF8StringEncoding] : nil;
}

static int readValue(sqlite3 *db, NSString *key, NSString **value) {
    sqlite3_stmt *statement = NULL;
    int status = sqlite3_prepare_v2(db, "SELECT value FROM storage WHERE key = ?1", -1, &statement, NULL);
    if (status == SQLITE_OK) status = bindText(statement, 1, key);
    if (status == SQLITE_OK) {
        status = sqlite3_step(statement);
        if (status == SQLITE_ROW) {
            *value = columnText(statement, 0);
            status = *value ? SQLITE_OK : SQLITE_CORRUPT;
        } else if (status == SQLITE_DONE) {
            *value = nil;
            status = SQLITE_OK;
        }
    }
    sqlite3_finalize(statement);
    return status;
}

static int writeValue(sqlite3 *db, NSString *key, NSString *value) {
    sqlite3_stmt *statement = NULL;
    const char *sql = value ? "INSERT OR REPLACE INTO storage (key, value) VALUES (?1, ?2)"
                            : "DELETE FROM storage WHERE key = ?1";
    int status = sqlite3_prepare_v2(db, sql, -1, &statement, NULL);
    if (status == SQLITE_OK) status = bindText(statement, 1, key);
    if (status == SQLITE_OK && value) status = bindText(statement, 2, value);
    if (status == SQLITE_OK) status = sqlite3_step(statement);
    sqlite3_finalize(statement);
    return status == SQLITE_DONE ? SQLITE_OK : status;
}

@implementation DesktopStorage {
    NSURL *_directory, *_file;
    NSMutableDictionary<NSString *, NSString *> *_snapshot;
    NSMutableDictionary<NSString *, NSMutableArray<DesktopStorageSubscription *> *> *_subscriptions;
    NSMutableArray<NSDictionary *> *_deliveries;
    BOOL _available, _draining;
}

- (instancetype)initWithIdentity:(NSString *)identity directory:(NSURL *)directory {
    if (!(self = [super init])) return nil;
    _directory = directory;
    _file = [_directory URLByAppendingPathComponent:storeName(identity)];
    _snapshot = [NSMutableDictionary dictionary];
    _subscriptions = [NSMutableDictionary dictionary];
    _deliveries = [NSMutableArray array];
    sqlite3 *db = NULL;
    int status = [self open:&db];
    if (status != SQLITE_OK && _file) {
        sqlite3_close(db);
        db = NULL;
        status = sqlite3_open_v2(_file.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL);
    }
    sqlite3_stmt *statement = NULL;
    if (status == SQLITE_OK)
        status = sqlite3_prepare_v2(db, "SELECT key, value FROM storage", -1, &statement, NULL);
    if (status == SQLITE_OK) {
        while ((status = sqlite3_step(statement)) == SQLITE_ROW) {
            NSString *key = columnText(statement, 0), *value = columnText(statement, 1);
            if (!key.length || !value || !fitsReceipt(key, value)) {
                status = SQLITE_CORRUPT;
                break;
            }
            _snapshot[key] = value;
        }
    }
    sqlite3_finalize(statement);
    sqlite3_close(db);
    _available = status == SQLITE_DONE;
    if (!_available) [_snapshot removeAllObjects];
    [self restoreMirror];
    return self;
}

- (int)open:(sqlite3 **)db {
    if (!_directory || ![NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:NULL]) return SQLITE_CANTOPEN;
    int status = sqlite3_open_v2(_file.fileSystemRepresentation, db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    if (status == SQLITE_OK) {
        sqlite3_busy_timeout(*db, 500);
        status = sqlite3_exec(*db, "PRAGMA synchronous=EXTRA;"
            "CREATE TABLE IF NOT EXISTS storage (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;",
            NULL, NULL, NULL);
    }
    return status;
}

- (void)restoreMirror {
    if (mochi_native_reset_storage() != 0) DesktopFailure(@"cannot reset the desktop storage mirror");
    for (NSString *key in _snapshot) {
        NSData *name __attribute__((objc_precise_lifetime)) = [key dataUsingEncoding:NSUTF8StringEncoding];
        NSData *value __attribute__((objc_precise_lifetime)) = [_snapshot[key] dataUsingEncoding:NSUTF8StringEncoding];
        if (mochi_native_seed_storage((MochiNativeBytes){name.bytes, name.length},
                                     (MochiNativeBytes){value.bytes, value.length}) != 0)
            DesktopFailure(@"cannot seed the desktop storage mirror");
    }
}

- (void)enqueue:(DesktopStorageSubscription *)subscription payload:(NSDictionary *)payload {
    if (subscription.vm) [_deliveries addObject:@{@"subscription":subscription,
        @"callback":subscription.callback, @"payload":payload}];
}

- (void)subscribe:(DesktopVM *)vm key:(NSString *)key callback:(NSString *)callback {
    if (!vm || !key.length || !callback.length || !fitsReceipt(key, nil)) return;
    NSMutableArray *bucket = _subscriptions[key];
    if (!bucket) _subscriptions[key] = bucket = [NSMutableArray array];
    DesktopStorageSubscription *record = nil;
    for (DesktopStorageSubscription *candidate in bucket) {
        if (candidate.vm == vm) { record = candidate; break; }
    }
    if (!record) {
        record = [DesktopStorageSubscription new];
        record.vm = vm;
        [bucket addObject:record];
    }
    record.callback = callback;
    [self enqueue:record payload:receipt(key, _snapshot[key], nil, @"initial", _available ? nil : @"unavailable")];
}

- (void)removeSubscriptions:(DesktopVM *)vm {
    for (NSString *key in _subscriptions.allKeys) {
        NSMutableArray *bucket = _subscriptions[key];
        NSIndexSet *dead = [bucket indexesOfObjectsPassingTest:^BOOL(DesktopStorageSubscription *record,
                                                                      NSUInteger index, BOOL *stop) {
            if (record.vm && record.vm != vm) return NO;
            record.vm = nil;
            return YES;
        }];
        [bucket removeObjectsAtIndexes:dead];
        if (!bucket.count) [_subscriptions removeObjectForKey:key];
    }
}

- (NSString *)applyEffect:(NSDictionary *)command from:(DesktopVM *)vm {
    NSString *kind = command[@"__host"], *key = command[@"key"];
    if ([kind isEqual:@"storage_subscribe"]) {
        [self subscribe:vm key:key callback:command[@"callback"]];
        return nil;
    }

    NSString *value = [kind isEqual:@"storage_set"] ? command[@"value"] : nil;
    NSString *previous = _snapshot[key];
    NSString *durablePrevious = previous;
    sqlite3 *db = NULL;
    int status = key.length ? [self open:&db] : SQLITE_MISMATCH;
    if (status == SQLITE_OK) status = sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL);
    if (status == SQLITE_OK) status = readValue(db, key, &durablePrevious);
    if (status == SQLITE_OK && durablePrevious && !fitsReceipt(key, durablePrevious)) status = SQLITE_CORRUPT;
    if (status == SQLITE_OK) previous = durablePrevious;
    BOOL changed = !((previous == value) || [previous isEqualToString:value]);
    if (status == SQLITE_OK && !fitsReceipt(key, value)) status = SQLITE_TOOBIG;
    if (status == SQLITE_OK && changed) status = writeValue(db, key, value);
    if (status == SQLITE_OK) status = sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);
    if (status != SQLITE_OK && db) sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
    sqlite3_close(db);

    NSString *error = nil;
    if (status == SQLITE_OK) _available = YES;
    else {
        value = previous;
        error = (status == SQLITE_FULL || status == SQLITE_TOOBIG) ? @"quota" : @"unavailable";
    }
    _snapshot[key] = value;
    if (error || changed) {
        NSDictionary *payload = receipt(key, value, previous, @"same_tab", error);
        for (DesktopStorageSubscription *record in _subscriptions[key]) [self enqueue:record payload:payload];
    }
    return error;
}

- (void)drain {
    if (_draining) return;
    _draining = YES;
    @try {
        for (NSUInteger delivered = 0; _deliveries.count; delivered++) {
            NSDictionary *next = _deliveries.firstObject;
            [_deliveries removeObjectAtIndex:0];
            DesktopStorageSubscription *subscription = next[@"subscription"];
            DesktopVM *vm = subscription.vm;
            if (delivered == 4096) {
                [_deliveries removeAllObjects];
                [vm reportHostError:@"desktop storage notification cascade exceeded its limit"];
                break;
            }
            if (!vm) continue;
            @try {
                [vm deliverStorage:next[@"callback"] payload:next[@"payload"]];
            } @catch (NSException *error) { [vm reportHostError:error.reason]; }
        }
    } @finally { _draining = NO; }
}
@end
