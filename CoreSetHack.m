// ============================================================================
//  CoreSetHack.m
//  Core-SET v1.7 (bundle id: qingxiugai.qingxiugai.qinxiugai) 进程内激活补丁
//
//  原理(不改二进制、不越狱、不碰代码段):
//    这个 App 的"能不能用"完全由服务端接口 /check/client-startup-status 返回的
//    state 字段决定(ACTIVE / PROCESSING_NOT_ACTIVE / TOKEN_REJECTED ...)。
//    没有任何 SSL Pinning,所以最干净的打法就是:在进程内直接把这个接口的应答
//    换掉 —— 等价于给自己开了个假服务器,App 一点都察觉不到,证书校验、越狱
//    检测、完整性自检全都不会被触发。
//
//  四层保险,一层不生效还有下一层:
//    [1] NSURLProtocol 假服务器   —— 拦截 api/test.klpjwycb.xyz 全部 HTTP 请求直接应答
//    [2] NSJSONSerialization 净化  —— 万一有请求漏网,把应答里的"否决状态"改写成 ACTIVE
//    [3] WebSocket 过滤           —— 实时二次校验的否决消息吞掉(默认关,见开关)
//    [4] 激活回调兜底             —— 强制 finish:authorized:message:expiresAt: 走"已授权"
//
//  编译:见同目录 .github/workflows/build.yml(纯 clang,无需 theos)
// ============================================================================

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>

// ============================== 编译开关 =====================================
// 想改行为,直接改这里的 0/1,然后 push 一下让 GitHub 重新编译

#define QX_ENABLE_JSON_HOOK    1   // [2] JSON 净化层
#define QX_ENABLE_FINISH_HOOK  1   // [4] 激活回调兜底层
#define QX_ENABLE_WS_FILTER    0   // [3] WebSocket 过滤层(默认关,见说明)
#define QX_ENABLE_CONF_GUARD   1   // 阻止 App 自己设置的 protocolClasses 把我们的协议挤掉
#define QX_ENABLE_TEXT_PATCH   0   // [5] 二进制指令补丁(默认关!地址和版本强绑定,别乱开)
#define QX_SHOW_ALERT          0   // 注入后弹一次提示框(用来肉眼确认 dylib 到底有没有加载)

// 主二进制的判定点(v1.7 实测):
//   0x10019b4a4  tbnz w0, #0, ->  改成  b #0x10019b4bc  = 无条件通过
// 只有 QX_ENABLE_TEXT_PATCH=1 时才用,而且仅在系统允许改写代码页时生效
#define QX_PATCH_ADDR          0x10019b4a4ULL
#define QX_PATCH_OPCODE        0x14000006U   // b #+0x18

// ============================================================================

static NSString *const QXTag = @"[CoreSetHack]";

// ------------------------------- 日志 ---------------------------------------

static void QXFileLog(NSString *msg)
{
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.qt.hacklog", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(q, ^{
        @autoreleasepool {
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"CoreSetHack.log"];
            NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:path]) {
                [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            } else {
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
                if (fh) {
                    @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
                    @finally { [fh closeFile]; }
                }
            }
        }
    });
}

static void QXLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!msg) return;
    NSLog(@"%@ %@", QXTag, msg);
    QXFileLog(msg);
}

// ------------------------------ 基础常量 -------------------------------------

// 目标接口所在的域名(注意:order.klpjwycb.xyz 是购买页,不碰)
static BOOL QXIsAPIHost(NSString *host)
{
    if (host.length == 0) return NO;
    NSString *h = [host lowercaseString];
    return [h isEqualToString:@"api.klpjwycb.xyz"] || [h isEqualToString:@"test.klpjwycb.xyz"];
}

static NSString *QXZeroHash(void)
{
    static NSString *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [@"" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0]; });
    return h;
}

