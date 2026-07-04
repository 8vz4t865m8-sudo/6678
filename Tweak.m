//
//  MyRadarExtract.m - Method Swizzling 版（最安全）
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static BOOL g_extracted = NO;

// 新方法
static id extracted_httpResponseForRelativePath(id self, SEL _cmd, NSString *relativePath, NSString *gameKey) {
    // 调用原始方法（通过 objc_msgSend 直接调用原始 SEL）
    id response = ((id(*)(id, SEL, NSString*, NSString*))objc_msgSend)(self, _cmd, relativePath, gameKey);
    
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

__attribute__((constructor))
static void extract_init() {
    NSLog(@"========================================");
    NSLog(@"[Extract] 前端资源提取器已加载");
    NSLog(@"========================================");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Class cls = objc_getClass("ViewController");
        if (!cls) { NSLog(@"[Extract] 找不到 ViewController"); return; }
        
        SEL origSel = @selector(httpResponseForRelativePath:gameKey:);
        SEL newSel = @selector(extracted_httpResponseForRelativePath:gameKey:);
        
        // 添加新方法
        BOOL added = class_addMethod(cls, newSel, (IMP)extracted_httpResponseForRelativePath, "@@:@@");
        if (!added) {
            NSLog(@"[Extract] 添加方法失败，可能已经存在");
            return;
        }
        
        // 交换实现
        Method origMethod = class_getInstanceMethod(cls, origSel);
        Method newMethod = class_getInstanceMethod(cls, newSel);
        method_exchangeImplementations(origMethod, newMethod);
        
        NSLog(@"[Extract] Method Swizzling 完成，请访问本地雷达");
    });
}
