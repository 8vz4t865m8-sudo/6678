#import <objc/runtime.h>
#import <substrate.h>

#define NEW_IP @"162.14.104.134"

static NSString *(*orig_directWatchUrl)(id, SEL);
static NSString *hook_directWatchUrl(id self, SEL _cmd) {
    return [NSString stringWithFormat:@"http://%@/?game=dfm", NEW_IP];
}

static NSString *(*orig_publishWsUrl)(id, SEL);
static NSString *hook_publishWsUrl(id self, SEL _cmd) {
    return [NSString stringWithFormat:@"ws://%@/ws?role=publisher&room=default", NEW_IP];
}

static NSURL *(*orig_URLWithString)(id, SEL, NSString *);
static NSURL *hook_URLWithString(id self, SEL _cmd, NSString *URLString) {
    URLString = [URLString stringByReplacingOccurrencesOfString:@"210.16.163.46" withString:NEW_IP];
    URLString = [URLString stringByReplacingOccurrencesOfString:@":93" withString:@""];
    return orig_URLWithString(self, _cmd, URLString);
}

__attribute__((constructor))
static void init() {
    Class relay = objc_getClass("MRCloudRelay");
    if (relay) {
        MSHookMessageEx(relay, @selector(directWatchUrl), (IMP)hook_directWatchUrl, (IMP *)&orig_directWatchUrl);
        MSHookMessageEx(relay, @selector(publishWsUrl), (IMP)hook_publishWsUrl, (IMP *)&orig_publishWsUrl);
    }
    Class urlClass = objc_getClass("NSURL");
    if (urlClass) {
        MSHookMessageEx(urlClass, @selector(URLWithString:), (IMP)hook_URLWithString, (IMP *)&orig_URLWithString);
    }
}
