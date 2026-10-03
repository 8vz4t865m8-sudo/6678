/* ============================================================================
 * CoreSetFix.m  —  v3.0 「保命版」
 *
 * 目标(按优先级):
 *   1. 让 App 自己踩空的那一脚(CFDictionaryGetCount(NULL))当场被接住,不再秒退
 *   2. 修掉重签导致的钥匙串访问组失效(自签 App 秒退的头号嫌疑)
 *   3. 把真实死因 + 每次请求应答完整记录下来,方便下一轮做精准激活
 *
 * 适用版本:Core-SET v1.7(主程序 UUID fb499349-0107-3fc4-b686-8fa3ffd2dd3b)
 * 纯 C 实现,不依赖 Foundation/UIKit 头文件;符号槽地址与本版二进制一一对应。
 * ========================================================================== */

/* ------------------------------- 开关 ----------------------------------- */
#define QX_VER            "3.0"
#define QX_TARGET_UUID    "fb499349-0107-3fc4-b686-8fa3ffd2dd3b"
#define QX_SLIDE_BASE     0x100000000ULL

#define QX_HEAL_NULL      1   /* 空指针自愈(核心) */
#define QX_FIX_KEYCHAIN   1   /* 钥匙串访问组修复 */
#define QX_GUARD_CF       1   /* CoreFoundation 空指针防护 */
#define QX_LOG_NET        1   /* 网络请求/应答抓取 */
#define QX_SANITIZE_NET   1   /* 应答净化:否决状态 -> ACTIVE */
#define QX_CLIPBOARD      1   /* 定时把报告写进剪贴板 */
#define QX_DUMP_IMAGES    1   /* 启动时记录已加载镜像 */

#define QX_MAX_HEAL       400 /* 最多自愈多少次,防止死循环 */
#define QX_MAX_ONE_PC     40  /* 同一地址反复踩空的上限 */

/* ------------------------------- 头文件 --------------------------------- */
#include <stdbool.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <ptrauth.h>
#include <Block.h>
#include <dispatch/dispatch.h>

/* --------------------------- ObjC 运行时(手写声明) --------------------- */
typedef void *qx_id;
typedef void *qx_SEL;
typedef void *qx_Class;
typedef void *qx_Method;
typedef void (*qx_IMP)(void);

extern qx_Class objc_getClass(const char *name);
extern qx_SEL   sel_registerName(const char *name);
extern qx_Method class_getInstanceMethod(qx_Class cls, qx_SEL sel);
extern qx_Method class_getClassMethod(qx_Class cls, qx_SEL sel);
extern qx_IMP   method_getImplementation(qx_Method m);
extern qx_IMP   method_setImplementation(qx_Method m, qx_IMP imp);
extern qx_Class object_getClass(qx_id obj);
extern void    *objc_msgSend(void);

/* CoreFoundation(手写声明,免得引头文件) */
typedef const void *CFTypeRef;
typedef const void *CFDictionaryRef;
typedef void       *CFMutableDictionaryRef;
typedef const void *CFStringRef;

extern void            *CFDictionaryCreateMutableCopy(void *allocator, long capacity, CFDictionaryRef src);
extern void             CFDictionaryRemoveValue(CFMutableDictionaryRef d, const void *key);
extern int              CFDictionaryContainsKey(CFDictionaryRef d, const void *key);
extern const void      *CFDictionaryGetValue(CFDictionaryRef d, const void *key);
extern void             CFRelease(const void *cf);
extern unsigned long    CFGetTypeID(const void *cf);
extern unsigned long    CFStringGetTypeID(void);
extern int              CFStringGetCString(CFStringRef s, char *buf, long size, uint32_t encoding);

/* Security(钥匙串常量) */
extern const void *kSecClass;
extern const void *kSecAttrAccount;
extern const void *kSecAttrService;
extern const void *kSecAttrAccessGroup;
extern const void *kSecValueData;
extern const void *kSecReturnData;

typedef int32_t OSStatus;

/* ========================================================================== */
/* 1. 日志                                                                    */
/* ========================================================================== */

static int   g_fd   = -1;
static char  g_path[512];
static long  g_pg   = 4096;
static uintptr_t g_slide = 0;
static void *g_main_hdr  = 0;

static void qx_raw(const char *s, size_t n) { if (g_fd >= 0) { ssize_t r = write(g_fd, s, n); (void)r; } }

static void qx_log(const char *fmt, ...)
{
    char buf[1200];
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = vsnprintf(buf, sizeof(buf) - 2, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof(buf) - 2) n = (int)sizeof(buf) - 2;
    buf[n++] = '\n';
    qx_raw(buf, (size_t)n);
}

/* 信号处理里专用的无依赖版本(只使用 write,不碰 malloc) */
static char *qx_pstr(char *p, const char *s) { while (*s) *p++ = *s++; return p; }
static char *qx_phex(char *p, uint64_t v)
{
    static const char *H = "0123456789abcdef";
    char t[17];
    int i;
    if (v == 0) { *p++ = '0'; return p; }
    for (i = 0; i < 16 && v; i++) { t[i] = H[v & 15]; v >>= 4; }
    while (i--) *p++ = t[i];
    return p;
}
static char *qx_pdec(char *p, long v)
{
    char t[24]; int i = 0;
    if (v < 0) { *p++ = '-'; v = -v; }
    if (v == 0) { *p++ = '0'; return p; }
    while (v > 0) { t[i++] = (char)('0' + (v % 10)); v /= 10; }
    while (i--) *p++ = t[i];
    return p;
}

