#import "OITPrivateAppScanner.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@implementation OITInstalledApplication
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                              displayName:(NSString *)displayName
                                    icon:(UIImage *)icon {
    self = [super init];
    if (self) {
        _bundleIdentifier = [bundleIdentifier copy];
        _displayName = [displayName copy];
        _icon = icon;
    }
    return self;
}
@end

@implementation OITPrivateAppScanner

static NSString *gOITScanStatus = @"Не запускалось";

typedef void (^OITApplicationBlock)(id proxy);

static id OITSendId(id target, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static id OITSendIdInteger(id target, SEL selector, NSInteger value) {
    return ((id (*)(id, SEL, NSInteger))objc_msgSend)(target, selector, value);
}

static id OITSendIdIntegerObject(id target, SEL selector, NSInteger value, id object) {
    return ((id (*)(id, SEL, NSInteger, id))objc_msgSend)(target, selector, value, object);
}

static id OITSendIconClassMethod(id target, SEL selector, NSString *bundleID, NSInteger format, CGFloat scale) {
    return ((id (*)(id, SEL, id, NSInteger, CGFloat))objc_msgSend)(target, selector, bundleID, format, scale);
}

static void OITSendEnumerate(id target, SEL selector, NSUInteger type, OITApplicationBlock block) {
    ((void (*)(id, SEL, NSUInteger, id))objc_msgSend)(target, selector, type, block);
}

static void OITSendEnumerateLegacy(id target, SEL selector, NSUInteger type, BOOL legacy, OITApplicationBlock block) {
    ((void (*)(id, SEL, NSUInteger, BOOL, id))objc_msgSend)(target, selector, type, legacy, block);
}

static NSString *OITStringValue(id object, NSArray<NSString *> *selectorNames) {
    for (NSString *name in selectorNames) {
        SEL sel = NSSelectorFromString(name);
        if (![object respondsToSelector:sel]) continue;
        @try {
            id value = OITSendId(object, sel);
            if ([value isKindOfClass:NSString.class] && [value length] > 0) {
                return value;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

static NSArray *OITArrayFromUnknownCollection(id value) {
    if ([value isKindOfClass:NSArray.class]) return value;
    if ([value respondsToSelector:@selector(allObjects)]) {
        @try { return [value allObjects]; } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static void OITAppendObjects(NSMutableArray *destination, id value) {
    NSArray *array = OITArrayFromUnknownCollection(value);
    if (array.count > 0) [destination addObjectsFromArray:array];
}

static UIImage *OITIconForProxy(id proxy, NSString *bundleID) {
    NSArray<NSNumber *> *variants = @[@2, @1, @0, @6, @10];

    SEL iconDataSel = NSSelectorFromString(@"iconDataForVariant:");
    if ([proxy respondsToSelector:iconDataSel]) {
        for (NSNumber *variant in variants) {
            @try {
                id data = OITSendIdInteger(proxy, iconDataSel, variant.integerValue);
                if ([data isKindOfClass:NSData.class]) {
                    UIImage *image = [UIImage imageWithData:data];
                    if (image) return image;
                }
            } @catch (__unused NSException *exception) {}
        }
    }

    SEL iconDataOptionsSel = NSSelectorFromString(@"iconDataForVariant:withOptions:");
    if ([proxy respondsToSelector:iconDataOptionsSel]) {
        for (NSNumber *variant in variants) {
            @try {
                id data = OITSendIdIntegerObject(proxy, iconDataOptionsSel, variant.integerValue, @{});
                if ([data isKindOfClass:NSData.class]) {
                    UIImage *image = [UIImage imageWithData:data];
                    if (image) return image;
                }
            } @catch (__unused NSException *exception) {}
        }
    }

    SEL imageSel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    Class imageClass = UIImage.class;
    if ([imageClass respondsToSelector:imageSel]) {
        CGFloat scale = UIScreen.mainScreen.scale;
        for (NSNumber *format in @[@2, @1, @0]) {
            @try {
                id result = OITSendIconClassMethod(imageClass, imageSel, bundleID, format.integerValue, scale);
                if ([result isKindOfClass:UIImage.class]) return result;
            } @catch (__unused NSException *exception) {}
        }
    }

    return nil;
}

static Class OITLoadLaunchServicesClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (cls) return cls;

    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY | RTLD_LOCAL);
    cls = NSClassFromString(name);
    if (cls) return cls;

    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL);
    return NSClassFromString(name);
}

static NSUInteger OITCollectUsingLSEnumerator(NSMutableArray *rawApps) {
    Class enumeratorClass = OITLoadLaunchServicesClass(@"LSEnumerator");
    SEL makeSel = NSSelectorFromString(@"enumeratorForApplicationProxiesWithOptions:");
    if (!enumeratorClass || ![enumeratorClass respondsToSelector:makeSel]) return 0;

    NSUInteger before = rawApps.count;
    for (NSNumber *options in @[@0, @1]) {
        @try {
            id enumerator = OITSendIdInteger(enumeratorClass, makeSel, options.integerValue);
            if (!enumerator) continue;
            for (NSUInteger guard = 0; guard < 4096; guard++) {
                id object = [enumerator nextObject];
                if (!object) break;
                [rawApps addObject:object];
            }
            if (rawApps.count > before) break;
        } @catch (__unused NSException *exception) {
        }
    }
    return rawApps.count - before;
}

static NSUInteger OITCollectUsingWorkspaceEnumerators(id workspace, NSMutableArray *rawApps) {
    NSUInteger before = rawApps.count;
    NSMutableSet<NSString *> *attempted = [NSMutableSet set];

    OITApplicationBlock appendBlock = ^(id proxy) {
        if (proxy) [rawApps addObject:proxy];
    };

    SEL appEnumSel = NSSelectorFromString(@"enumerateApplicationsOfType:block:");
    if ([workspace respondsToSelector:appEnumSel]) {
        [attempted addObject:@"enumerateApplicationsOfType:block:"];
        for (NSUInteger type = 0; type <= 1; type++) {
            @try { OITSendEnumerate(workspace, appEnumSel, type, appendBlock); }
            @catch (__unused NSException *exception) {}
        }
    }

    if (rawApps.count == before) {
        SEL appLegacySel = NSSelectorFromString(@"enumerateApplicationsOfType:legacySPI:block:");
        if ([workspace respondsToSelector:appLegacySel]) {
            [attempted addObject:@"enumerateApplicationsOfType:legacySPI:block:"];
            for (NSUInteger type = 0; type <= 1; type++) {
                @try { OITSendEnumerateLegacy(workspace, appLegacySel, type, YES, appendBlock); }
                @catch (__unused NSException *exception) {}
            }
        }
    }

    if (rawApps.count == before) {
        SEL bundleEnumSel = NSSelectorFromString(@"enumerateBundlesOfType:block:");
        if ([workspace respondsToSelector:bundleEnumSel]) {
            [attempted addObject:@"enumerateBundlesOfType:block:"];
            for (NSUInteger type = 0; type <= 1; type++) {
                @try { OITSendEnumerate(workspace, bundleEnumSel, type, appendBlock); }
                @catch (__unused NSException *exception) {}
            }
        }
    }

    return rawApps.count - before;
}

static NSUInteger OITCollectUsingWorkspaceArrays(id workspace, NSMutableArray *rawApps, NSString **usedSelector) {
    NSUInteger before = rawApps.count;

    for (NSString *selectorName in @[@"allInstalledApplications",
                                      @"allApplications",
                                      @"unrestrictedApplications",
                                      @"installedApplications"]) {
        SEL sel = NSSelectorFromString(selectorName);
        if (![workspace respondsToSelector:sel]) continue;
        @try {
            id value = OITSendId(workspace, sel);
            NSUInteger countBefore = rawApps.count;
            OITAppendObjects(rawApps, value);
            if (rawApps.count > countBefore) {
                if (usedSelector) *usedSelector = selectorName;
                break;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    if (rawApps.count == before) {
        SEL typeSel = NSSelectorFromString(@"applicationsOfType:");
        if ([workspace respondsToSelector:typeSel]) {
            for (NSUInteger type = 0; type <= 1; type++) {
                @try { OITAppendObjects(rawApps, OITSendIdInteger(workspace, typeSel, type)); }
                @catch (__unused NSException *exception) {}
            }
            if (rawApps.count > before && usedSelector) *usedSelector = @"applicationsOfType:";
        }
    }

    return rawApps.count - before;
}

+ (NSArray<OITInstalledApplication *> *)installedApplications {
    NSMutableArray *rawApps = [NSMutableArray array];
    NSMutableArray<NSString *> *methods = [NSMutableArray array];

    NSUInteger enumCount = OITCollectUsingLSEnumerator(rawApps);
    if (enumCount > 0) {
        [methods addObject:[NSString stringWithFormat:@"LSEnumerator:%lu", (unsigned long)enumCount]];
    }

    Class workspaceClass = OITLoadLaunchServicesClass(@"LSApplicationWorkspace");
    id workspace = nil;
    if (workspaceClass) {
        SEL defaultWorkspaceSel = NSSelectorFromString(@"defaultWorkspace");
        if ([workspaceClass respondsToSelector:defaultWorkspaceSel]) {
            @try { workspace = OITSendId(workspaceClass, defaultWorkspaceSel); }
            @catch (__unused NSException *exception) {}
        }
    }

    if (workspace) {
        NSUInteger workspaceEnumCount = OITCollectUsingWorkspaceEnumerators(workspace, rawApps);
        if (workspaceEnumCount > 0) {
            [methods addObject:[NSString stringWithFormat:@"enumerate:%lu", (unsigned long)workspaceEnumCount]];
        }

        NSString *arraySelector = nil;
        NSUInteger arrayCount = OITCollectUsingWorkspaceArrays(workspace, rawApps, &arraySelector);
        if (arrayCount > 0) {
            [methods addObject:[NSString stringWithFormat:@"%@:%lu", arraySelector ?: @"array", (unsigned long)arrayCount]];
        }
    }

    if (rawApps.count == 0) {
        if (!workspaceClass && !OITLoadLaunchServicesClass(@"LSEnumerator")) {
            gOITScanStatus = @"LaunchServices недоступен в этом процессе";
        } else if (!workspace) {
            gOITScanStatus = @"LaunchServices загружен, но workspace недоступен";
        } else {
            gOITScanStatus = @"LaunchServices доступен, но iOS не вернула ни одного приложения";
        }
        return @[];
    }

    NSMutableDictionary<NSString *, OITInstalledApplication *> *unique = [NSMutableDictionary dictionary];

    for (id proxy in rawApps) {
        NSString *bundleID = OITStringValue(proxy, @[@"bundleIdentifier", @"applicationIdentifier"]);
        if (bundleID.length == 0) continue;

        NSString *name = OITStringValue(proxy, @[@"localizedName", @"localizedShortName", @"itemName", @"name"]);
        if (name.length == 0) name = bundleID;

        UIImage *icon = OITIconForProxy(proxy, bundleID);
        OITInstalledApplication *existing = unique[bundleID];
        if (!existing || (!existing.icon && icon)) {
            unique[bundleID] = [[OITInstalledApplication alloc] initWithBundleIdentifier:bundleID
                                                                            displayName:name
                                                                                  icon:icon];
        }
    }

    NSArray *sorted = [unique.allValues sortedArrayUsingComparator:^NSComparisonResult(OITInstalledApplication *a, OITInstalledApplication *b) {
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];

    NSString *methodText = methods.count > 0 ? [methods componentsJoinedByString:@" · "] : @"LaunchServices";
    gOITScanStatus = [NSString stringWithFormat:@"Найдено: %lu · %@",
                      (unsigned long)sorted.count,
                      methodText];
    return sorted;
}

+ (NSString *)scanStatus {
    return gOITScanStatus ?: @"";
}

@end
