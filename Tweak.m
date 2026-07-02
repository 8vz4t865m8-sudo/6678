// Tweak.m - 不用 substrate
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#define NEW_IP @"162.14.104.134"

// 替换 directWatchUrl
static NSString *hook_directWatchUrl(id self, SEL _cmd) {
    return [NSString stringWithFormat:@"http://%@/?game=dfm", NEW_IP];
}

// 替换 publishWsUrl  
static NSString *hook_publishWsUrl(id self, SEL _cmd) {
    return [NSString stringWithFormat:@"ws://%@/ws?role=publisher&room=default", NEW_IP];
}

// 替换 URLWithString
static NSURL *hook_URLWithString(id self, SEL _cmd, NSString *URLString) {
    if ([URLString containsString:@"210.16.163.46"]) {
        URLString = [URLString stringByReplacingOccurrencesOfString:@"210.16.163.46" withString:NEW_IP];
        URLString = [URLString stringByReplacingOccurrencesOfString:@":93" withString:@""];
    }
    return ((NSURL *(*)(id, SEL, NSString *))class_getMethodImplementation([NSURL class], _cmd))(self, _cmd, URLString);
}

__attribute__((constructor))
static void init() {
    Class relay = objc_getClass("MRCloudRelay");
    if (relay) {
        method_setImplementation(class_getInstanceMethod(relay, @selector(directWatchUrl)), (IMP)hook_directWatchUrl);
        method_setImplementation(class_getInstanceMethod(relay, @selector(publishWsUrl)), (IMP)hook_publishWsUrl);
    }
    
    Class urlClass = [NSURL class];
    method_setImplementation(class_getClassMethod(urlClass, @selector(URLWithString:)), (IMP)hook_URLWithString);
}