/* ========================================================================== */
/* 2. 内存可写 / 符号槽接管(带 PAC 签名的原位替换)                           */
/* ========================================================================== */

static int qx_writable(void *addr, size_t len)
{
    uintptr_t a = (uintptr_t)addr & ~(uintptr_t)(g_pg - 1);
    uintptr_t b = ((uintptr_t)addr + len + (uintptr_t)g_pg - 1) & ~(uintptr_t)(g_pg - 1);
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)a, (vm_size_t)(b - a),
                                  false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return kr == KERN_SUCCESS;
}

typedef struct { const char *name; uint64_t va; } qx_slot_t;

/* 这些地址取自 Core-SET v1.7 主二进制的链式修复表(DYLD_CHAINED_PTR_ARM64E_USERLAND24,
 * 全部为 auth-bind: key=IA, addrDiv=1, diversity=0)。换版本后会自动跳过并打印警告。 */
static const qx_slot_t g_slots[] = {
    { "SecItemCopyMatching", 0x100b8c290ULL },
    { "SecItemAdd",          0x100b8c288ULL },
    { "SecItemUpdate",       0x100b8c2a0ULL },
    { "SecItemDelete",       0x100b8c298ULL },
    { "dlsym",               0x100b8ce78ULL },
    { "dlopen",              0x100b8ce70ULL },
    { "sigaction",           0x100b8d348ULL },
    { "signal",              0x100b8d350ULL },
    { NULL, 0 }
};

static int qx_takeover(const char *name, uint64_t va, void *repl, void **orig)
{
    uintptr_t *slot = (uintptr_t *)(g_slide + (va - QX_SLIDE_BASE));
    void *real = dlsym(RTLD_DEFAULT, name);
    void *cur  = ptrauth_strip((void *)*slot, ptrauth_key_asia);

    if (orig) *orig = (cur ? cur : real);
    if (!real) { qx_log("[槽位] %s: dlsym 拿不到真身,跳过", name); return -1; }
    if (cur != real) {
        qx_log("[槽位] %s 地址对不上(槽内=%p 真身=%p) —— 版本可能变了,跳过", name, cur, real);
        return -2;
    }
    if (!qx_writable(slot, sizeof(*slot))) { qx_log("[槽位] %s 页面改不动,跳过", name); return -3; }

    uint64_t disc = ptrauth_blend_discriminator(slot, 0);
    *slot = (uintptr_t)ptrauth_sign_unauthenticated(repl, ptrauth_key_asia, disc);
    qx_log("[槽位] %s 已接管(槽=%p 原=%p)", name, (void *)slot, real);
    return 0;
}

/* ========================================================================== */
/* 3. 钥匙串修复 + CoreFoundation 防护                                        */
/* ========================================================================== */

static OSStatus (*real_copyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*real_itemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*real_itemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*real_itemDelete)(CFDictionaryRef);

static void qx_cf2str(const void *cfstr, char *out, size_t n)
{
    out[0] = 0;
    if (!cfstr) return;
    if (CFGetTypeID(cfstr) != CFStringGetTypeID()) { strncpy(out, "(非字符串)", n - 1); out[n - 1] = 0; return; }
    if (!CFStringGetCString((CFStringRef)cfstr, out, (long)n, 0x08000100)) { out[0] = 0; }
}

static void qx_kc_dump(const char *tag, CFDictionaryRef q)
{
    char c[128], a[192], s[192], g[192];
    if (!q) { qx_log("[钥匙串] %s 查询字典=NULL", tag); return; }
    qx_cf2str(CFDictionaryGetValue(q, kSecClass), c, sizeof(c));
    qx_cf2str(CFDictionaryGetValue(q, kSecAttrAccount), a, sizeof(a));
    qx_cf2str(CFDictionaryGetValue(q, kSecAttrService), s, sizeof(s));
    qx_cf2str(CFDictionaryGetValue(q, kSecAttrAccessGroup), g, sizeof(g));
    qx_log("[钥匙串] %s class=%s acct=%s svc=%s group=%s", tag,
           c[0] ? c : "-", a[0] ? a : "-", s[0] ? s : "-", g[0] ? g : "(无)");
}

/* 把访问组去掉再试一次:自签之后 team 变了,原访问组必然被拒(-34018) */
static int qx_strip_retry(CFDictionaryRef q, CFDictionaryRef *out)
{
    *out = NULL;
    if (!q || !kSecAttrAccessGroup) return 0;
    if (!CFDictionaryContainsKey(q, kSecAttrAccessGroup)) return 0;
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, q);
    if (!m) return 0;
    CFDictionaryRemoveValue(m, kSecAttrAccessGroup);
    *out = m;
    return 1;
}

