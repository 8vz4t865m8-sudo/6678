//
//  MyRadarExtract.m - 专门用于提取内嵌前端资源
//  用法：替换掉你原来的 hook，启动 APP，另一台设备访问雷达页面，提取完成后换回原 hook
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static BOOL g_extracted = NO;

static id hook_httpResponseForRelativePath(id self, SEL _cmd, NSString *relativePath, NSString *gameKey) {
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

static void initHooks() {
    hookMethod("ViewController", @selector(httpResponseForRelativePath:gameKey:), 
               (IMP)hook_httpResponseForRelativePath, NULL);
    NSLog(@"[Extract] 提取 hook 已加载，请访问本地雷达触发加载");
}

__attribute__((constructor))
static void extract_init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        initHooks();
    });
}
