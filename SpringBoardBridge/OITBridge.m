#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSDictionary<NSString *, NSData *> *gTheme = nil;
static CFMessagePortRef gPort = NULL;
static CFRunLoopSourceRef gSource = NULL;
static IMP gOriginalLayout = NULL;

static NSString * const kThemePath =
    @"/var/mobile/Library/OpaqueIconThemer/Theme.plist";

static id Msg0(id obj, const char *name) {
    if (!obj) return nil;
    SEL sel = sel_registerName(name);
    if (![obj respondsToSelector:sel]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(obj, sel);
}

static BOOL MsgObj(id obj, const char *name, id value) {
    if (!obj) return NO;
    SEL sel = sel_registerName(name);
    if (![obj respondsToSelector:sel]) return NO;
    ((void(*)(id,SEL,id))objc_msgSend)(obj, sel, value);
    return YES;
}

static void MsgVoid(id obj, const char *name) {
    if (!obj) return;
    SEL sel = sel_registerName(name);
    if ([obj respondsToSelector:sel]) {
        ((void(*)(id,SEL))objc_msgSend)(obj, sel);
    }
}

static NSString *BundleIDForIconView(id iconView) {
    id icon = Msg0(iconView, "icon");
    if (!icon) return nil;

    const char *sels[] = {
        "applicationBundleID",
        "bundleIdentifier",
        "leafIdentifier",
        "nodeIdentifier",
        "uniqueIdentifier"
    };

    for (NSUInteger i = 0; i < sizeof(sels)/sizeof(sels[0]); i++) {
        id value = Msg0(icon, sels[i]);
        if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
    }

    id app = Msg0(icon, "application");
    if (app) {
        for (NSUInteger i = 0; i < 2; i++) {
            id value = Msg0(app, sels[i]);
            if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
        }
    }
    return nil;
}

static id InnerImageView(id iconView) {
    id direct = Msg0(iconView, "_iconImageView");
    if (direct) return direct;

    Class cls = object_getClass(iconView);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, "_iconImageView");
        if (ivar) {
            id value = object_getIvar(iconView, ivar);
            if (value) return value;
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static void RequestRefresh(id iconView) {
    MsgVoid(iconView, "setNeedsLayout");
    MsgVoid(iconView, "_updateIconImageView");
    MsgVoid(iconView, "updateIconImageView");
}

static void ApplyImage(id iconView, UIImage *image) {
    if (!iconView || !image) return;

    // Important: badge/accessory subviews are deliberately untouched.
    BOOL usedOverride = MsgObj(iconView, "setOverrideImage:", image);
    if (!usedOverride) {
        if (!MsgObj(iconView, "setIconImage:", image)) {
            MsgObj(iconView, "_setIconImage:", image);
        }
    }

    id inner = InnerImageView(iconView);
    if (inner) {
        if (!MsgObj(inner, "setDisplayedImage:", image)) {
            MsgObj(inner, "setImage:", image);
        }
    }

    RequestRefresh(iconView);
}

static void ClearImage(id iconView) {
    MsgObj(iconView, "setOverrideImage:", nil);
    id inner = InnerImageView(iconView);
    if (inner) {
        MsgVoid(inner, "setNeedsLayout");
        MsgVoid(inner, "updateImage");
    }
    RequestRefresh(iconView);
}

static void ApplyToView(id iconView) {
    NSString *bundleID = BundleIDForIconView(iconView);
    if (bundleID.length == 0) return;

    NSData *data = gTheme[bundleID];
    if (![data isKindOfClass:NSData.class] || data.length == 0) return;

    UIImage *image = [UIImage imageWithData:data scale:UIScreen.mainScreen.scale];
    if (image) ApplyImage(iconView, image);
}

static BOOL LooksLikeIconView(UIView *view) {
    NSString *n = NSStringFromClass(view.class);
    return [n containsString:@"SBIconView"] || [n containsString:@"SBHIconView"];
}

static void Walk(UIView *view, BOOL clear) {
    if (!view) return;
    if (LooksLikeIconView(view)) {
        if (clear) ClearImage(view);
        else ApplyToView(view);
    }
    for (UIView *sub in view.subviews) Walk(sub, clear);
}

static void RefreshVisible(BOOL clear) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = UIApplication.sharedApplication;

        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                Walk(w, clear);
                [w setNeedsLayout];
            }
        }
    });
}

static void LayoutHook(id self, SEL _cmd) {
    if (gOriginalLayout) ((void(*)(id,SEL))gOriginalLayout)(self, _cmd);
    if (gTheme.count > 0) ApplyToView(self);
}

