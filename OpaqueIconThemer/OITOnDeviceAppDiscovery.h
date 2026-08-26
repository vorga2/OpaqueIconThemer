#import <Foundation/Foundation.h>
#import "OITPrivateAppScanner.h"

NS_ASSUME_NONNULL_BEGIN

@interface OITOnDeviceAppDiscovery : NSObject
+ (NSArray<OITInstalledApplication *> *)discoverApplications;
+ (NSString *)status;
@end

NS_ASSUME_NONNULL_END