static OSStatus qx_SecItemCopyMatching(CFDictionaryRef q, CFTypeRef *res)
{
#if QX_FIX_KEYCHAIN
    OSStatus st = real_copyMatching(q, res);
    qx_kc_dump("copy", q);
    if (st != 0) {
        CFDictionaryRef q2 = NULL;
        if (qx_strip_retry(q, &q2)) {
            OSStatus st2 = real_copyMatching(q2, res);
            qx_log("[钥匙串] copy 原状态=%d → 去掉访问组重试=%d", (int)st, (int)st2);
            CFRelease(q2);
            if (st2 == 0) return 0;
        } else {
            qx_log("[钥匙串] copy 状态=%d(无访问组可去掉)", (int)st);
        }
    }
    return st;
#else
    return real_copyMatching(q, res);
#endif
}

static OSStatus qx_SecItemAdd(CFDictionaryRef q, CFTypeRef *res)
{
#if QX_FIX_KEYCHAIN
    OSStatus st = real_itemAdd(q, res);
    if (st != 0) {
        CFDictionaryRef q2 = NULL;
        if (qx_strip_retry(q, &q2)) {
            OSStatus st2 = real_itemAdd(q2, res);
            qx_log("[钥匙串] add 原状态=%d → 去掉访问组重试=%d", (int)st, (int)st2);
            CFRelease(q2);
            if (st2 == 0) return 0;
        } else {
            qx_log("[钥匙串] add 状态=%d", (int)st);
        }
    }
    return st;
#else
    return real_itemAdd(q, res);
#endif
}

static OSStatus qx_SecItemUpdate(CFDictionaryRef q, CFDictionaryRef attrs)
{
#if QX_FIX_KEYCHAIN
    OSStatus st = real_itemUpdate(q, attrs);
    if (st != 0) {
        CFDictionaryRef q2 = NULL, a2 = NULL;
        int ok1 = qx_strip_retry(q, &q2), ok2 = qx_strip_retry(attrs, &a2);
        if (ok1 || ok2) {
            OSStatus st2 = real_itemUpdate(ok1 ? q2 : q, ok2 ? a2 : attrs);
            qx_log("[钥匙串] update 原状态=%d → 去访问组重试=%d", (int)st, (int)st2);
            if (ok1) CFRelease(q2);
            if (ok2) CFRelease(a2);
            if (st2 == 0) return 0;
        } else {
            qx_log("[钥匙串] update 状态=%d", (int)st);
        }
    }
    return st;
#else
    return real_itemUpdate(q, attrs);
#endif
}

static OSStatus qx_SecItemDelete(CFDictionaryRef q)
{
#if QX_FIX_KEYCHAIN
    OSStatus st = real_itemDelete(q);
    if (st != 0) {
        CFDictionaryRef q2 = NULL;
        if (qx_strip_retry(q, &q2)) {
            OSStatus st2 = real_itemDelete(q2);
            qx_log("[钥匙串] delete 原状态=%d → 去掉访问组重试=%d", (int)st, (int)st2);
            CFRelease(q2);
            if (st2 == 0) return 0;
        }
    }
    return st;
#else
    return real_itemDelete(q);
#endif
}

/* --- CoreFoundation 空指针防护:就是崩在 CFDictionaryGetCount(NULL) 上 --- */
static unsigned long (*real_dGetCount)(CFDictionaryRef);
static const void    *(*real_dGetValue)(CFDictionaryRef, const void *);
static unsigned long (*real_aGetCount)(const void *);
static void           (*real_release)(const void *);
static const void    *(*real_retain)(const void *);
static int            (*real_gvIfPresent)(CFDictionaryRef, const void *, const void **);

static int g_cf_guard_hit = 0;

static unsigned long qx_CFDictionaryGetCount(CFDictionaryRef d)
{
    if (!d) { if (g_cf_guard_hit++ < 50) qx_log("[CF] CFDictionaryGetCount(NULL) → 挡下,返回 0"); return 0; }
    return real_dGetCount ? real_dGetCount(d) : 0;
}
static const void *qx_CFDictionaryGetValue(CFDictionaryRef d, const void *k)
{
    if (!d || !k) { if (g_cf_guard_hit++ < 50) qx_log("[CF] CFDictionaryGetValue(空) → 挡下,返回 NULL"); return NULL; }
    return real_dGetValue ? real_dGetValue(d, k) : NULL;
}
static int qx_CFDictionaryGetValueIfPresent(CFDictionaryRef d, const void *k, const void **v)
{
    if (!d || !k) { if (g_cf_guard_hit++ < 50) qx_log("[CF] CFDictionaryGetValueIfPresent(空) → 挡下"); if (v) *v = NULL; return 0; }
    return real_gvIfPresent ? real_gvIfPresent(d, k, v) : 0;
}
static unsigned long qx_CFArrayGetCount(const void *a)
{
    if (!a) { if (g_cf_guard_hit++ < 50) qx_log("[CF] CFArrayGetCount(NULL) → 挡下,返回 0"); return 0; }
    return real_aGetCount ? real_aGetCount(a) : 0;
}
static void qx_CFRelease(const void *cf)
{
    if (!cf) { if (g_cf_guard_hit++ < 50) qx_log("[CF] CFRelease(NULL) → 挡下"); return; }
    if (real_release) real_release(cf);
}
static const void *qx_CFRetain(const void *cf)
{
    if (!cf) { if (g_cf_guard_hit++ < 50) qx_log("[CF] CFRetain(NULL) → 挡下"); return NULL; }
    return real_retain ? real_retain(cf) : cf;
}