static void InstallHook(void) {
    Class cls = objc_getClass("SBIconView");
    if (!cls) cls = objc_getClass("SBHIconView");
    if (!cls) return;

    Method m = class_getInstanceMethod(cls, @selector(layoutSubviews));
    if (!m) return;

    IMP current = method_getImplementation(m);
    if (current == (IMP)LayoutHook) return;

    gOriginalLayout = current;
    method_setImplementation(m, (IMP)LayoutHook);
}

static BOOL CleanTheme(id obj, NSDictionary **out) {
    if (![obj isKindOfClass:NSDictionary.class]) return NO;

    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (![key isKindOfClass:NSString.class]) return;
        if (![value isKindOfClass:NSData.class]) return;
        if ([key length] == 0 || [value length] == 0 || [value length] > 2*1024*1024) return;
        if (![UIImage imageWithData:value]) return;
        clean[key] = value;
    }];

    if (out) *out = [clean copy];
    return YES;
}

static void Persist(void) {
    NSString *dir = [kThemePath stringByDeletingLastPathComponent];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];

    if (gTheme.count == 0) {
        [NSFileManager.defaultManager removeItemAtPath:kThemePath error:nil];
        return;
    }

    NSData *data = [NSPropertyListSerialization dataWithPropertyList:gTheme
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:nil];
    [data writeToFile:kThemePath atomically:YES];
}

static void LoadPersisted(void) {
    NSData *data = [NSData dataWithContentsOfFile:kThemePath];
    if (!data.length) { gTheme = @{}; return; }

    id obj = [NSPropertyListSerialization propertyListWithData:data
                                                       options:NSPropertyListImmutable
                                                        format:NULL
                                                         error:nil];
    NSDictionary *clean = nil;
    gTheme = CleanTheme(obj, &clean) ? clean : @{};
}

static NSData *Reply(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data;
}

static CFDataRef PortCallback(CFMessagePortRef local, SInt32 msgid,
                              CFDataRef data, void *info) {
    @autoreleasepool {
        if (msgid == 1) return (CFDataRef)CFBridgingRetain(Reply(@"pong"));

        if (msgid == 2) {
            NSData *payload = (__bridge NSData *)data;
            if (!payload.length || payload.length > 80*1024*1024)
                return (CFDataRef)CFBridgingRetain(Reply(@"error:payload"));

            id obj = [NSPropertyListSerialization propertyListWithData:payload
                                                               options:NSPropertyListImmutable
                                                                format:NULL
                                                                 error:nil];
            NSDictionary *clean = nil;
            if (!CleanTheme(obj, &clean))
                return (CFDataRef)CFBridgingRetain(Reply(@"error:plist"));

            gTheme = clean;
            Persist();
            RefreshVisible(NO);

            return (CFDataRef)CFBridgingRetain(
                Reply([NSString stringWithFormat:@"ok:applied:%lu",
                       (unsigned long)gTheme.count])
            );
        }

        if (msgid == 3) {
            gTheme = @{};
            Persist();
            RefreshVisible(YES);
            return (CFDataRef)CFBridgingRetain(Reply(@"ok:cleared"));
        }

        if (msgid == 4) {
            return (CFDataRef)CFBridgingRetain(
                Reply([NSString stringWithFormat:@"Bridge active • theme %lu",
                       (unsigned long)gTheme.count])
            );
        }

        if (msgid == 5) {
            LoadPersisted();
            RefreshVisible(NO);
            return (CFDataRef)CFBridgingRetain(Reply(@"ok:reloaded"));
        }

        return (CFDataRef)CFBridgingRetain(Reply(@"error:unknown"));
    }
}

void OITBridgeStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LoadPersisted();
        InstallHook();

        CFMessagePortContext ctx = {0, NULL, NULL, NULL, NULL};
        Boolean freeInfo = false;
        gPort = CFMessagePortCreateLocal(
            kCFAllocatorDefault,
            CFSTR("com.nomadvorga.opaqueiconthemer.bridge"),
            PortCallback,
            &ctx,
            &freeInfo
        );

        if (gPort) {
            gSource = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, gPort, 0);
            if (gSource) CFRunLoopAddSource(CFRunLoopGetMain(), gSource, kCFRunLoopCommonModes);
        }

        if (gTheme.count > 0) RefreshVisible(NO);
    });
}

__attribute__((constructor))
static void OITCtor(void) {
    @autoreleasepool {
        if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            OITBridgeStart();
        }
    }
}
