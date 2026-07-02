#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#define NEW_IP @"162.14.104.134"

@interface MRCloudRelay : NSObject
- (NSString *)publishWsUrl;
@end

@implementation MRCloudRelay (Hook)

- (NSString *)new_publishWsUrl {
    // 原来: ws://210.16.163.46:93/loon
    // 改成: ws://162.14.104.134/ws?role=publisher&room=default
    return @"ws://" NEW_IP "/ws?role=publisher&room=default";
}

@end

__attribute__((constructor))
static void init() {
    Class relay = objc_getClass("MRCloudRelay");
    if (relay) {
        Method orig = class_getInstanceMethod(relay, @selector(publishWsUrl));
        Method new = class_getInstanceMethod(relay, @selector(new_publishWsUrl));
        method_exchangeImplementations(orig, new);
    }
}