typedef struct { const char *n; void *p; } qx_guard_t;

static const qx_guard_t g_guards[] = {
    { "CFDictionaryGetCount",          (void *)qx_CFDictionaryGetCount },
    { "CFDictionaryGetValue",          (void *)qx_CFDictionaryGetValue },
    { "CFDictionaryGetValueIfPresent", (void *)qx_CFDictionaryGetValueIfPresent },
    { "CFArrayGetCount",               (void *)qx_CFArrayGetCount },
    { "CFRelease",                     (void *)qx_CFRelease },
    { "CFRetain",                      (void *)qx_CFRetain },
    { "SecItemCopyMatching",           (void *)qx_SecItemCopyMatching },
    { "SecItemAdd",                    (void *)qx_SecItemAdd },
    { "SecItemUpdate",                 (void *)qx_SecItemUpdate },
    { "SecItemDelete",                 (void *)qx_SecItemDelete },
    { NULL, NULL }
};

/* --- dlsym / dlopen 钩子:Lua/FFI 那种运行时取符号的调用也一并包住 --- */
static void *(*real_dlsym)(void *, const char *);
static void *(*real_dlopen)(const char *, int);
static int   (*real_sigaction)(int, const struct sigaction *, struct sigaction *);
typedef void (*qx_sighandler_t)(int);
static qx_sighandler_t (*real_signal)(int, qx_sighandler_t);

static void *qx_dlsym(void *h, const char *name)
{
    int i;
    if (name) {
        for (i = 0; g_guards[i].n; i++) {
            if (strcmp(name, g_guards[i].n) == 0) {
                qx_log("[dlsym] %s → 已包裹返回", name);
                return g_guards[i].p;
            }
        }
        if (strstr(name, "SecItem") || strstr(name, "CFDictionary") ||
            strstr(name, "ptrace")    || strstr(name, "csops")        ||
            strstr(name, "sysctl"))
            qx_log("[dlsym] %s", name);
    }
    return real_dlsym ? real_dlsym(h, name) : NULL;
}

static void *qx_dlopen(const char *path, int mode)
{
    void *r = real_dlopen ? real_dlopen(path, mode) : NULL;
    qx_log("[dlopen] %s → %s", path ? path : "(null)", r ? "ok" : "fail");
    return r;
}

/* 别让 App 自己把我们的信号处理换掉 */
static int qx_sigaction(int sig, const struct sigaction *act, struct sigaction *old)
{
    if ((sig == SIGSEGV || sig == SIGBUS) && act) {
        qx_log("[信号] 拦下 App 对 %s 的重设", sig == SIGSEGV ? "SIGSEGV" : "SIGBUS");
        if (old) real_sigaction(sig, NULL, old);
        return 0;
    }
    return real_sigaction ? real_sigaction(sig, act, old) : -1;
}
static qx_sighandler_t qx_signal(int sig, qx_sighandler_t h)
{
    if ((sig == SIGSEGV || sig == SIGBUS) && h != SIG_IGN && h != SIG_DFL) {
        qx_log("[信号] 拦下 App 对 %s 的 signal()", sig == SIGSEGV ? "SIGSEGV" : "SIGBUS");
        return SIG_IGN;
    }
    return real_signal ? real_signal(sig, h) : SIG_IGN;
}

/* ========================================================================== */
/* 4. 空指针自愈:把踩空那一脚原地接住                                         */
/* ========================================================================== */

static volatile int g_heal = 0;
static uintptr_t    g_heal_pc[QX_MAX_ONE_PC * 4];
static int          g_heal_cnt[QX_MAX_ONE_PC * 4];
static int          g_heal_n = 0;

/* 按 ARM64 寄存器号安全读写(x29=FP / x30=LR / x31=SP 都不是数组元素) */
static uint64_t qx_getreg(ucontext_t *uc, uint32_t r)
{
    if (r < 29)  return uc->uc_mcontext->__ss.__x[r];
    if (r == 29) return uc->uc_mcontext->__ss.__fp;
    if (r == 30) return uc->uc_mcontext->__ss.__lr;
    return uc->uc_mcontext->__ss.__sp;
}
static void qx_setreg(ucontext_t *uc, uint32_t r, uint64_t v)
{
    if (r < 29)       uc->uc_mcontext->__ss.__x[r] = v;
    else if (r == 29) uc->uc_mcontext->__ss.__fp    = v;
    else if (r == 30) uc->uc_mcontext->__ss.__lr    = v;
    /* r == 31 是 XZR,丢掉写入 */
}

