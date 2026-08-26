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
typedef id (*OITMobileInstallationLookupFn)(id options, id callback);

static id OITSendId(id target, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static id OITSendIdObject(id target, SEL selector, id object) {
    return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, object);
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

static BOOL OITLooksLikeBundleIdentifier(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length >= 3 &&
           [trimmed containsString:@"."] &&
           ![trimmed containsString:@"/"] &&
           ![trimmed containsString:@" "];
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
    if ([value isKindOfClass:NSSet.class]) return [value allObjects];
    if ([value respondsToSelector:@selector(allObjects)]) {
        @try { return [value allObjects]; } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static void OITAppendObjects(NSMutableArray *destination, id value) {
    NSArray *array = OITArrayFromUnknownCollection(value);
    if (array.count > 0) [destination addObjectsFromArray:array];
}

static void OITLoadLaunchServices(void) {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY | RTLD_LOCAL);
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL);
    dlopen("/System/Library/PrivateFrameworks/CoreServicesStore.framework/CoreServicesStore", RTLD_LAZY | RTLD_LOCAL);
}

static Class OITLoadLaunchServicesClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (cls) return cls;
    OITLoadLaunchServices();
    return NSClassFromString(name);
}

static id OITProxyForBundleIdentifier(NSString *bundleID) {
    if (!OITLooksLikeBundleIdentifier(bundleID)) return nil;

    Class proxyClass = OITLoadLaunchServicesClass(@"LSApplicationProxy");
    if (!proxyClass) return nil;

    SEL oneArg = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if ([proxyClass respondsToSelector:oneArg]) {
        @try {
            id proxy = OITSendIdObject(proxyClass, oneArg, bundleID);
            if (proxy) {
                NSString *resolved = OITStringValue(proxy, @[@"bundleIdentifier", @"applicationIdentifier"]);
                if (resolved.length > 0) return proxy;
            }
        } @catch (__unused NSException *exception) {}
    }

    SEL twoArg = NSSelectorFromString(@"applicationProxyForIdentifier:placeholder:");
    if ([proxyClass respondsToSelector:twoArg]) {
        @try {
            id proxy = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(proxyClass, twoArg, bundleID, NO);
            if (proxy) {
                NSString *resolved = OITStringValue(proxy, @[@"bundleIdentifier", @"applicationIdentifier"]);
                if (resolved.length > 0) return proxy;
            }
        } @catch (__unused NSException *exception) {}
    }

    return nil;
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

static NSUInteger OITCollectUsingLSEnumerator(NSMutableArray *rawApps) {
    Class enumeratorClass = OITLoadLaunchServicesClass(@"LSEnumerator");
    if (!enumeratorClass) return 0;

    NSUInteger before = rawApps.count;
    for (NSString *selectorName in @[@"enumeratorForApplicationProxiesWithOptions:",
                                      @"enumeratorForApplicationRecordsWithOptions:"]) {
        SEL makeSel = NSSelectorFromString(selectorName);
        if (![enumeratorClass respondsToSelector:makeSel]) continue;

        for (NSNumber *options in @[@0, @1]) {
            @try {
                id enumerator = OITSendIdInteger(enumeratorClass, makeSel, options.integerValue);
                if (!enumerator) continue;

                if ([enumerator respondsToSelector:@selector(allObjects)]) {
                    NSArray *objects = [enumerator allObjects];
                    if (objects.count > 0) [rawApps addObjectsFromArray:objects];
                } else {
                    for (NSUInteger guard = 0; guard < 4096; guard++) {
                        id object = [enumerator nextObject];
                        if (!object) break;
                        [rawApps addObject:object];
                    }
                }

                if (rawApps.count > before) return rawApps.count - before;
            } @catch (__unused NSException *exception) {}
        }
    }

    return rawApps.count - before;
}

static NSUInteger OITCollectUsingWorkspaceEnumerators(id workspace, NSMutableArray *rawApps) {
    NSUInteger before = rawApps.count;
    OITApplicationBlock appendBlock = ^(id proxy) {
        if (proxy) [rawApps addObject:proxy];
    };

    SEL appEnumSel = NSSelectorFromString(@"enumerateApplicationsOfType:block:");
    if ([workspace respondsToSelector:appEnumSel]) {
        for (NSUInteger type = 0; type <= 2; type++) {
            @try { OITSendEnumerate(workspace, appEnumSel, type, appendBlock); }
            @catch (__unused NSException *exception) {}
        }
    }

    if (rawApps.count == before) {
        SEL appLegacySel = NSSelectorFromString(@"enumerateApplicationsOfType:legacySPI:block:");
        if ([workspace respondsToSelector:appLegacySel]) {
            for (NSUInteger type = 0; type <= 2; type++) {
                @try { OITSendEnumerateLegacy(workspace, appLegacySel, type, YES, appendBlock); }
                @catch (__unused NSException *exception) {}
            }
        }
    }

    if (rawApps.count == before) {
        SEL bundleEnumSel = NSSelectorFromString(@"enumerateBundlesOfType:block:");
        if ([workspace respondsToSelector:bundleEnumSel]) {
            for (NSUInteger type = 0; type <= 2; type++) {
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
        } @catch (__unused NSException *exception) {}
    }

    if (rawApps.count == before) {
        SEL typeSel = NSSelectorFromString(@"applicationsOfType:");
        if ([workspace respondsToSelector:typeSel]) {
            for (NSUInteger type = 0; type <= 2; type++) {
                @try { OITAppendObjects(rawApps, OITSendIdInteger(workspace, typeSel, type)); }
                @catch (__unused NSException *exception) {}
            }
            if (rawApps.count > before && usedSelector) *usedSelector = @"applicationsOfType:";
        }
    }

    return rawApps.count - before;
}

static NSString *OITBundleIDFromDictionary(NSDictionary *dictionary) {
    for (NSString *key in @[@"__OITBundleID",
                             @"CFBundleIdentifier",
                             @"BundleIdentifier",
                             @"bundleIdentifier",
                             @"ApplicationIdentifier",
                             @"applicationIdentifier"]) {
        id value = dictionary[key];
        if ([value isKindOfClass:NSString.class] && OITLooksLikeBundleIdentifier(value)) return value;
    }
    return nil;
}

static NSString *OITNameFromDictionary(NSDictionary *dictionary) {
    for (NSString *key in @[@"CFBundleDisplayName",
                             @"CFBundleName",
                             @"DisplayName",
                             @"LocalizedName",
                             @"Name",
                             @"name"]) {
        id value = dictionary[key];
        if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
    }
    return nil;
}

static void OITAppendMobileInstallationObject(NSMutableArray *rawApps, id object, NSString *keyHint, NSUInteger depth) {
    if (!object || depth > 5) return;

    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = object;
        NSString *bundleID = OITBundleIDFromDictionary(dictionary);
        if (!bundleID && OITLooksLikeBundleIdentifier(keyHint)) bundleID = keyHint;

        if (bundleID) {
            NSMutableDictionary *descriptor = [dictionary mutableCopy];
            descriptor[@"__OITBundleID"] = bundleID;
            [rawApps addObject:descriptor];
            return;
        }

        [dictionary enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            NSString *nextHint = [key isKindOfClass:NSString.class] ? key : nil;
            OITAppendMobileInstallationObject(rawApps, value, nextHint, depth + 1);
        }];
        return;
    }

    if ([object isKindOfClass:NSArray.class] || [object isKindOfClass:NSSet.class]) {
        for (id value in object) OITAppendMobileInstallationObject(rawApps, value, nil, depth + 1);
        return;
    }

    if ([object isKindOfClass:NSString.class] && OITLooksLikeBundleIdentifier(object)) {
        [rawApps addObject:object];
    }
}

