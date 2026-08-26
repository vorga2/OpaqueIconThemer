#import "OITPrivateAppScanner.h"
#import <objc/message.h>
#import <objc/runtime.h>

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

static NSString *OITStringValue(id object, NSArray<NSString *> *selectorNames) {
    for (NSString *name in selectorNames) {
        SEL sel = NSSelectorFromString(name);
        if ([object respondsToSelector:sel]) {
            id value = OITSendId(object, sel);
            if ([value isKindOfClass:NSString.class] && [value length] > 0) {
                return value;
            }
        }
    }
    return nil;
}

static UIImage *OITIconForProxy(id proxy, NSString *bundleID) {
    NSArray<NSNumber *> *variants = @[@2, @1, @0, @6, @10];

    SEL iconDataSel = NSSelectorFromString(@"iconDataForVariant:");
    if ([proxy respondsToSelector:iconDataSel]) {
        for (NSNumber *variant in variants) {
            id data = OITSendIdInteger(proxy, iconDataSel, variant.integerValue);
            if ([data isKindOfClass:NSData.class]) {
                UIImage *image = [UIImage imageWithData:data];
                if (image) return image;
            }
        }
    }

    SEL iconDataOptionsSel = NSSelectorFromString(@"iconDataForVariant:withOptions:");
    if ([proxy respondsToSelector:iconDataOptionsSel]) {
        for (NSNumber *variant in variants) {
            id data = OITSendIdIntegerObject(proxy, iconDataOptionsSel, variant.integerValue, @{});
            if ([data isKindOfClass:NSData.class]) {
                UIImage *image = [UIImage imageWithData:data];
                if (image) return image;
            }
        }
    }

    SEL imageSel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    Class imageClass = UIImage.class;
    if ([imageClass respondsToSelector:imageSel]) {
        CGFloat scale = UIScreen.mainScreen.scale;
        for (NSNumber *format in @[@2, @1, @0]) {
            id result = OITSendIconClassMethod(imageClass, imageSel, bundleID, format.integerValue, scale);
            if ([result isKindOfClass:UIImage.class]) return result;
        }
    }

    return nil;
}

+ (NSArray<OITInstalledApplication *> *)installedApplications {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) {
        gOITScanStatus = @"LSApplicationWorkspace недоступен";
        return @[];
    }

    SEL defaultWorkspaceSel = NSSelectorFromString(@"defaultWorkspace");
    if (![workspaceClass respondsToSelector:defaultWorkspaceSel]) {
        gOITScanStatus = @"defaultWorkspace недоступен";
        return @[];
    }

    id workspace = OITSendId(workspaceClass, defaultWorkspaceSel);
    if (!workspace) {
        gOITScanStatus = @"Не удалось получить workspace";
        return @[];
    }

    NSArray *rawApps = nil;
    SEL allApplicationsSel = NSSelectorFromString(@"allApplications");
    if ([workspace respondsToSelector:allApplicationsSel]) {
        id result = OITSendId(workspace, allApplicationsSel);
        if ([result isKindOfClass:NSArray.class]) {
            rawApps = result;
        } else if ([result respondsToSelector:@selector(allObjects)]) {
            rawApps = [result allObjects];
        }
    }

    if (rawApps.count == 0) {
        gOITScanStatus = @"iOS не отдала список установленных приложений";
        return @[];
    }

    NSMutableDictionary<NSString *, OITInstalledApplication *> *unique = [NSMutableDictionary dictionary];

    for (id proxy in rawApps) {
        NSString *bundleID = OITStringValue(proxy, @[@"bundleIdentifier", @"applicationIdentifier"]);
        if (bundleID.length == 0) continue;

        NSString *name = OITStringValue(proxy, @[@"localizedName", @"localizedShortName", @"itemName"]);
        if (name.length == 0) name = bundleID;

        UIImage *icon = OITIconForProxy(proxy, bundleID);
        unique[bundleID] = [[OITInstalledApplication alloc] initWithBundleIdentifier:bundleID
                                                                        displayName:name
                                                                              icon:icon];
    }

    NSArray *sorted = [unique.allValues sortedArrayUsingComparator:^NSComparisonResult(OITInstalledApplication *a, OITInstalledApplication *b) {
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];

    gOITScanStatus = [NSString stringWithFormat:@"Найдено приложений: %lu", (unsigned long)sorted.count];
    return sorted;
}

+ (NSString *)scanStatus {
    return gOITScanStatus ?: @"";
}

@end