/* 返回 1 = 可以跳过这条指令继续跑 */
static int qx_emu_load(ucontext_t *uc, uintptr_t far)
{
    uintptr_t pc     = uc->uc_mcontext->__ss.__pc;
    uint32_t  insn   = *(uint32_t *)pc;

    if (far >= 0x10000) return 0;   /* 只救页零附近的空指针 */

    /* LDR/STR (未移位立即数): size(2) 111 V 01 opc(2) imm12 Rn Rt */
    uint32_t f = (insn >> 24) & 0x3F;
    if (f == 0x39 || f == 0x3D) {
        uint32_t V   = (insn >> 26) & 1;
        uint32_t opc = (insn >> 22) & 3;
        uint32_t rn  = (insn >> 5) & 31;
        uint32_t rt  = insn & 31;
        uint64_t base = qx_getreg(uc, rn);
        if (V == 0 && opc == 1 && base < 0x10000) {      /* 读操作 → 目标寄存器置 0 */
            qx_setreg(uc, rt, 0);
            uc->uc_mcontext->__ss.__pc = pc + 4;
            return 1;
        }
        return 0;                                        /* 写操作救不了 */
    }

    /* LDP (64 位立即数) 与 STP 同族:opc=10 101 V 0 0 1 0 */
    if (((insn >> 22) & 0x3FF) == 0x2A5) {
        uint32_t rn  = (insn >> 5) & 31;
        uint32_t rt  = insn & 31;
        uint32_t rt2 = (insn >> 10) & 31;
        uint64_t base = qx_getreg(uc, rn);
        if (base < 0x10000) {
            qx_setreg(uc, rt, 0);
            qx_setreg(uc, rt2, 0);
            uc->uc_mcontext->__ss.__pc = pc + 4;
            return 1;
        }
    }
    return 0;
}

static int qx_pc_seen(uintptr_t pc)
{
    int i;
    for (i = 0; i < g_heal_n; i++) {
        if (g_heal_pc[i] == pc) { g_heal_cnt[i]++; return g_heal_cnt[i]; }
    }
    if (g_heal_n < QX_MAX_ONE_PC * 4) { g_heal_pc[g_heal_n] = pc; g_heal_cnt[g_heal_n] = 1; g_heal_n++; }
    return 1;
}

static void qx_dump_ctx(const char *tag, int sig, uintptr_t far, ucontext_t *uc);