static NSUInteger OITCollectUsingMobileInstallation(NSMutableArray *rawApps) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY | RTLD_LOCAL);
    if (!handle) return 0;

    OITMobileInstallationLookupFn lookup = (OITMobileInstallationLookupFn)dlsym(handle, "MobileInstallationLookup");
    if (!lookup) return 0;

    NSUInteger before = rawApps.count;
    for (NSDictionary *options in @[@{@"ApplicationType": @"Any"},
                                     @{@"ApplicationType": @"User"},
                                     @{@"ApplicationType": @"System"},
                                     @{}]) {
        @try {
            id result = lookup(options, nil);
            OITAppendMobileInstallationObject(rawApps, result, nil, 0);
        } @catch (__unused NSException *exception) {}
        if (rawApps.count > before) break;
    }

    return rawApps.count - before;
}

static NSUInteger OITCollectUsingReadableAppDirectories(NSMutableArray *rawApps) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *roots = @[@"/Applications",
                                    @"/System/Applications",
                                    @"/private/var/containers/Bundle/Application",
                                    @"/var/containers/Bundle/Application"];
    NSUInteger before = rawApps.count;

    for (NSString *root in roots) {
        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) continue;

        NSURL *rootURL = [NSURL fileURLWithPath:root isDirectory:YES];
        NSDirectoryEnumerator<NSURL *> *enumerator =
            [fm enumeratorAtURL:rootURL
     includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                        options:NSDirectoryEnumerationSkipsHiddenFiles
                   errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];

        for (NSURL *url in enumerator) {
            if (![url.pathExtension.lowercaseString isEqualToString:@"app"]) continue;

            NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@"Info.plist"]];
            NSString *bundleID = OITBundleIDFromDictionary(info ?: @{});
            if (bundleID.length > 0) {
                NSMutableDictionary *descriptor = info ? [info mutableCopy] : [NSMutableDictionary dictionary];
                descriptor[@"__OITBundleID"] = bundleID;
                descriptor[@"__OITBundleURL"] = url.path ?: @"";
                [rawApps addObject:descriptor];
            }
            [enumerator skipDescendants];
        }
    }

    return rawApps.count - before;
}

static NSString *OITBundleIDForRawObject(id raw) {
    if ([raw isKindOfClass:NSString.class]) return OITLooksLikeBundleIdentifier(raw) ? raw : nil;
    if ([raw isKindOfClass:NSDictionary.class]) return OITBundleIDFromDictionary(raw);
    return OITStringValue(raw, @[@"bundleIdentifier", @"applicationIdentifier"]);
}

