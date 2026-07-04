//
//  MyRadarExtract.m - 正确版：Hook GCDWebServerDataResponse
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// 全局状态
// ============================================================
static BOOL g_extracted = NO;

// ============================================================
// 提取逻辑：Hook GCDWebServerDataResponse 的初始化
// ============================================================

// 原始方法
static id (*g_orig_initWithData)(id, SEL, NSData*, NSString*) = NULL;
static id (*g_orig_initWithHTML)(id, SEL, NSString*) = NULL;

// 新的 initWithData:contentType:
static id new_initWithDataContentType(id self, SEL _cmd, NSData *data, NSString *contentType) {
    // 调用原始方法
    id response = g_orig_initWithData(self, _cmd, data, contentType);
    
    // 提取数据
    if (!g_extracted && data && data.length > 0) {
        // 根据 contentType 判断文件类型
        NSString *ext = @"bin";
        if ([contentType containsString:@"html"]) ext = @"html";
        else if ([contentType containsString:@"javascript"]) ext = @"js";
        else if ([contentType containsString:@"css"]) ext = @"css";
        else if ([contentType containsString:@"png"]) ext = @"png";
        else if ([contentType containsString:@"jpeg"]) ext = @"jpg";
        
        // 生成文件名（用时间戳避免冲突）
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

// 新的 initWithHTML:
static id new_initWithHTML(id self, SEL _cmd, NSString *html) {
    id response = g_orig_initWithHTML(self, _cmd, html);
    
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
    
    // Hook initWithData:contentType:
    SEL sel1 = @selector(initWithData:contentType:);
    Method m1 = class_getInstanceMethod(responseClass, sel1);
    if (m1) {
        g_orig_initWithData = (id (*)(id, SEL, NSData*, NSString*))method_getImplementation(m1);
        method_setImplementation(m1, (IMP)new_initWithDataContentType);
        NSLog(@"[Extract] Hook: initWithData:contentType:");
    }
    
    // Hook initWithHTML:（如果有的话）
    SEL sel2 = @selector(initWithHTML:);
    Method m2 = class_getInstanceMethod(responseClass, sel2);
    if (m2) {
        g_orig_initWithHTML = (id (*)(id, SEL, NSString*))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)new_initWithHTML);
        NSLog(@"[Extract] Hook: initWithHTML:");
    }
    
    NSLog(@"[Extract] 提取 hook 已加载，请访问本地雷达触发加载");
}

__attribute__((constructor))
static void extract_init() {
    NSLog(@"========================================");
    NSLog(@"[Extract] 前端资源提取器 v2 已加载");
    NSLog(@"[Extract] 原理：Hook GCDWebServerDataResponse");
    NSLog(@"========================================");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        initHooks();
    });
}