// 服务端用来表示"不放行"的状态值(从 App 二进制里挖出来的完整枚举)
static NSSet *QXDenyStates(void)
{
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"TOKEN_REJECTED", @"CLIENT_BUILD_REJECTED",
            @"PROCESSING_NOT_ACTIVE", @"PROCESSING_DISABLED",
            @"PROCESSING_UNAVAILABLE", @"PROCESSING_PAUSED",
            @"PROCESSING_NOT_REQUIRED",
            @"UNAUTHORIZED", @"UNKNOWN", @"EXPIRED",
            @"CLAIM_EXPIRED", @"CLAIM_CARD_INVALID", @"CLAIM_OWNER_CHANGED", @"CLAIM_NOT_OWNED",
            @"INVALID_RESPONSE", @"INVALID_REQUEST", @"INVALID_CHALLENGE",
            @"RECOVERY_RETRY_LATER", @"RATE_LIMITED",
            @"CHALLENGE_EXPIRED_OR_USED", @"NEEDS_IDENTITY_BINDING",
            @"TOKEN_BINDING_REQUIRED", @"TOKEN_IDENTITY_REQUIRES_SPLIT",
            @"SUFFIX_CHANGE_REQUIRED", @"SPLIT_REQUIRED",
            @"DEVICE_KEY_UNAVAILABLE", @"NETWORK_UNAVAILABLE",
            @"runtime_policy_denied", @"missing_device_hash",
            @"invalid_policy_response", @"invalid_policy_url",
            @"policy_request_failed", @"policy_http_error",
            @"policy_parse_failed", @"invalid_policy_size",
        ]];
    });
    return set;
}

// 这些 key 的值如果是否/假,一律改成真
static BOOL QXKeyShouldBeTrue(NSString *key)
{
    if (key.length == 0) return NO;
    NSString *lk = [key lowercaseString];
    if ([lk isEqualToString:@"ok"] || [lk isEqualToString:@"isok"]) return YES;
    static NSArray *subs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        subs = @[ @"authorized", @"authorised", @"activated", @"activation", @"active",
                  @"valid", @"vip", @"allow", @"enable", @"unlock", @"licen",
                  @"success", @"paid", @"premium", @"subscri", @"entitle" ];
    });
    for (NSString *s in subs) {
        if ([lk containsString:s]) return YES;
    }
    return NO;
}

static BOOL QXKeyIsExpiry(NSString *key)
{
    if (key.length == 0) return NO;
    NSString *lk = [key lowercaseString];
    return [lk containsString:@"expire"] || [lk containsString:@"expiry"] ||
           [lk containsString:@"valid_until"] || [lk containsString:@"deadline"];
}

static const long long QXFarSec = 4102444800LL;      // 2100-01-01
static const long long QXFarMs  = 4102444800000LL;

// --------------------------- 伪造的服务端应答 ---------------------------------

static NSMutableDictionary *QXBasePayload(void)
{
    NSMutableDictionary *d = [@{
        @"code": @0,
        @"errcode": @0,
        @"errno": @0,
        @"status": @"ACTIVE",
        @"state": @"ACTIVE",
        @"result": @"ACTIVE",
        @"authorization_state": @"ACTIVE",
        @"authorization_mode": @"ACTIVE",
        @"phase": @"ACTIVE",
        @"claim": @"ACKNOWLEDGED",
        @"claim_status": @"ACKNOWLEDGED",
        @"allow": @YES,
        @"allowed": @YES,
        @"ok": @YES,
        @"success": @YES,
        @"active": @YES,
        @"activated": @YES,
        @"authorized": @YES,
        @"valid": @YES,
        @"vip": @YES,
        @"is_vip": @YES,
        @"reason": @"",
        @"message": @"ok",
        @"msg": @"ok",
        @"expires": @(QXFarSec),
        @"expire_at": @(QXFarSec),
        @"expires_at": @(QXFarSec),
        @"expiresAt": @(QXFarSec),
        @"expireTime": @(QXFarSec),
        @"expiresAtMs": @(QXFarMs),
        @"expires_at_ms": @(QXFarMs),
        @"expires_at_text": @"2099-12-31 23:59:59",
        @"device_hash": QXZeroHash(),
        @"device_id": QXZeroHash(),
        @"feature_mask": @(-1),
        @"profile_id": @"local",
        @"max_bootstrap_seconds": @86400,
    } mutableCopy];
    return d;
}

// 从请求体里把 card=xxxx 抠出来回显(有些流程会校验应答里的卡密一致)
static NSString *QXExtractCard(NSURLRequest *req)
{
    NSData *body = req.HTTPBody;
    if (body.length == 0) return nil;
    NSString *s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (s.length == 0) return nil;
    for (NSString *pair in [s componentsSeparatedByString:@"&"]) {
        NSRange r = [pair rangeOfString:@"="];
        if (r.location == NSNotFound) continue;
        NSString *k = [pair substringToIndex:r.location];
        if ([k isEqualToString:@"card"] || [k isEqualToString:@"card_key"] || [k isEqualToString:@"code"]) {
            return [pair substringFromIndex:r.location + 1];
        }
    }
    return nil;
}

