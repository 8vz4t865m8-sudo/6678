// ============================================================
//  CoreSetDiag.m  —— 启动闪退 诊断版注入包
//  作用：不管 App 是被系统杀、自己 exit、还是崩在代码里，
//        都把「原因 + 调用栈」抓下来，写进沙盒并自动复制到剪贴板。
//  用法：编成 dylib 注入后打开 App，闪退那一刻原因已经在剪贴板里了，
//        打开 Telegram 长按粘贴发出来即可。
//  编译：见 .github/workflows/build.yml（必须含 arm64e 切片！）
// ============================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <execinfo.h>
#import <signal.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <unistd.h>
#import <fcntl.h>
#import <stdio.h>
#import <time.h>
#import <string.h>
#import <stdlib.h>
#import <sys/sysctl.h>
#import <pthread.h>

#define QX_VER        @"diag-1.0"
#define QX_SHOW_UI    1     // 1=启动弹诊断窗（看完了可以改 0 重编）
#define QX_EXIT_HOLD  25    // 拦到 exit() 时先卡住多少秒，方便截图

// ------------------------------------------------------------
// 全局
// ------------------------------------------------------------
static char        gLogPath[1024];
static char        gReport[32768];
static volatile int gBusy = 0;
static NSString   *gPrevLog = nil;     // 上次运行留下的日志

static NSString *qxDocsDir(void) {
    NSArray *p = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return p.count ? p[0] : NSTemporaryDirectory();
}

static const char *qxCString(NSString *s) {
    return s ? [s UTF8String] : "?";
}

static void qxAppendFile(const char *s) {
    int fd = open(gLogPath, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        size_t n = strlen(s);
        ssize_t w = write(fd, s, n);
        (void)w;
        ssize_t w2 = write(fd, "\n", 1);
        (void)w2;
        close(fd);
    }
}

// 设备信息（启动时算一次，之后缓存成 C 串，崩的时候不用再调系统）
static char gDevInfo[512] = "?";

static void qxCollectDeviceInfo(void) {
    char model[128] = "?";
    size_t sz = sizeof(model);
    if (sysctlbyname("hw.machine", model, &sz, NULL, 0) != 0) strlcpy(model, "?", sizeof(model));

    char os[128] = "?";
    size_t osz = sizeof(os);
    if (sysctlbyname("kern.osversion", os, &osz, NULL, 0) != 0) strlcpy(os, "?", sizeof(os));

    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";

    // App 主二进制架构
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
    const char *arch = "?";
    if (mh) {
        if ((mh->cputype & 0x00ffffff) == 12) {
            uint32_t sub = mh->cpusubtype;
            arch = (sub & 0xff) == 2 ? "arm64e" : "arm64";
        }
    }

    // 本 dylib 自己跑在什么架构上 + 有几个切片
    const char *selfArch = "?";
    uint32_t ic = _dyld_image_count();
    for (uint32_t i = 0; i < ic; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "CoreSetDiag")) {
            const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
            if (h && (h->cputype & 0x00ffffff) == 12) {
                selfArch = ((h->cpusubtype & 0xff) == 2) ? "arm64e" : "arm64";
            }
            break;
        }
    }

    snprintf(gDevInfo, sizeof(gDevInfo),
             "设备:%s  iOS:%s  App:%s v%s  主程序架构:%s  本dylib跑在:%s",
             model, os, qxCString(bid), qxCString(ver), arch, selfArch);
}

// ------------------------------------------------------------
// 调用栈（关键：给的是「镜像内偏移」，拿回来就能对到代码）
// ------------------------------------------------------------
static void qxBacktrace(char *out, size_t outsz) {
    void *addrs[80];
    int n = backtrace(addrs, 80);
    size_t used = 0;
    out[0] = 0;
    for (int i = 0; i < n && used + 160 < outsz; i++) {
        Dl_info info;
        int wrote;
        if (dladdr(addrs[i], &info) && info.dli_fname) {
            const char *base = strrchr(info.dli_fname, '/');
            base = base ? base + 1 : info.dli_fname;
            unsigned long long off = (unsigned long long)((uintptr_t)addrs[i] - (uintptr_t)info.dli_fbase);
            wrote = snprintf(out + used, outsz - used, "  #%-2d %-28s +0x%llx\n", i, base, off);
        } else {
            wrote = snprintf(out + used, outsz - used, "  #%-2d %p\n", i, addrs[i]);
        }
        if (wrote <= 0) break;
        used += (size_t)wrote;
    }
}

