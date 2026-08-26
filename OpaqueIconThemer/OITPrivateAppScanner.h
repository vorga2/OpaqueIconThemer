#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OITInstalledApplication : NSObject
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, strong, nullable) UIImage *icon;
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                              displayName:(NSString *)displayName
                                    icon:(nullable UIImage *)icon;
@end

@interface OITPrivateAppScanner : NSObject
+ (NSArray<OITInstalledApplication *> *)installedApplications;
+ (nullable OITInstalledApplication *)installedApplicationForBundleIdentifier:(NSString *)bundleIdentifier;
+ (NSString *)scanStatus;
@end

NS_ASSUME_NONNULL_END