static NSData *QXPayloadForRequest(NSURLRequest *req)
{
    NSString *path = [[req.URL path] lowercaseString];
    if (path.length == 0) path = @"/";
    NSURLComponents *comp = [NSURLComponents componentsWithURL:req.URL resolvingAgainstBaseURL:NO];

    NSMutableDictionary *core = QXBasePayload();

    if ([path containsString:@"regist2cardunlimit"] || [path containsString:@"card"]) {
        NSString *card = QXExtractCard(req);
        if (card.length) {
            core[@"card"] = card;
            core[@"card_key"] = card;
        }
        core[@"claim"] = @"ACKNOWLEDGED";
        core[@"issue"] = @"ACKNOWLEDGED";
        core[@"state"] = @"ACTIVE";
    }
    if ([path containsString:@"startup"]) {
        core[@"processing"] = @"ACTIVE";
        core[@"startup"] = @"ACTIVE";
        core[@"state"] = @"ACTIVE";
    }
    if ([path containsString:@"identity"]) {
        core[@"identity"] = @"ACTIVE";
        core[@"binding"] = @"BOUND";
        core[@"state"] = @"ACTIVE";
    }
    if ([path containsString:@"hash-list"]) {
        core[@"list"] = @[];
        core[@"device_hash_list"] = @[];
        core[@"matched"] = @NO;          // 不在黑名单里 = 放行
        core[@"state"] = @"ACTIVE";
    }
    if (path.length) core[@"path"] = path;
    if (comp.query.length) core[@"query"] = comp.query;

    // 顶层 / data / result / payload 四处都塞一份,App 读哪个都能读到
    NSMutableDictionary *root = [core mutableCopy];
    root[@"data"] = core;
    root[@"result"] = core;
    root[@"payload"] = core;
    root[@"body"] = core;
    root[@"content"] = core;

    NSError *err = nil;
    NSData *out = [NSJSONSerialization dataWithJSONObject:root options:0 error:&err];
    if (!out) {
        out = [@"{\"code\":0,\"state\":\"ACTIVE\",\"status\":\"ACTIVE\",\"success\":true}" dataUsingEncoding:NSUTF8StringEncoding];
    }
    return out;
}

// ======================= [1] NSURLProtocol 假服务器 ==========================

@interface QXFakeProtocol : NSURLProtocol
@end

@implementation QXFakeProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    @try {
        NSString *scheme = [[request.URL scheme] lowercaseString];
        if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
        if (!QXIsAPIHost(request.URL.host)) return NO;
        if ([NSURLProtocol propertyForKey:@"QXFakeHandled" inRequest:request]) return NO;
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b
{
    return NO;
}

- (void)startLoading
{
    NSURLRequest *req = self.request;
    NSData *body = QXPayloadForRequest(req);
    QXLog(@"[假服务器] 拦截 %@ %@ -> 200 ACTIVE (%lu bytes)",
          req.HTTPMethod ?: @"GET", req.URL.absoluteString ?: @"", (unsigned long)body.length);

    NSDictionary *headers = @{
        @"Content-Type": @"application/json; charset=utf-8",
        @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length],
        @"Server": @"nginx",
        @"Connection": @"close",
        @"Cache-Control": @"no-store",
    };
    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:req.URL
                                                          statusCode:200
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:headers];
    id<NSURLProtocolClient> client = self.client;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            [client URLProtocol:self didLoadData:body];
            [client URLProtocolDidFinishLoading:self];
        } @catch (NSException *e) {
            QXLog(@"[假服务器] 回调异常: %@", e);
        }
    });
}

- (void)stopLoading { }

@end

// ======================= [2] JSON 净化 ======================================

static id QXSanitize(id obj, NSUInteger depth);

static id QXSanitizeValue(NSString *key, id value, NSUInteger depth)
{
    if (value == nil) return nil;

    if ([value isKindOfClass:[NSString class]]) {
        NSString *sv = (NSString *)value;
        if (sv.length && [QXDenyStates() containsObject:[sv uppercaseString]]) {
            QXLog(@"[净化] %@: \"%@\" -> \"ACTIVE\"", key.length ? key : @"(item)", sv);
            return @"ACTIVE";
        }
        return sv;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *n = (NSNumber *)value;
        const char *t = [n objCType];
        BOOL isBool = (t != NULL && (t[0] == 'c' || t[0] == 'B'));
        int iv = [n intValue];
        if (QXKeyShouldBeTrue(key) && (isBool || iv == 0 || iv == 1) && ![n boolValue]) {
            QXLog(@"[净化] %@: %@ -> 1", key.length ? key : @"(item)", n);
            return @YES;
        }
        if (QXKeyIsExpiry(key)) {
            double d = [n doubleValue];
            if (d > 0 && d < (double)QXFarSec) {
                return (d > 1e11) ? @(QXFarMs) : @(QXFarSec);
            }
        }
        return n;
    }

    if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]]) {
        return QXSanitize(value, depth + 1);
    }
    return value;
}