static void qx_handler(int sig, siginfo_t *si, void *ctx)
{
    ucontext_t *uc  = (ucontext_t *)ctx;
    uintptr_t   far = (uintptr_t)(si ? si->si_addr : 0);
    uintptr_t   pc  = uc->uc_mcontext->__ss.__pc;

#if QX_HEAL_NULL
    if (g_heal < QX_MAX_HEAL && qx_emu_load(uc, far)) {
        int seen = qx_pc_seen(pc);
        g_heal++;
        char b[256], *p = b;
        p = qx_pstr(p, "[自愈] 第 ");   p = qx_pdec(p, g_heal);
        p = qx_pstr(p, " 次接住空指针 @pc="); p = qx_phex(p, pc);
        p = qx_pstr(p, " 地址=");       p = qx_phex(p, far);
        p = qx_pstr(p, " 同址第 ");     p = qx_pdec(p, seen);
        p = qx_pstr(p, " 次\n");
        qx_raw(b, (size_t)(p - b));
        if (seen > 8) {                 /* 同一个地方反复踩,说明救不活 */
            p = b;
            p = qx_pstr(p, "[自愈] 同址反复,交回系统\n");
            qx_raw(b, (size_t)(p - b));
            qx_dump_ctx("放弃", sig, far, uc);
            signal(sig, SIG_DFL);
            raise(sig);
            return;
        }
        return;                         /* 继续跑 */
    }
#endif
    qx_dump_ctx("致死", sig, far, uc);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void qx_dump_ctx(const char *tag, int sig, uintptr_t far, ucontext_t *uc)
{
    char b[4096], *p = b;
    uint64_t *x = uc->uc_mcontext->__ss.__x;
    uint64_t fp = uc->uc_mcontext->__ss.__fp;
    int i;

    p = qx_pstr(p, "[崩溃] "); p = qx_pstr(p, tag);
    p = qx_pstr(p, " sig=");   p = qx_pdec(p, sig);
    p = qx_pstr(p, " pc=");    p = qx_phex(p, uc->uc_mcontext->__ss.__pc);
    p = qx_pstr(p, " addr=");  p = qx_phex(p, far);
    p = qx_pstr(p, " lr=");    p = qx_phex(p, uc->uc_mcontext->__ss.__lr);
    p = qx_pstr(p, "\n       x0=");
    for (i = 0; i < 8; i++) { p = qx_phex(p, x[i]); p = qx_pstr(p, " "); }
    p = qx_pstr(p, "\n");
    qx_raw(b, (size_t)(p - b));

    /* 回溯帧指针链 */
    for (i = 0; i < 20 && fp > 0x1000 && (fp & 7) == 0; i++) {
        uint64_t *fr = (uint64_t *)fp;
        uint64_t next = fr[0];
        uint64_t ret  = fr[1] & 0x0000000FFFFFFFFFULL;   /* 去掉 PAC */
        p = b;
        p = qx_pstr(p, "       帧 "); p = qx_pdec(p, i);
        p = qx_pstr(p, " = "); p = qx_phex(p, ret);
        p = qx_pstr(p, "  相对主程序 = ");
        if (g_slide && ret > g_slide + QX_SLIDE_BASE && ret < g_slide + 0x0B8C000ULL)
            p = qx_phex(p, ret - g_slide - QX_SLIDE_BASE);
        else
            p = qx_pstr(p, "(非主程序)");
        p = qx_pstr(p, "\n");
        qx_raw(b, (size_t)(p - b));
        if (next <= fp) break;
        fp = next;
    }
}

/* ========================================================================== */
/* 5. 网络抓取 + 应答净化                                                     */
/* ========================================================================== */

static void qx_method_swizzle(const char *cls, const char *sel, void *repl, void **orig, int is_class)
{
    qx_Class c = objc_getClass(cls);
    if (!c) { qx_log("[方法] 类 %s 不存在", cls); return; }
    qx_Class target = is_class ? object_getClass(c) : c;
    qx_Method m = is_class ? class_getClassMethod(c, sel_registerName(sel))
                           : class_getInstanceMethod(c, sel_registerName(sel));
    if (!m) { qx_log("[方法] %s[%s %s] 找不到", is_class ? "+" : "-", cls, sel); return; }
    if (orig) *orig = (void *)method_getImplementation(m);
    method_setImplementation(m, (qx_IMP)repl);
    qx_log("[方法] 已接管 %s[%s %s]", is_class ? "+" : "-", cls, sel);
}

static const char *qx_cstr(qx_id nsstr)
{
    if (!nsstr) return "(null)";
    const char *(*fn)(qx_id, qx_SEL) = (const char *(*)(qx_id, qx_SEL))objc_msgSend;
    const char *s = fn(nsstr, sel_registerName("UTF8String"));
    return s ? s : "(?)";
}

static const char *qx_req_url(qx_id req)
{
    if (!req) return "(无请求)";
    qx_id (*u0)(qx_id, qx_SEL) = (qx_id (*)(qx_id, qx_SEL))objc_msgSend;
    qx_id url = u0(req, sel_registerName("URL"));
    if (!url) return "(无URL)";
    qx_id abs = u0(url, sel_registerName("absoluteString"));
    return qx_cstr(abs);
}

static const char *g_bad[] = {
    "TOKEN_REJECTED", "PROCESSING_NOT_ACTIVE", "UNAUTHORIZED", "NOT_ACTIVE",
    "INACTIVE", "REVOKED", "EXPIRED", "INVALID", "REJECTED", "DENIED", NULL
};

/* 把应答里的"否决状态"统一改写成 ACTIVE(只动这个域名下的应答) */
static qx_id qx_sanitize(qx_id data, qx_id req)
{
    if (!data) return data;
    const char *url = qx_req_url(req);
    unsigned char *(*bytes)(qx_id, qx_SEL) = (unsigned char *(*)(qx_id, qx_SEL))objc_msgSend;
    unsigned long  (*lenf)(qx_id, qx_SEL)  = (unsigned long (*)(qx_id, qx_SEL))objc_msgSend;
    unsigned char *bp = bytes(data, sel_registerName("bytes"));
    unsigned long  ln = lenf(data, sel_registerName("length"));
    if (!bp || !ln || ln > 300000) return data;

    char head[401];
    unsigned long n = ln < 400 ? ln : 400;
    memcpy(head, bp, n); head[n] = 0;
    for (unsigned long i = 0; i < n; i++) if (head[i] < 32 || head[i] > 126) head[i] = '.';
    qx_log("[网络] 应答(%luB) %s\n       %s", ln, url, head);

#if QX_SANITIZE_NET
    if (!strstr(url, "klpjwycb")) return data;
    char *buf = (char *)malloc((size_t)ln + 1);
    if (!buf) return data;
    memcpy(buf, bp, ln); buf[ln] = 0;
    int changed = 0, i;
    for (i = 0; g_bad[i]; i++) {
        size_t bl = strlen(g_bad[i]);
        char *pos;
        while ((pos = strstr(buf, g_bad[i])) != NULL) {
            size_t tail = strlen(pos + bl);
            memmove(pos + 6, pos + bl, tail + 1);   /* 先把尾巴搬走,再写新值 */
            memcpy(pos, "ACTIVE", 6);
            changed++;
        }
    }
    if (!changed) { free(buf); return data; }
    qx_log("[网络] 应答已净化,改写 %d 处否决状态 → ACTIVE", changed);
    qx_id newData = ((qx_id (*)(qx_id, qx_SEL, const void *, unsigned long))objc_msgSend)(
        (qx_id)objc_getClass("NSData"), sel_registerName("dataWithBytes:length:"), buf, strlen(buf));
    free(buf);
    return newData ? newData : data;
#else
    return data;
#endif
}

static void *orig_task_req = NULL;
static void *orig_task_url = NULL;

static void *qx_task_req(void *self, void *cmd, void *req, void *handler)
{
    qx_log("[网络] dataTaskWithRequest %s", qx_req_url((qx_id)req));
    if (handler && QX_SANITIZE_NET) {
        void *h2 = Block_copy(^void(void *d, void *r, void *e) {
            void *d2 = qx_sanitize((qx_id)d, (qx_id)req);
            ((void (*)(void *, void *, void *))handler)(d2, r, e);
        });
        void *(*f)(void *, void *, void *, void *) = (void *(*)(void *, void *, void *, void *))orig_task_req;
        return f(self, cmd, req, h2);
    }
    void *(*f)(void *, void *, void *, void *) = (void *(*)(void *, void *, void *, void *))orig_task_req;
    return f(self, cmd, req, handler);
}

static void *qx_task_url(void *self, void *cmd, void *url, void *handler)
{
    qx_log("[网络] dataTaskWithURL %s", qx_cstr((qx_id)url));
    if (handler && QX_SANITIZE_NET) {
        void *h2 = Block_copy(^void(void *d, void *r, void *e) {
            void *d2 = qx_sanitize((qx_id)d, NULL);
            ((void (*)(void *, void *, void *))handler)(d2, r, e);
        });
        void *(*f)(void *, void *, void *, void *) = (void *(*)(void *, void *, void *, void *))orig_task_url;
        return f(self, cmd, url, h2);
    }
    void *(*f)(void *, void *, void *, void *) = (void *(*)(void *, void *, void *, void *))orig_task_url;
    return f(self, cmd, url, handler);
}

/* ========================================================================== */
/* 6. 报告 → 剪贴板                                                           */
/* ========================================================================== */

static void qx_clipboard_push(void)
{
    if (g_fd < 0) return;
    int fd = open(g_path, O_RDONLY);
    if (fd < 0) return;
    char buf[6144];
    long total = lseek(fd, 0, SEEK_END);
    long take  = total > (long)sizeof(buf) - 1 ? (long)sizeof(buf) - 1 : total;
    lseek(fd, total - take, SEEK_SET);
    ssize_t got = read(fd, buf, (size_t)take);
    close(fd);
    if (got <= 0) return;
    buf[got] = 0;
    if (!objc_getClass("UIPasteboard")) return;
    qx_id s = ((qx_id (*)(qx_id, qx_SEL, const char *))objc_msgSend)(
        (qx_id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), buf);
    if (!s) return;
    qx_id pb = ((qx_id (*)(qx_id, qx_SEL))objc_msgSend)(
        (qx_id)objc_getClass("UIPasteboard"), sel_registerName("generalPasteboard"));
    if (!pb) return;
    ((void (*)(qx_id, qx_SEL, qx_id))objc_msgSend)(pb, sel_registerName("setString:"), s);
}

static void qx_clipboard_timer(void)
{
#if QX_CLIPBOARD
    dispatch_queue_t q = dispatch_get_global_queue(0, 0);
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!t) return;
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 2ULL * NSEC_PER_SEC),
                              3ULL * NSEC_PER_SEC, 1ULL * NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{
        dispatch_async(dispatch_get_main_queue(), ^{ qx_clipboard_push(); });
    });
    dispatch_resume(t);
