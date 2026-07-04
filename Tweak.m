//
//  MyRadarExtract.m - 只保留提取功能
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// 前置声明（修复 undeclared function 错误）
// ============================================================
static void hookMethod(const char *className, SEL sel, IMP newImp, IMP *oldImp);

// ============================================================
// 全局状态
// ============================================================
static BOOL g_extracted = NO;

// ============================================================
// 工具函数
// ============================================================
static void hookMethod(const char *className, SEL sel, IMP newImp, IMP *oldImp) {
    Class cls = objc_getClass(className);
    if (!cls) { NSLog(@"[Extract] 找不到类: %s", className); return; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NSLog(@"[Extract] 找不到方法: %s", sel_getName(sel)); return; }
    if (oldImp) *oldImp = method_getImplementation(m);
    method_setImplementation(m, newImp);
    NSLog(@"[Extract] Hook: %s", sel_getName(sel));
}

// ============================================================
// 提取逻辑
// ============================================================
static id hook_httpResponseForRelativePath(id self, SEL _cmd, NSString *relativePath, NSString *gameKey) {
    // 调用原始方法获取响应
    Class vcClass = [self class];
    Method m = class_getInstanceMethod(vcClass, _cmd);
    IMP origImp = method_getImplementation(m);
    id response = ((id(*)(id, SEL, NSString*, NSString*))origImp)(self, _cmd, relativePath, gameKey);
    
    if (!g_extracted && response) {
        NSData *data = nil;
        
        if ([response respondsToSelector:@selector(data)]) {
            data = ((id(*)(id, SEL))objc_msgSend)(response, @selector(data));
        } else if ([response respondsToSelector:@selector(filePath)]) {
            NSString *filePath = ((id(*)(id, SEL))objc_msgSend)(response, @selector(filePath));
            data = [NSData dataWithContentsOfFile:filePath];
        }
        
        if (data && data.length > 0) {
            NSString *baseDir = @"/var/mobile/Documents/MyRadarExtracted";
            NSString *savePath = [baseDir stringByAppendingPathComponent:relativePath];
            NSString *saveDir = [savePath stringByDeletingLastPathComponent];
            
            [[NSFileManager defaultManager] createDirectoryAtPath:saveDir 
                                      withIntermediateDirectories:YES 
                                                       attributes:nil 
                                                            error:nil];
            
            [data writeToFile:savePath atomically:YES];
            NSLog(@"[Extract] ✅ %@ (%lu bytes)", relativePath, (unsigned long)data.length);
        }
    }
    
    return response;
}

// ============================================================
// 初始化
// ============================================================
static void initHooks() {
    NSLog(@"[Extract] 开始初始化...");
    hookMethod("ViewController", @selector(httpResponseForRelativePath:gameKey:), 
               (IMP)hook_httpResponseForRelativePath, NULL);
    NSLog(@"[Extract] 提取 hook 已加载，请访问本地雷达触发加载");
}

__attribute__((constructor))
static void extract_init() {
    NSLog(@"========================================");
    NSLog(@"[Extract] 前端资源提取器已加载");
    NSLog(@"========================================");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        initHooks();
    });
}
