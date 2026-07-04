//
//  MyRadarExtract.m - 终极版：双保险提取
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// 全局状态
// ============================================================
static BOOL g_extracted = NO;

// ============================================================
// 方案 A：Hook GCDWebServerDataResponse 类方法
// ============================================================

static id (*g_orig_responseWithData)(id, SEL, NSData*, NSString*) = NULL;
static id (*g_orig_responseWithHTML)(id, SEL, NSString*) = NULL;

static NSString* getExtractDir() {
    NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *extractDir = [docs stringByAppendingPathComponent:@"MyRadarExtracted"];
    [[NSFileManager defaultManager] createDirectoryAtPath:extractDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return extractDir;
}

static id new_responseWithData(id self, SEL _cmd, NSData *data, NSString *contentType) {
    id response = g_orig_responseWithData(self, _cmd, data, contentType);
    
    if (!g_extracted && data && data.length > 0) {
        NSString *ext = @"bin";
        if ([contentType containsString:@"html"]) ext = @"html";
        else if ([contentType containsString:@"javascript"]) ext = @"js";
        else if ([contentType containsString:@"css"]) ext = @"css";
        else if ([contentType containsString:@"png"]) ext = @"png";
        else if ([contentType containsString:@"jpeg"]) ext = @"jpg";
        
        NSString *filename = [NSString stringWithFormat:@"A_%@.%@",
                             [NSNumber numberWithLongLong:(long long)(CFAbsoluteTimeGetCurrent()*1000)], ext];
        
        NSString *savePath = [getExtractDir() stringByAppendingPathComponent:filename];
        BOOL ok = [data writeToFile:savePath atomically:YES];
        NSLog(@"[Extract] A方案 %@: %@ (%lu bytes)", ok ? @"✅" : @"❌", filename, (unsigned long)data.length);
    }
    
    return response;
}

static id new_responseWithHTML(id self, SEL _cmd, NSString *html) {
    id response = g_orig_responseWithHTML(self, _cmd, html);
    
    if (!g_extracted && html && html.length > 0) {
        NSData *data = [html dataUsingEncoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithFormat:@"A_%@.html",
                             [NSNumber numberWithLongLong:(long long)(CFAbsoluteTimeGetCurrent()*1000)]];
        
        NSString *savePath = [getExtractDir() stringByAppendingPathComponent:filename];
        BOOL ok = [data writeToFile:savePath atomically:YES];
        NSLog(@"[Extract] A方案 %@: %@ (%lu bytes)", ok ? @"✅" : @"❌", filename, (unsigned long)data.length);
    }
    
    return response;
}

// ============================================================
// 方案 B：Hook NSData writeToFile（保底，任何写入都能拦截）
// ============================================================

static BOOL (*g_orig_writeToFile)(id, SEL, NSString*, BOOL) = NULL;

static BOOL new_writeToFile(id self, SEL _cmd, NSString *path, BOOL atomically) {
    // 调用原始方法
    BOOL result = g_orig_writeToFile(self, _cmd, path, atomically);
    
    // 如果写入的是 APP 自己的缓存目录（GCDWebServer 的临时文件），复制一份到提取目录
    if (result && [path containsString:@"/tmp/"] && [path containsString:@"GCDWebServer"]) {
        NSString *filename = [path lastPathComponent];
        NSString *ext = filename.pathExtension;
        if ([ext isEqualToString:@"html"] || [ext isEqualToString:@"js"] || [ext isEqualToString:@"css"] ||
            [ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"]) {
            
            NSString *newName = [NSString stringWithFormat:@"B_%@.%@",
                                  [NSNumber numberWithLongLong:(long long)(CFAbsoluteTimeGetCurrent()*1000)], ext];
            NSString *savePath = [getExtractDir() stringByAppendingPathComponent:newName];
            
            [self writeToFile:savePath atomically:YES];
            NSLog(@"[Extract] B方案 ✅ 从缓存复制: %@ -> %@", filename, newName);
        }
    }
    
    return result;
}

// ============================================================
// 方案 C：Hook GCDWebServer 的 addGETHandler（最底层）
// ============================================================

static void (*g_orig_addGETHandler)(id, SEL, NSString*, id, NSString*, NSUInteger) = NULL;

static void new_addGETHandler(id self, SEL _cmd, NSString *path, NSData *staticData, NSString *contentType, NSUInteger cacheAge) {
    // 提取静态数据
    if (staticData && staticData.length > 0) {
        NSString *ext = path.pathExtension;
        if (ext.length == 0) {
            if ([contentType containsString:@"html"]) ext = @"html";
            else if ([contentType containsString:@"javascript"]) ext = @"js";
            else if ([contentType containsString:@"css"]) ext = @"css";
        }
        
        NSString *filename = [NSString stringWithFormat:@"C_%@_%@",
                             [path lastPathComponent],
                             [NSNumber numberWithLongLong:(long long)(CFAbsoluteTimeGetCurrent()*1000)]];
        
        NSString *savePath = [getExtractDir() stringByAppendingPathComponent:filename];
        [staticData writeToFile:savePath atomically:YES];
        NSLog(@"[Extract] C方案 ✅ %@ (%lu bytes)", filename, (unsigned long)staticData.length);
    }
    
    // 调用原始方法
    g_orig_addGETHandler(self, _cmd, path, staticData, contentType, cacheAge);
}

// ============================================================
// 初始化
// ============================================================
static void initHooks() {
    NSLog(@"[Extract] 开始初始化...");
    NSLog(@"[Extract] 沙盒目录: %@", getExtractDir());
    
    Class responseClass = objc_getClass("GCDWebServerDataResponse");
    if (responseClass) {
        SEL sel1 = @selector(responseWithData:contentType:);
        Method m1 = class_getClassMethod(responseClass, sel1);
        if (m1) {
            g_orig_responseWithData = (id (*)(id, SEL, NSData*, NSString*))method_getImplementation(m1);
            method_setImplementation(m1, (IMP)new_responseWithData);
            NSLog(@"[Extract] A方案已启用: responseWithData:");
        }
        
        SEL sel2 = @selector(responseWithHTML:);
        Method m2 = class_getClassMethod(responseClass, sel2);
        if (m2) {
            g_orig_responseWithHTML = (id (*)(id, SEL, NSString*))method_getImplementation(m2);
            method_setImplementation(m2, (IMP)new_responseWithHTML);
            NSLog(@"[Extract] A方案已启用: responseWithHTML:");
        }
    }
    
    // B方案：Hook NSData writeToFile
    Class dataClass = [NSData class];
    SEL writeSel = @selector(writeToFile:atomically:);
    Method writeMethod = class_getInstanceMethod(dataClass, writeSel);
    if (writeMethod) {
        g_orig_writeToFile = (BOOL (*)(id, SEL, NSString*, BOOL))method_getImplementation(writeMethod);
        method_setImplementation(writeMethod, (IMP)new_writeToFile);
        NSLog(@"[Extract] B方案已启用: NSData writeToFile:");
    }
    
    // C方案：Hook GCDWebServer addGETHandler
    Class serverClass = objc_getClass("GCDWebServer");
    if (serverClass) {
        SEL handlerSel = @selector(addGETHandlerForPath:staticData:contentType:cacheAge:);
        Method handlerMethod = class_getInstanceMethod(serverClass, handlerSel);
        if (handlerMethod) {
            g_orig_addGETHandler = (void (*)(id, SEL, NSString*, id, NSString*, NSUInteger))method_getImplementation(handlerMethod);
            method_setImplementation(handlerMethod, (IMP)new_addGETHandler);
            NSLog(@"[Extract] C方案已启用: addGETHandler");
        }
    }
    
    NSLog(@"[Extract] 三保险提取器已加载，请访问本地雷达");
}

__attribute__((constructor))
static void extract_init() {
    NSLog(@"========================================");
    NSLog(@"[Extract] 前端资源提取器 v5 三保险版");
    NSLog(@"========================================");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        initHooks();
    });
}