static id QXSanitize(id obj, NSUInteger depth)
{
    if (obj == nil || depth > 16) return obj;

    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *md;
        if ([obj isKindOfClass:[NSMutableDictionary class]]) {
            md = (NSMutableDictionary *)obj;
        } else {
            md = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary *)obj count]];
        }
        NSDictionary *src = (NSDictionary *)obj;
        for (id k in [src allKeys]) {
            id v = src[k];
            id nv = [k isKindOfClass:[NSString class]] ? QXSanitizeValue(k, v, depth)
                                                      : QXSanitize(v, depth + 1);
            if (nv != v) md[k] = nv;
            else if (![obj isKindOfClass:[NSMutableDictionary class]]) md[k] = v;
        }
        return md;
    }

    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *ma;
        if ([obj isKindOfClass:[NSMutableArray class]]) {
            ma = (NSMutableArray *)obj;
        } else {
            ma = [NSMutableArray arrayWithCapacity:[(NSArray *)obj count]];
        }
        NSArray *src = (NSArray *)obj;
        for (NSUInteger i = 0; i < src.count; i++) {
            id v = src[i];
            id nv = QXSanitizeValue(@"", v, depth);
            if ([obj isKindOfClass:[NSMutableArray class]]) {
                if (nv != v) ma[i] = (nv ?: [NSNull null]);
            } else {
                [ma addObject:(nv ?: [NSNull null])];
            }
        }
        return ma;
    }

    return QXSanitizeValue(@"", obj, depth);
}

#if QX_ENABLE_JSON_HOOK
static id (*gOrigJSONObject)(id, SEL, NSData *, NSJSONReadingOptions, NSError **) = NULL;

static id QXHookJSONObject(id self, SEL _cmd, NSData *data, NSJSONReadingOptions opt, NSError **err)
{
    id obj = gOrigJSONObject ? gOrigJSONObject(self, _cmd, data, opt, err) : nil;
    if (obj == nil) return nil;
    @try {
        return QXSanitize(obj, 0);
    } @catch (NSException *e) {
        QXLog(@"[净化] 异常,放行原对象: %@", e);
        return obj;
    }
}
#endif

// ======================= [3] WebSocket 过滤(可选) ===========================

#if QX_ENABLE_WS_FILTER
static void (*gOrigRecvMsg)(id, SEL, void (^)(id, NSError *)) = NULL;

static BOOL QXTextHasDeny(NSString *text)
{
    if (text.length == 0) return NO;
    NSString *up = [text uppercaseString];
    for (NSString *s in QXDenyStates()) {
        if ([up containsString:[s uppercaseString]]) return YES;
    }
    return NO;
}

static void QXHookRecvMsg(id self, SEL _cmd, void (^handler)(id, NSError *))
{
    if (handler == nil) {
        if (gOrigRecvMsg) gOrigRecvMsg(self, _cmd, handler);
        return;
    }
    void (^wrapped)(id, NSError *) = ^(id msg, NSError *err) {
        @try {
            NSString *text = nil;
            if ([msg isKindOfClass:[NSString class]]) {
                text = msg;
            } else if ([msg respondsToSelector:NSSelectorFromString(@"data")]) {
                id d = [(id)msg valueForKey:@"data"];
                if ([d isKindOfClass:[NSData class]]) {
                    text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                }
            }
            if (QXTextHasDeny(text)) {
                QXLog(@"[WS] 吞掉否决消息: %@", text);
                return;
            }
        } @catch (NSException *e) { }
        handler(msg, err);
    };
    if (gOrigRecvMsg) gOrigRecvMsg(self, _cmd, wrapped);
}
#endif

// ======================= [4] 激活回调兜底 ====================================

#if QX_ENABLE_FINISH_HOOK
static void (*gOrigFinishB)(id, SEL, id, BOOL, id, id) = NULL;
static void (*gOrigFinishO)(id, SEL, id, id, id, id)   = NULL;