static NSString *OITNameForRawObject(id raw) {
    if ([raw isKindOfClass:NSDictionary.class]) return OITNameFromDictionary(raw);
    if ([raw isKindOfClass:NSString.class]) return nil;
    return OITStringValue(raw, @[@"localizedName", @"localizedShortName", @"itemName", @"name"]);
}

static OITInstalledApplication *OITBuildInstalledApplication(id raw) {
    NSString *bundleID = OITBundleIDForRawObject(raw);
    if (bundleID.length == 0) return nil;

    id proxy = (![raw isKindOfClass:NSString.class] && ![raw isKindOfClass:NSDictionary.class]) ? raw : OITProxyForBundleIdentifier(bundleID);
    NSString *name = OITStringValue(proxy, @[@"localizedName", @"localizedShortName", @"itemName", @"name"]);
    if (name.length == 0) name = OITNameForRawObject(raw);
    if (name.length == 0) name = bundleID;

    UIImage *icon = OITIconForProxy(proxy, bundleID);
    return [[OITInstalledApplication alloc] initWithBundleIdentifier:bundleID displayName:name icon:icon];
}

+ (NSArray<OITInstalledApplication *> *)installedApplications {
    NSMutableArray *rawApps = [NSMutableArray array];
    NSMutableArray<NSString *> *methods = [NSMutableArray array];

    NSUInteger lsEnumCount = OITCollectUsingLSEnumerator(rawApps);
    [methods addObject:[NSString stringWithFormat:@"LSEnum:%lu", (unsigned long)lsEnumCount]];

    Class workspaceClass = OITLoadLaunchServicesClass(@"LSApplicationWorkspace");
    id workspace = nil;
    if (workspaceClass) {
        SEL defaultWorkspaceSel = NSSelectorFromString(@"defaultWorkspace");
        if ([workspaceClass respondsToSelector:defaultWorkspaceSel]) {
            @try { workspace = OITSendId(workspaceClass, defaultWorkspaceSel); }
            @catch (__unused NSException *exception) {}
        }
    }

    NSUInteger workspaceEnumCount = 0;
    NSUInteger arrayCount = 0;
    NSString *arraySelector = nil;
    if (workspace) {
        workspaceEnumCount = OITCollectUsingWorkspaceEnumerators(workspace, rawApps);
        arrayCount = OITCollectUsingWorkspaceArrays(workspace, rawApps, &arraySelector);
    }
    [methods addObject:[NSString stringWithFormat:@"LSWorkspace:%lu/%lu", (unsigned long)workspaceEnumCount, (unsigned long)arrayCount]];

    NSUInteger miCount = OITCollectUsingMobileInstallation(rawApps);
    [methods addObject:[NSString stringWithFormat:@"MI:%lu", (unsigned long)miCount]];

    NSUInteger filesCount = OITCollectUsingReadableAppDirectories(rawApps);
    [methods addObject:[NSString stringWithFormat:@"Files:%lu", (unsigned long)filesCount]];

    NSMutableDictionary<NSString *, OITInstalledApplication *> *unique = [NSMutableDictionary dictionary];
    for (id raw in rawApps) {
        OITInstalledApplication *app = OITBuildInstalledApplication(raw);
        if (!app) continue;
        OITInstalledApplication *existing = unique[app.bundleIdentifier];
        if (!existing || (!existing.icon && app.icon)) unique[app.bundleIdentifier] = app;
    }

    NSArray *sorted = [unique.allValues sortedArrayUsingComparator:^NSComparisonResult(OITInstalledApplication *a, OITInstalledApplication *b) {
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];

    NSString *methodText = [methods componentsJoinedByString:@" · "];
    if (sorted.count == 0) {
        gOITScanStatus = [NSString stringWithFormat:@"iOS закрыла массовый список для этого процесса · %@", methodText];
        return @[];
    }

    gOITScanStatus = [NSString stringWithFormat:@"Найдено: %lu · %@", (unsigned long)sorted.count, methodText];
    return sorted;
}

+ (nullable OITInstalledApplication *)installedApplicationForBundleIdentifier:(NSString *)bundleIdentifier {
    NSString *bundleID = [bundleIdentifier stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!OITLooksLikeBundleIdentifier(bundleID)) return nil;

    id proxy = OITProxyForBundleIdentifier(bundleID);
    if (!proxy) return nil;

    NSString *resolvedID = OITStringValue(proxy, @[@"bundleIdentifier", @"applicationIdentifier"]);
    if (resolvedID.length == 0) return nil;

    NSString *name = OITStringValue(proxy, @[@"localizedName", @"localizedShortName", @"itemName", @"name"]);
    if (name.length == 0) name = resolvedID;

    UIImage *icon = OITIconForProxy(proxy, resolvedID);
    return [[OITInstalledApplication alloc] initWithBundleIdentifier:resolvedID displayName:name icon:icon];
}

+ (NSString *)scanStatus {
    return gOITScanStatus ?: @"";
}

@end