#endif
}

/* ========================================================================== */
/* 7. 启动                                                                    */
/* ========================================================================== */

static void qx_uuid_of(const void *hdr, char *out, size_t n)
{
    const uint8_t *p = (const uint8_t *)hdr;
    uint32_t ncmds = *(const uint32_t *)(p + 16);
    const uint8_t *q = p + 32;
    uint32_t i;
    for (i = 0; i < ncmds; i++) {
        uint32_t cmd = *(const uint32_t *)q;
        uint32_t sz  = *(const uint32_t *)(q + 4);
        if (cmd == 0x1B && sz >= 24) {
            const uint8_t *u = q + 8;
            snprintf(out, n,
                     "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                     u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
                     u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
            return;
        }
        if (sz < 8) break;
        q += sz;
    }
    snprintf(out, n, "(未找到)");
}

__attribute__((constructor(101))) static void qx_init(void)
{
    g_pg = sysconf(_SC_PAGESIZE);
    if (g_pg <= 0) g_pg = 16384;

    /* 日志落到 App 沙盒 Document,连带 /tmp 一份 */
    const char *home = getenv("HOME");
    if (home) snprintf(g_path, sizeof(g_path), "%s/Documents/qx_fix.log", home);
    else      snprintf(g_path, sizeof(g_path), "/tmp/qx_fix.log");
    g_fd = open(g_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (g_fd < 0) {
        snprintf(g_path, sizeof(g_path), "/tmp/qx_fix.log");
        g_fd = open(g_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }

    qx_log("================ CoreSetFix %s 启动 ================", QX_VER);
    qx_log("日志:%s  页大小:%ld  pid:%d", g_path, g_pg, (int)getpid());

    /* 主镜像 = 第一个 MH_EXECUTE */
    uint32_t n = _dyld_image_count(), i, mainIdx = 0;
    for (i = 0; i < n; i++) {
        const uint8_t *h = (const uint8_t *)_dyld_get_image_header(i);
        if (h && *(const uint32_t *)(h + 12) == 2) { mainIdx = i; break; }
    }
    g_main_hdr = (void *)_dyld_get_image_header(mainIdx);
    g_slide    = (uintptr_t)_dyld_get_image_vmaddr_slide(mainIdx);

    char uuid[64];
    qx_uuid_of(g_main_hdr, uuid, sizeof(uuid));
    qx_log("主程序:%s", _dyld_get_image_name(mainIdx));
    qx_log("UUID:%s   版本拼图:%s", uuid, strcmp(uuid, QX_TARGET_UUID) == 0 ? "匹配 ✔" : "不匹配 ✘(槽位会跳过)");
    qx_log("slide=%p", (void *)g_slide);

#if QX_DUMP_IMAGES
    qx_log("已加载镜像 %u 个,非系统的一律列出:", n);
    for (i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        if (nm[0] == '/' && strncmp(nm, "/System", 7) && strncmp(nm, "/usr/lib", 8))
            qx_log("   [镜像] %s", nm);
    }
#endif

    /* 先拿到真身 */
    real_dlsym     = (void *(*)(void *, const char *))dlsym(RTLD_DEFAULT, "dlsym");
    real_dlopen    = (void *(*)(const char *, int))dlsym(RTLD_DEFAULT, "dlopen");
    real_sigaction = (int (*)(int, const struct sigaction *, struct sigaction *))dlsym(RTLD_DEFAULT, "sigaction");
    real_signal    = (qx_sighandler_t (*)(int, qx_sighandler_t))dlsym(RTLD_DEFAULT, "signal");

    real_copyMatching = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    real_itemAdd      = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemAdd");
    real_itemUpdate   = (OSStatus (*)(CFDictionaryRef, CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemUpdate");
    real_itemDelete   = (OSStatus (*)(CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemDelete");

    real_dGetCount   = (unsigned long (*)(CFDictionaryRef))dlsym(RTLD_DEFAULT, "CFDictionaryGetCount");
    real_dGetValue   = (const void *(*)(CFDictionaryRef, const void *))dlsym(RTLD_DEFAULT, "CFDictionaryGetValue");
    real_aGetCount   = (unsigned long (*)(const void *))dlsym(RTLD_DEFAULT, "CFArrayGetCount");
    real_release     = (void (*)(const void *))dlsym(RTLD_DEFAULT, "CFRelease");
    real_retain      = (const void *(*)(const void *))dlsym(RTLD_DEFAULT, "CFRetain");
    real_gvIfPresent = (int (*)(CFDictionaryRef, const void *, const void **))dlsym(RTLD_DEFAULT, "CFDictionaryGetValueIfPresent");

    qx_log("钥匙串 copy=%p add=%p update=%p delete=%p",
           (void *)real_copyMatching, (void *)real_itemAdd, (void *)real_itemUpdate, (void *)real_itemDelete);

    /* 信号处理:自愈 + 崩溃记录 */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = qx_handler;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    real_sigaction(SIGSEGV, &sa, NULL);
    real_sigaction(SIGBUS,  &sa, NULL);
    qx_log("[信号] SIGSEGV/SIGBUS 自愈已挂载");

    /* 接管符号槽 */
    int stopped = 0;
    for (i = 0; g_slots[i].name; i++) {
        void *repl = NULL;
        if      (!strcmp(g_slots[i].name, "SecItemCopyMatching")) repl = (void *)qx_SecItemCopyMatching;
        else if (!strcmp(g_slots[i].name, "SecItemAdd"))          repl = (void *)qx_SecItemAdd;
        else if (!strcmp(g_slots[i].name, "SecItemUpdate"))       repl = (void *)qx_SecItemUpdate;
        else if (!strcmp(g_slots[i].name, "SecItemDelete"))       repl = (void *)qx_SecItemDelete;
        else if (!strcmp(g_slots[i].name, "dlsym"))               repl = (void *)qx_dlsym;
        else if (!strcmp(g_slots[i].name, "dlopen"))              repl = (void *)qx_dlopen;
        else if (!strcmp(g_slots[i].name, "sigaction"))           repl = (void *)qx_sigaction;
        else if (!strcmp(g_slots[i].name, "signal"))              repl = (void *)qx_signal;
        if (!repl) continue;
        if (qx_takeover(g_slots[i].name, g_slots[i].va, repl, NULL) == 0) stopped++;
    }
    qx_log("符号槽接管完成:%d 个", stopped);

    /* 网络抓取:NSURLSession 是类簇,实体类会覆盖方法,所以挨个试 */
    {
        static const char *cls[] = { "NSURLSession", "__NSURLSessionLocal",
                                     "NSURLSessionTask", "__NSCFURLSession", NULL };
        int ci;
        for (ci = 0; cls[ci]; ci++) {
            if (!objc_getClass(cls[ci])) continue;
            if (!orig_task_req)
                qx_method_swizzle(cls[ci], "dataTaskWithRequest:completionHandler:",
                                  (void *)qx_task_req, &orig_task_req, 0);
            if (!orig_task_url)
                qx_method_swizzle(cls[ci], "dataTaskWithURL:completionHandler:",
                                  (void *)qx_task_url, &orig_task_url, 0);
        }
    }

    qx_clipboard_timer();
    qx_log("---- 初始化完毕,开始观察 ----");
}