static void QXHookFinishB(id self, SEL _cmd, id a1, BOOL auth, id a3, id a4)
{
    QXLog(@"[兜底] %@ 命中,强制 authorized=YES", NSStringFromClass(object_getClass(self)) ?: @"?");
    if (gOrigFinishB) gOrigFinishB(self, _cmd, a1, YES, a3, a4);
}

static void QXHookFinishO(id self, SEL _cmd, id a1, id auth, id a3, id a4)
{
    QXLog(@"[兜底] %@ 命中,替换 authorized=@YES", NSStringFromClass(object_getClass(self)) ?: @"?");
    if (gOrigFinishO) gOrigFinishO(self, _cmd, a1, @YES, a3, a4);
}

static void QXInstallFinishHook(void)
{
    SEL sel = NSSelectorFromString(@"finish:authorized:message:expiresAt:");
    if (sel == NULL) return;

    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    if (list == NULL) return;

    NSMutableSet *done = [NSMutableSet set];
    int installed = 0;

    for (unsigned int i = 0; i < count; i++) {
        Class c = list[i];
        if (c == Nil) continue;
        if (!class_respondsToSelector(c, sel)) continue;

        Method m = class_getInstanceMethod(c, sel);
        if (m == NULL) continue;

        NSValue *mv = [NSValue valueWithPointer:(const void *)m];
        if ([done containsObject:mv]) continue;
        [done addObject:mv];

        @try {
            NSMethodSignature *sig = [c instanceMethodSignatureForSelector:sel];
            if (sig.numberOfArguments < 6) continue;
            const char *at = [sig getArgumentTypeAtIndex:3];
            if (at == NULL) continue;

            if (at[0] == '@') {
                gOrigFinishO = (void (*)(id, SEL, id, id, id, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)QXHookFinishO);
                installed++;
                QXLog(@"[兜底] 已挂钩 %s (对象参数)", class_getName(c));
            } else if (at[0] == 'c' || at[0] == 'B' || at[0] == 'i' || at[0] == 's' ||
                       at[0] == 'l' || at[0] == 'q' || at[0] == 'I' || at[0] == 'Q') {
                gOrigFinishB = (void (*)(id, SEL, id, BOOL, id, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)QXHookFinishB);
                installed++;
                QXLog(@"[兜底] 已挂钩 %s (布尔参数)", class_getName(c));
            }
        } @catch (NSException *e) {
            QXLog(@"[兜底] 挂 %s 失败: %@", class_getName(c), e);
        }
    }

    free(list);
    QXLog(@"[兜底] 共挂钩 %d 处", installed);
}
#endif

// ======================= [配置守护] =========================================

#if QX_ENABLE_CONF_GUARD
static void (*gOrigSetProtocolClasses)(id, SEL, NSArray *) = NULL;

static void QXHookSetProtocolClasses(id self, SEL _cmd, NSArray *classes)
{
    @try {
        Class ours = [QXFakeProtocol class];
        NSMutableArray *list = classes ? [classes mutableCopy] : [NSMutableArray array];
        if (![list containsObject:ours]) {
            [list insertObject:ours atIndex:0];
        }
        if (gOrigSetProtocolClasses) gOrigSetProtocolClasses(self, _cmd, list);
    } @catch (NSException *e) {
        if (gOrigSetProtocolClasses) gOrigSetProtocolClasses(self, _cmd, classes);
    }
}
#endif

// ======================= [5] 二进制指令补丁(默认关) =========================

#if QX_ENABLE_TEXT_PATCH
static void QXTryTextPatch(void)
{
    const struct mach_header_64 *hdr = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (i == 0) { hdr = (const struct mach_header_64 *)_dyld_get_image_header(i); break; }
    }
    if (hdr == NULL) return;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    uintptr_t addr = (uintptr_t)QX_PATCH_ADDR + (uintptr_t)slide;

    uint32_t cur = 0;
    memcpy(&cur, (const void *)addr, sizeof(cur));
    QXLog(@"[补丁] 目标地址 0x%lx 当前指令 0x%08x", (unsigned long)addr, cur);

    uintptr_t page = addr & ~(uintptr_t)0x3FFFu;
    if (mprotect((void *)page, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
        QXLog(@"[补丁] 代码页不可写(未越狱常见),跳过");
        return;
    }
    uint32_t op = QX_PATCH_OPCODE;
    memcpy((void *)addr, &op, sizeof(op));
    mprotect((void *)page, 0x4000, PROT_READ | PROT_EXEC);
    QXLog(@"[补丁] 已写入 0x%08x", op);
}
#endif

