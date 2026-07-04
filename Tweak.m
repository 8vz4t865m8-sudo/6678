//
//  MyRadarExtract.m - 修复版：Hook 类方法
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// 全局状态
// ============================================================
static BOOL g_extracted = NO;

// ============================================================
// 提取逻辑：Hook 类方法 +[GCDWebServerDataResponse responseWithData:contentType:]
// ============================================================

// 原始类方法
static id (*g_orig_responseWithData)(id, SEL, NSData*, NSString*) = NULL;
static id (*g_orig_responseWithHTML)(id, SEL, NSString*) = NULL;
static id (*g_orig_responseWithText)(id, SEL, NSString*) = NULL;

// 新的 +[GCDWebServerDataResponse responseWithData:contentType:]
static id new_responseWithData(id self, SEL _cmd, NSData *data, NSString *contentType) {
    // 调用原始类方法
    id response = g_orig_responseWithData(self, _cmd, data, contentType);
    
    // 提取数据
    if (!g_extracted && data && data.length > 0) {
        NSString *ext = @"bin";
        if ([contentType containsString:@"html"]) ext = @"html";
        else if ([contentType containsString:@"javascript"]) ext = @"js";
        else if ([contentType containsString:@"css"]) ext = @"css";
        else if ([contentType containsString:@"png"]) ext = @"png";
        else if ([contentType containsString:@"jpeg"]) ext = @"jpg";
        else if ([contentType containsString:@"json"]) ext = @"json";
        
        NSString *filename = [NSString stringWithFormat:@"resource_%@.%@",
                             [NSNumber numberWithLongLong:(long long)(CFAbsoluteTimeGetCurrent()*1000)], ext];
        
        NSString *baseDir = @"/var/mobile/Documents/MyRadarExtracted";
        NSString *savePath = [baseDir stringByAppendingPathComponent:filename];
        
        [[NSFileManager defaultManager] createDirectoryAtPath:baseDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        
        [data writeToFile:savePath atomically:YES];
        NSLog(@"[Extract] ✅ %@ (%lu bytes) type=%@", filename, (unsigned long)data.length, contentType);
    }
    
    return response;
}

// 新的 +[GCDWebServerDataResponse responseWithHTML:]
static id new_responseWithHTML(id self, SEL _cmd, NSString *html) {
    id response = g_orig_responseWithHTML(self, _cmd, html);
    
    if (!g_extracted && html && html.length > 0) {
        NSData *data = [html dataUsingEncoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithFormat:@"resource_%@.html",
                             [NSNumber numberWithLongLong:(long long)(CFAbsoluteTimeGetCurrent()*1000)]];
        
        NSString *baseDir = @"/var/mobile/Documents/MyRadarExtracted";
        NSString *savePath = [baseDir stringByAppendingPathComponent:filename];
        
        [[NSFileManager defaultManager] createDirectoryAtPath:baseDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        
        [data writeToFile:savePath atomically:YES];
        NSLog(@"[Extract] ✅ %@ (%lu bytes) type=text/html", filename, (unsigned long)data.length);
    }
    
    return response;
}

// 新的 +[GCDWebServerDataResponse responseWithText:]
static id new_responseWithText(id self, SEL _cmd, NSString *text) {
    id response = g_orig_responseWithText(self, _cmd, text);
    
    if (!g_extracted && text && text.length > 0) {
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithFormat:@"resource_%@.txt",
                             [NSNumber numberWithLongLong:(long long)(CFAbsoluteTimeGetCurrent()*1000)]];
        
        NSString *baseDir = @"/var/mobile/Documents/MyRadarExtracted";
        NSString *savePath = [baseDir stringByAppendingPathComponent:filename];
        
        [[NSFileManager defaultManager] createDirectoryAtPath:baseDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        
        [data writeToFile:savePath atomically:YES];
        NSLog(@"[Extract] ✅ %@ (%lu bytes) type=text/plain", filename, (unsigned long)data.length);
    }
    
    return response;
}

// ============================================================
// 初始化
// ============================================================
static void initHooks() {
    NSLog(@"[Extract] 开始初始化...");
    
    Class responseClass = objc_getClass("GCDWebServerDataResponse");
    if (!responseClass) {
        NSLog(@"[Extract] 找不到 GCDWebServerDataResponse");
        return;
    }
    
    // Hook +[GCDWebServerDataResponse responseWithData:contentType:]
    SEL sel1 = @selector(responseWithData:contentType:);
    Method m1 = class_getClassMethod(responseClass, sel1);
    if (m1) {
        g_orig_responseWithData = (id (*)(id, SEL, NSData*, NSString*))method_getImplementation(m1);
        method_setImplementation(m1, (IMP)new_responseWithData);
        NSLog(@"[Extract] Hook 类方法: +[GCDWebServerDataResponse responseWithData:contentType:]");
    } else {
        NSLog(@"[Extract] 找不到 +[GCDWebServerDataResponse responseWithData:contentType:]");
    }
    
    // Hook +[GCDWebServerDataResponse(Extensions) responseWithHTML:]
    SEL sel2 = @selector(responseWithHTML:);
    Method m2 = class_getClassMethod(responseClass, sel2);
    if (m2) {
        g_orig_responseWithHTML = (id (*)(id, SEL, NSString*))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)new_responseWithHTML);
        NSLog(@"[Extract] Hook 类方法: +[GCDWebServerDataResponse responseWithHTML:]");
    } else {
        NSLog(@"[Extract] 找不到 +[GCDWebServerDataResponse responseWithHTML:]");
    }
    
    // Hook +[GCDWebServerDataResponse(Extensions) responseWithText:]
    SEL sel3 = @selector(responseWithText:);
    Method m3 = class_getClassMethod(responseClass, sel3);
    if (m3) {
        g_orig_responseWithText = (id (*)(id, SEL, NSString*))method_getImplementation(m3);
        method_setImplementation(m3, (IMP)new_responseWithText);
        NSLog(@"[Extract] Hook 类方法: +[GCDWebServerDataResponse responseWithText:]");
    } else {
        NSLog(@"[Extract] 找不到 +[GCDWebServerDataResponse responseWithText:]");
    }
    
    NSLog(@"[Extract] 提取 hook 已加载，请访问本地雷达触发加载");
}

__attribute__((constructor))
static void extract_init() {
    NSLog(@"========================================");
    NSLog(@"[Extract] 前端资源提取器 v3 已加载");
    NSLog(@"[Extract] 原理：Hook GCDWebServerDataResponse 类方法");
    NSLog(@"========================================");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        initHooks();
    });
}
