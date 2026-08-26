#import "OITOnDeviceAppDiscovery.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@implementation OITOnDeviceAppDiscovery

static NSString *gOITOnDeviceStatus = @"Не запускалось";

static id OITODSendId(id target, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static id OITODSendObject(id target, SEL selector, id object) {
    return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, object);
}

static id OITODSendInteger(id target, SEL selector, NSInteger value) {
    return ((id (*)(id, SEL, NSInteger))objc_msgSend)(target, selector, value);
}

static id OITODSendIntegerObject(id target, SEL selector, NSInteger value, id object) {
    return ((id (*)(id, SEL, NSInteger, id))objc_msgSend)(target, selector, value, object);
}

static id OITODSendIcon(id target, SEL selector, NSString *bundleID, NSInteger format, CGFloat scale) {
    return ((id (*)(id, SEL, id, NSInteger, CGFloat))objc_msgSend)(target, selector, bundleID, format, scale);
}

static void OITODLoadLaunchServices(void) {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY | RTLD_LOCAL);
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL);
    dlopen("/System/Library/PrivateFrameworks/CoreServicesStore.framework/CoreServicesStore", RTLD_LAZY | RTLD_LOCAL);
}

static Class OITODClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (cls) return cls;
    OITODLoadLaunchServices();
    return NSClassFromString(name);
}

