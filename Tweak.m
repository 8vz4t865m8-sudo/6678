#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#define NEW_IP @"162.14.104.134"

// 新实现 - 直接返回新服务器地址
static NSString *new_publishWsUrl(id self, SEL _cmd) {
    return @"ws://" NEW_IP "/ws?role=publisher&room=default";
}

__attribute__((constructor))
static void init() {
    // 运行时获取 MRCloudRelay 类
    Class relay = objc_getClass("MRCloudRelay");
    if (!relay) return;
    
    // 获取原方法
    Method origMethod = class_getInstanceMethod(relay, @selector(publishWsUrl));
    if (!origMethod) return;
    
    // 添加新方法
    BOOL added = class_addMethod(relay, @selector(new_publishWsUrl), (IMP)new_publishWsUrl, method_getTypeEncoding(origMethod));
    
    if (added) {
        // 交换实现
        Method newMethod = class_getInstanceMethod(relay, @selector(new_publishWsUrl));
        method_exchangeImplementations(origMethod, newMethod);
    } else {
        // 如果添加失败，直接替换实现
        method_setImplementation(origMethod, (IMP)new_publishWsUrl);
    }
}
