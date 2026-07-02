#import <objc/runtime.h>
#import <Foundation/Foundation.h>

// ========== 在这里改成你的服务器地址 ==========
// 可以是域名，也可以是IP
// 例如：@"example.com" 或 @"192.168.1.100"
#define NEW_DOMAIN @"162.14.104.134"

// 是否使用 HTTPS/WSS（如果你的网站有SSL证书就改成YES）
#define USE_HTTPS NO

// ============================================
// Hook publishWsUrl - App 上传数据用的 WebSocket 地址
// 原始地址：ws://210.16.163.46:93/loon
// 修改后：  ws://162.14.104.134/loon
// ============================================
static NSString *new_publishWsUrl(id self, SEL _cmd) {
    NSString *scheme = USE_HTTPS ? @"wss://" : @"ws://";
    return [NSString stringWithFormat:@"%@%@/loon", scheme, NEW_DOMAIN];
}

// ============================================
// Hook directWatchUrl - 网页观看地址
// 原始地址：http://210.16.163.46:93/loon/radar/?room=xxx
// 修改后：  http://162.14.104.134/?game=dfm&room=xxx
// ============================================
static NSString *new_directWatchUrl(id self, SEL _cmd) {
    NSString *scheme = USE_HTTPS ? @"https://" : @"http://";
    return [NSString stringWithFormat:@"%@%@/?game=dfm", scheme, NEW_DOMAIN];
}

// ============================================
// 可选：Hook mr_cloud_host / mr_cloud_port
// 如果 App 还有其他地方用到这些配置，也一起改掉
// ============================================
static NSString *new_cloudHost(id self, SEL _cmd) {
    return NEW_DOMAIN;
}

static NSNumber *new_cloudPort(id self, SEL _cmd) {
    return USE_HTTPS ? @443 : @80;
}

// ============================================
// 初始化 - 注入 Hook
// ============================================
__attribute__((constructor))
static void init() {
    NSLog(@"[MyRadar Hook] 加载中...");
    
    Class relay = objc_getClass("MRCloudRelay");
    if (!relay) {
        NSLog(@"[MyRadar Hook] 错误：找不到 MRCloudRelay 类");
        return;
    }
    
    // 1. Hook publishWsUrl
    Method orig1 = class_getInstanceMethod(relay, @selector(publishWsUrl));
    if (orig1) {
        class_addMethod(relay, @selector(new_publishWsUrl), (IMP)new_publishWsUrl, method_getTypeEncoding(orig1));
        Method new1 = class_getInstanceMethod(relay, @selector(new_publishWsUrl));
        method_exchangeImplementations(orig1, new1);
        NSLog(@"[MyRadar Hook] ✅ publishWsUrl Hook 成功");
    } else {
        NSLog(@"[MyRadar Hook] ⚠️  找不到 publishWsUrl 方法");
    }
    
    // 2. Hook directWatchUrl
    Method orig2 = class_getInstanceMethod(relay, @selector(directWatchUrl));
    if (orig2) {
        class_addMethod(relay, @selector(new_directWatchUrl), (IMP)new_directWatchUrl, method_getTypeEncoding(orig2));
        Method new2 = class_getInstanceMethod(relay, @selector(new_directWatchUrl));
        method_exchangeImplementations(orig2, new2);
        NSLog(@"[MyRadar Hook] ✅ directWatchUrl Hook 成功");
    } else {
        NSLog(@"[MyRadar Hook] ⚠️  找不到 directWatchUrl 方法");
    }
    
    // 3. 可选：Hook mr_cloud_host（如果存在的话）
    Method orig3 = class_getClassMethod(relay, @selector(mr_cloud_host));
    if (orig3) {
        class_addMethod(relay, @selector(new_cloudHost), (IMP)new_cloudHost, method_getTypeEncoding(orig3));
        Method new3 = class_getClassMethod(relay, @selector(new_cloudHost));
        method_exchangeImplementations(orig3, new3);
        NSLog(@"[MyRadar Hook] ✅ mr_cloud_host Hook 成功");
    }
    
    NSLog(@"[MyRadar Hook] 加载完成，目标服务器：%@", NEW_DOMAIN);
}