// ------------------------------------------------------------
// 生成报告 → 落盘 + 复制到剪贴板
// ------------------------------------------------------------
static void qxEmit(const char *headline) {
    char stack[16384];
    stack[0] = 0;
    qxBacktrace(stack, sizeof(stack));

    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    char ts[64];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tmv);

    snprintf(gReport, sizeof(gReport),
             "===== 闪退诊断报告 (%s) =====\n"
             "时间: %s\n"
             "%s\n"
             "原因: %s\n"
             "调用栈(镜像内偏移, 0x… 部分就是崩在哪):\n%s"
             "================================",
             qxCString(QX_VER), ts, gDevInfo, headline, stack);

    qxAppendFile(gReport);

    // 复制到系统剪贴板 —— 进程就算马上死，剪贴板里的东西还在
    @try {
        @autoreleasepool {
            NSString *s = [NSString stringWithUTF8String:gReport];
            if (s) [UIPasteboard generalPasteboard].string = s;
        }
    } @catch (NSException *e) { (void)e; }
}

// ------------------------------------------------------------
// 1) 信号处理器 —— 管 SIGABRT / SIGSEGV / SIGTRAP / SIGBUS …
// ------------------------------------------------------------
static void qxSignalHandler(int sig, siginfo_t *si, void *uctx) {
    (void)uctx;
    if (gBusy) {     // 处理中又崩了：直接放行，别死循环
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    gBusy = 1;

    const char *name = "未知信号";
    switch (sig) {
        case SIGABRT: name = "SIGABRT(主动 abort / C++异常 / 断言失败)"; break;
        case SIGSEGV: name = "SIGSEGV(野指针/空指针访问)";               break;
        case SIGBUS:  name = "SIGBUS(内存访问异常/映射失效)";            break;
        case SIGILL:  name = "SIGILL(非法指令)";                        break;
        case SIGTRAP: name = "SIGTRAP(Swift 强解包 nil / 系统 trap)";    break;
        case SIGFPE:  name = "SIGFPE(算术错误)";                        break;
        case SIGSYS:  name = "SIGSYS(非法系统调用)";                    break;
        default: break;
    }
    char head[256];
    snprintf(head, sizeof(head), "信号 %s  故障地址=%p", name, si ? si->si_addr : NULL);
    qxEmit(head);

    signal(sig, SIG_DFL);
    raise(sig);
}

// ------------------------------------------------------------
// 2) 未捕获异常（OC / Swift 抛出来没人接的）
// ------------------------------------------------------------
static void qxExceptionHandler(NSException *e) {
    char head[1024];
    snprintf(head, sizeof(head), "未捕获异常 %s: %s",
             qxCString(e.name), qxCString(e.reason));
    qxEmit(head);
}

// ------------------------------------------------------------
// 3) atexit —— 管 App 自己调 exit() 的情况（这种情况最像"闪退"）
// ------------------------------------------------------------
static void qxAtExit(void) {
    char head[256];
    snprintf(head, sizeof(head), "App 主动调用了 exit() 退出（不是崩溃，是它自己走的）");
    qxEmit(head);

    // 卡住一会儿，让上面的窗看得见、也让人有时间截图
    if (QX_EXIT_HOLD > 0) sleep(QX_EXIT_HOLD);
}

// ------------------------------------------------------------
// 诊断窗（自己开一个高优先级 window，不依赖 App 的界面）
// ------------------------------------------------------------
static UIWindow *gWin = nil;

static void qxShowUI(NSString *text) {
#if QX_SHOW_UI
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindowScene *scene = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) {
                    scene = (UIWindowScene *)s;
                    if (s.activationState == UISceneActivationStateForegroundActive) break;
                }
            }
            UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                                : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            if (scene) w.frame = scene.coordinateSpace.bounds;
            w.windowLevel = UIWindowLevelAlert + 500;

            UIViewController *vc = [UIViewController new];
            vc.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.95];

            // 不用 CGRectInset：它是 CoreGraphics 的外部函数符号，链接期容易找不到。
            // 这里纯手算 frame，零外部依赖。
            CGRect vb = vc.view.bounds;
            CGRect tvFrame;
            tvFrame.origin.x    = 12;
            tvFrame.origin.y    = 70;
            tvFrame.size.width  = vb.size.width  - 24;
            tvFrame.size.height = vb.size.height - 140;
            if (tvFrame.size.width  < 100) tvFrame.size.width  = 100;
            if (tvFrame.size.height < 100) tvFrame.size.height = 100;
            UITextView *tv = [[UITextView alloc] initWithFrame:tvFrame];
            tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            tv.backgroundColor = [UIColor blackColor];
            tv.textColor = [UIColor colorWithRed:0.4 green:1 blue:0.5 alpha:1];
            tv.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
            tv.editable = NO;
            tv.text = text;
            [vc.view addSubview:tv];

            UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
            copy.frame = (CGRect){{12, 28}, {130, 34}};
            [copy setTitle:@"复制报告" forState:UIControlStateNormal];
            [copy addTarget:vc action:@selector(qxCopyTapped:) forControlEvents:UIControlEventTouchUpInside];
            objc_setAssociatedObject(copy, "txt", tv.text, OBJC_ASSOCIATION_RETAIN);
            [vc.view addSubview:copy];

            UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
            close.frame = (CGRect){{vc.view.bounds.size.width - 100, 28}, {88, 34}};
            [close setTitle:@"关闭" forState:UIControlStateNormal];
            [close addTarget:vc action:@selector(qxCloseTapped:) forControlEvents:UIControlEventTouchUpInside];
            [vc.view addSubview:close];

            w.rootViewController = vc;
            w.hidden = NO;
            gWin = w;
        } @catch (NSException *e) { (void)e; }
    });