// ============================== 初始化 ======================================

__attribute__((constructor))
static void QXInit(void)
{
    @autoreleasepool {
        QXLog(@"=== CoreSetHack 开始加载 (pid %d) ===", getpid());

        // [1] 注册假协议 —— 必须在任何网络请求发生之前
        @try {
            [NSURLProtocol registerClass:[QXFakeProtocol class]];
            QXLog(@"[假服务器] NSURLProtocol 已注册");
        } @catch (NSException *e) {
            QXLog(@"[假服务器] 注册失败: %@", e);
        }

#if QX_ENABLE_CONF_GUARD
        @try {
            Class cfg = objc_getClass("NSURLSessionConfiguration");
            if (cfg) {
                Method m = class_getInstanceMethod(cfg, @selector(setProtocolClasses:));
                if (m) {
                    gOrigSetProtocolClasses = (void (*)(id, SEL, NSArray *))method_getImplementation(m);
                    method_setImplementation(m, (IMP)QXHookSetProtocolClasses);
                    QXLog(@"[配置守护] 已挂钩 protocolClasses");
                }
            }
        } @catch (NSException *e) {
            QXLog(@"[配置守护] 失败: %@", e);
        }
#endif

#if QX_ENABLE_JSON_HOOK
        @try {
            Class cls = objc_getClass("NSJSONSerialization");
            if (cls) {
                Method m = class_getClassMethod(cls, @selector(JSONObjectWithData:options:error:));
                if (m) {
                    gOrigJSONObject = (id (*)(id, SEL, NSData *, NSJSONReadingOptions, NSError **))method_getImplementation(m);
                    method_setImplementation(m, (IMP)QXHookJSONObject);
                    QXLog(@"[净化] NSJSONSerialization 已挂钩");
                }
            }
        } @catch (NSException *e) {
            QXLog(@"[净化] 挂钩失败: %@", e);
        }
#endif

#if QX_ENABLE_WS_FILTER
        @try {
            Class ws = objc_getClass("NSURLSessionWebSocketTask");
            if (ws) {
                Method m = class_getInstanceMethod(ws, @selector(receiveMessageWithCompletionHandler:));
                if (m) {
                    gOrigRecvMsg = (void (*)(id, SEL, void (^)(id, NSError *)))method_getImplementation(m);
                    method_setImplementation(m, (IMP)QXHookRecvMsg);
                    QXLog(@"[WS] 已挂钩");
                }
            }
        } @catch (NSException *e) {
            QXLog(@"[WS] 挂钩失败: %@", e);
        }
#endif

        // [4] 激活回调兜底 —— 等 ObjC 类都注册好再挂,挂两次保证不漏
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
#if QX_ENABLE_FINISH_HOOK
            @try { QXInstallFinishHook(); } @catch (NSException *e) { QXLog(@"[兜底] 异常 %@", e); }
#endif
#if QX_ENABLE_TEXT_PATCH
            @try { QXTryTextPatch(); } @catch (NSException *e) { QXLog(@"[补丁] 异常 %@", e); }
#endif
#if QX_SHOW_ALERT
            @try {
                Class alertCls = objc_getClass("UIAlertController");
                if (alertCls) {
                    id alert = ((id (*)(id, SEL, id, id, id))objc_msgSend)((id)alertCls,
                                 NSSelectorFromString(@"alertControllerWithTitle:message:preferredStyle:"),
                                 @"CoreSetHack", @"已注入并生效", (id)1);
                    id win = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UIApplication"),
                                 NSSelectorFromString(@"sharedApplication"));
                    win = ((id (*)(id, SEL))objc_msgSend)(win, NSSelectorFromString(@"keyWindow"));
                    id vc = ((id (*)(id, SEL))objc_msgSend)(win, NSSelectorFromString(@"rootViewController"));
                    if (vc) ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(vc,
                                 NSSelectorFromString(@"presentViewController:animated:completion:"), alert, YES, nil);
                }
            } @catch (NSException *e) { }
#endif
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
#if QX_ENABLE_FINISH_HOOK
            @try { QXInstallFinishHook(); } @catch (NSException *e) { }
#endif
        });

        QXLog(@"=== CoreSetHack 加载完成 ===");
    }
}