static id OITODWorkspace(void) {
    Class workspaceClass = OITODClass(@"LSApplicationWorkspace");
    if (!workspaceClass) return nil;
    SEL selector = NSSelectorFromString(@"defaultWorkspace");
    if (![workspaceClass respondsToSelector:selector]) return nil;
    @try {
        return OITODSendId(workspaceClass, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray *OITODArray(id value) {
    if ([value isKindOfClass:NSArray.class]) return value;
    if ([value isKindOfClass:NSSet.class]) return [value allObjects];
    if ([value respondsToSelector:@selector(allObjects)]) {
        @try { return [value allObjects]; }
        @catch (__unused NSException *exception) {}
    }
    return nil;
}

static void OITODAppendCollection(NSMutableArray *destination, id value) {
    NSArray *array = OITODArray(value);
    if (array.count > 0) [destination addObjectsFromArray:array];
}

static NSString *OITODStringValue(id object, NSArray<NSString *> *selectorNames) {
    if (!object) return nil;
    for (NSString *name in selectorNames) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) continue;
        @try {
            id value = OITODSendId(object, selector);
            if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static NSString *OITODBundleID(id proxy) {
    return OITODStringValue(proxy, @[@"bundleIdentifier", @"applicationIdentifier"]);
}

static NSString *OITODDisplayName(id proxy, NSString *bundleID) {
    NSString *name = OITODStringValue(proxy, @[@"localizedName", @"localizedShortName", @"itemName", @"name"]);
    return name.length > 0 ? name : bundleID;
}

static UIImage *OITODIconForProxy(id proxy, NSString *bundleID) {
    if (!proxy || bundleID.length == 0) return nil;

    NSArray<NSNumber *> *variants = @[@2, @1, @0, @6, @10];
    SEL dataSelector = NSSelectorFromString(@"iconDataForVariant:");
    if ([proxy respondsToSelector:dataSelector]) {
        for (NSNumber *variant in variants) {
            @try {
                id data = OITODSendInteger(proxy, dataSelector, variant.integerValue);
                if ([data isKindOfClass:NSData.class]) {
                    UIImage *image = [UIImage imageWithData:data];
                    if (image) return image;
                }
            } @catch (__unused NSException *exception) {}
        }
    }

    SEL optionsSelector = NSSelectorFromString(@"iconDataForVariant:withOptions:");
    if ([proxy respondsToSelector:optionsSelector]) {
        for (NSNumber *variant in variants) {
            @try {
                id data = OITODSendIntegerObject(proxy, optionsSelector, variant.integerValue, @{});
                if ([data isKindOfClass:NSData.class]) {
                    UIImage *image = [UIImage imageWithData:data];
                    if (image) return image;
                }
            } @catch (__unused NSException *exception) {}
        }
    }

    SEL imageSelector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([UIImage.class respondsToSelector:imageSelector]) {
        CGFloat scale = UIScreen.mainScreen.scale;
        for (NSNumber *format in @[@2, @1, @0]) {
            @try {
                id image = OITODSendIcon(UIImage.class, imageSelector, bundleID, format.integerValue, scale);
                if ([image isKindOfClass:UIImage.class]) return image;
            } @catch (__unused NSException *exception) {}
        }
    }

    return nil;
}

static NSUInteger OITODCollectSchemes(id workspace, NSMutableArray *rawApps, NSUInteger *schemeCount) {
    NSMutableOrderedSet<NSString *> *schemes = [NSMutableOrderedSet orderedSet];

    for (NSString *selectorName in @[@"publicURLSchemes", @"privateURLSchemes"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![workspace respondsToSelector:selector]) continue;
        @try {
            NSArray *values = OITODArray(OITODSendId(workspace, selector));
            for (id value in values) {
                if ([value isKindOfClass:NSString.class] && [value length] > 0) [schemes addObject:value];
            }
        } @catch (__unused NSException *exception) {}
    }

    if (schemeCount) *schemeCount = schemes.count;
    NSUInteger before = rawApps.count;
    SEL handlersSelector = NSSelectorFromString(@"applicationsAvailableForHandlingURLScheme:");
    SEL openSelector = NSSelectorFromString(@"applicationsAvailableForOpeningURL:");
    SEL legacyOpenSelector = NSSelectorFromString(@"applicationsAvailableForOpeningURL:legacySPI:");

    NSUInteger visited = 0;
    for (NSString *scheme in schemes) {
        if (visited++ >= 4096) break;
        NSUInteger countBeforeScheme = rawApps.count;

        if ([workspace respondsToSelector:handlersSelector]) {
            @try { OITODAppendCollection(rawApps, OITODSendObject(workspace, handlersSelector, scheme)); }
            @catch (__unused NSException *exception) {}
        }

        if (rawApps.count == countBeforeScheme) {
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://", scheme]];
            if (url && [workspace respondsToSelector:openSelector]) {
                @try { OITODAppendCollection(rawApps, OITODSendObject(workspace, openSelector, url)); }
                @catch (__unused NSException *exception) {}
            }
            if (url && rawApps.count == countBeforeScheme && [workspace respondsToSelector:legacyOpenSelector]) {
                @try {
                    id value = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(workspace, legacyOpenSelector, url, YES);
                    OITODAppendCollection(rawApps, value);
                } @catch (__unused NSException *exception) {}
            }
        }
    }

    return rawApps.count - before;
}

static NSUInteger OITODCollectActivities(id workspace, NSMutableArray *rawApps, NSUInteger *activityTypeCount, NSUInteger *domainCount) {
    SEL claimedSelector = NSSelectorFromString(@"getClaimedActivityTypes:domains:");
    if (![workspace respondsToSelector:claimedSelector]) return 0;

    __autoreleasing NSSet *types = nil;
    __autoreleasing NSSet *domains = nil;
    BOOL ok = NO;
    @try {
        ok = ((BOOL (*)(id, SEL, NSSet *__autoreleasing *, NSSet *__autoreleasing *))objc_msgSend)(workspace, claimedSelector, &types, &domains);
    } @catch (__unused NSException *exception) {
        ok = NO;
    }
    if (!ok) return 0;

    if (activityTypeCount) *activityTypeCount = types.count;
    if (domainCount) *domainCount = domains.count;

    NSUInteger before = rawApps.count;
    SEL activitySelector = NSSelectorFromString(@"applicationsForUserActivityType:");
    SEL activityLimitSelector = NSSelectorFromString(@"applicationsForUserActivityType:limit:");

    NSUInteger visited = 0;
    for (id value in types) {
        if (visited++ >= 4096 || ![value isKindOfClass:NSString.class]) break;
        NSString *activityType = value;
        NSUInteger countBeforeType = rawApps.count;
        if ([workspace respondsToSelector:activitySelector]) {
            @try { OITODAppendCollection(rawApps, OITODSendObject(workspace, activitySelector, activityType)); }
            @catch (__unused NSException *exception) {}
        }
        if (rawApps.count == countBeforeType && [workspace respondsToSelector:activityLimitSelector]) {
            @try {
                id result = ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(workspace, activityLimitSelector, activityType, 128);
                OITODAppendCollection(rawApps, result);
            } @catch (__unused NSException *exception) {}
        }
    }

    SEL domainSelector = NSSelectorFromString(@"applicationForUserActivityDomainName:");
    visited = 0;
    if ([workspace respondsToSelector:domainSelector]) {
        for (id value in domains) {
            if (visited++ >= 4096 || ![value isKindOfClass:NSString.class]) break;
            @try {
                id proxy = OITODSendObject(workspace, domainSelector, value);
                if (proxy) [rawApps addObject:proxy];
            } @catch (__unused NSException *exception) {}
        }
    }

    return rawApps.count - before;
}

static NSUInteger OITODCollectSpecialWorkspaceLists(id workspace, NSMutableArray *rawApps) {
    NSUInteger before = rawApps.count;
    for (NSString *selectorName in @[@"directionsApplications"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![workspace respondsToSelector:selector]) continue;
        @try { OITODAppendCollection(rawApps, OITODSendId(workspace, selector)); }
        @catch (__unused NSException *exception) {}
    }
    return rawApps.count - before;
}

+ (NSArray<OITInstalledApplication *> *)discoverApplications {
    id workspace = OITODWorkspace();
    if (!workspace) {
        gOITOnDeviceStatus = @"LSWorkspace недоступен";
        return @[];
    }

    NSMutableArray *rawApps = [NSMutableArray array];
    NSUInteger schemeCount = 0;
    NSUInteger activityTypeCount = 0;
    NSUInteger domainCount = 0;

    NSUInteger schemeApps = OITODCollectSchemes(workspace, rawApps, &schemeCount);
    NSUInteger activityApps = OITODCollectActivities(workspace, rawApps, &activityTypeCount, &domainCount);
    NSUInteger specialApps = OITODCollectSpecialWorkspaceLists(workspace, rawApps);

    NSMutableDictionary<NSString *, OITInstalledApplication *> *unique = [NSMutableDictionary dictionary];
    for (id proxy in rawApps) {
        NSString *bundleID = OITODBundleID(proxy);
        if (bundleID.length == 0) continue;
        NSString *name = OITODDisplayName(proxy, bundleID);
        UIImage *icon = OITODIconForProxy(proxy, bundleID);
        OITInstalledApplication *app = [[OITInstalledApplication alloc] initWithBundleIdentifier:bundleID displayName:name icon:icon];

        OITInstalledApplication *existing = unique[bundleID];
        if (!existing || (!existing.icon && app.icon)) unique[bundleID] = app;
    }

    NSArray *sorted = [unique.allValues sortedArrayUsingComparator:^NSComparisonResult(OITInstalledApplication *a, OITInstalledApplication *b) {
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];

    gOITOnDeviceStatus = [NSString stringWithFormat:@"URL-схемы:%lu→%lu · Activities:%lu/%lu→%lu · Special:%lu",
                          (unsigned long)schemeCount,
                          (unsigned long)schemeApps,
                          (unsigned long)activityTypeCount,
                          (unsigned long)domainCount,
                          (unsigned long)activityApps,
                          (unsigned long)specialApps];
    return sorted;
}

+ (NSString *)status {
    return gOITOnDeviceStatus ?: @"";
}

@end