#endif
}

@interface UIViewController (QXDiag)
@end
@implementation UIViewController (QXDiag)
- (void)qxCopyTapped:(UIButton *)b {
    id t = objc_getAssociatedObject(b, "txt");
    if ([t isKindOfClass:[NSString class]]) {
        [UIPasteboard generalPasteboard].string = t;
        [b setTitle:@"已复制✓" forState:UIControlStateNormal];
    }
}
- (void)qxCloseTapped:(UIButton *)b {
    (void)b;
    gWin.hidden = YES;
    gWin = nil;
}
@end

// ------------------------------------------------------------
// 启动
// ------------------------------------------------------------
@interface QXDiagLaunch : NSObject
@end
@implementation QXDiagLaunch
+ (void)onLaunch:(NSNotification *)n {
    (void)n;
    NSString *body = [NSString stringWithFormat:
        @"%@ 已加载 ✓\n%@\n\n"
        @"本次运行日志会写在这里：\nDocuments/qx_diag.log\n\n"
        @"【上次运行留下来的最后记录】\n%@",
        QX_VER, [NSString stringWithUTF8String:gDevInfo],
        gPrevLog.length ? gPrevLog : @"（无 —— 说明上次是第一次跑，或者上次是硬崩、来不及记录）"];
    qxShowUI(body);
}
@end

__attribute__((constructor))
static void qxInit(void) {
    @autoreleasepool {
        NSString *lp = [qxDocsDir() stringByAppendingPathComponent:@"qx_diag.log"];
        strlcpy(gLogPath, qxCString(lp), sizeof(gLogPath));

        qxCollectDeviceInfo();

        // 读上一次的日志尾巴（最多 12000 字）
        NSString *old = [NSString stringWithContentsOfFile:lp encoding:NSUTF8StringEncoding error:NULL];
        if (old.length > 12000) old = [old substringFromIndex:old.length - 12000];
        gPrevLog = [old copy];

        qxAppendFile("\n");
        qxAppendFile("================ 新一次启动 ================");
        {
            char head[512];
            snprintf(head, sizeof(head), "启动: %s", gDevInfo);
            qxAppendFile(head);
        }

        NSSetUncaughtExceptionHandler(&qxExceptionHandler);
        atexit(qxAtExit);

        static struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = qxSignalHandler;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&sa.sa_mask);
        int sigs[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGSYS};
        for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
            struct sigaction old_sa;
            sigaction(sigs[i], &sa, &old_sa);
        }

        [[NSNotificationCenter defaultCenter] addObserver:[QXDiagLaunch class]
                                                 selector:@selector(onLaunch:)
                                                     name:UIApplicationDidFinishLaunchingNotification
                                                   object:nil];
    }
}
