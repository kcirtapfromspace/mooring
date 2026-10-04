// Only fake private classes are resolved. No CGVirtualDisplay is instantiated.
#import "../app/NativeVirtualDisplay.h"
#import <Foundation/Foundation.h>

static NSString *missingSelector, *missingClass, *fault;
static int checks;
static void Require(BOOL result, NSString *message) {
    checks++;
    if (!result) { fprintf(stderr, "Private display boundary failed: %s\n", message.UTF8String); exit(1); }
}
static void Fault(NSString *point) {
    if ([fault isEqualToString:point]) [NSException raise:@"TestCompatibilityChange" format:@"Synthetic fault"];
}

@interface MLTestObject : NSObject
@end
@implementation MLTestObject
+ (BOOL)instancesRespondToSelector:(SEL)selector {
    Fault(@"availability");
    return ![missingSelector isEqualToString:NSStringFromSelector(selector)] && [super instancesRespondToSelector:selector];
}
@end

@interface MLTestDescriptor : MLTestObject
@property (strong) id maxPixelsWide, maxPixelsHigh, sizeInMillimeters, name, vendorID, productID, serialNum, queue, terminationHandler;
@end
@implementation MLTestDescriptor
- (instancetype)init { Fault(@"descriptor.init"); return [super init]; }
- (void)setValue:(id)value forKey:(NSString *)key { Fault([@"descriptor." stringByAppendingString:key]); [super setValue:value forKey:key]; }
@end

@interface MLTestSettings : MLTestObject
@property (strong) id modes, hiDPI;
@end
@implementation MLTestSettings
- (instancetype)init { Fault(@"settings.init"); return [super init]; }
- (void)setValue:(id)value forKey:(NSString *)key { Fault([@"settings." stringByAppendingString:key]); [super setValue:value forKey:key]; }
@end

@interface MLTestMode : MLTestObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end
@implementation MLTestMode
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate {
    Fault(@"mode.init"); return [super init];
}
@end

@interface MLTestDisplay : MLTestObject
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
- (unsigned int)displayID;
@end
@implementation MLTestDisplay
- (instancetype)initWithDescriptor:(id)descriptor { Fault(@"display.init"); return [super init]; }
- (BOOL)applySettings:(id)settings { Fault(@"display.apply"); return ![fault isEqualToString:@"display.refuse"]; }
- (unsigned int)displayID { Fault(@"display.id"); return 777; }
@end

static MLVirtualDisplay *Create(void) {
    return [[MLVirtualDisplay alloc] initWithName:@"Test" pointWidth:1920 pointHeight:1080 scale:1];
}
int main(void) {
    @autoreleasepool {
        MLVirtualDisplaySetClassResolver(^Class(NSString *name) {
            if ([missingClass isEqualToString:name]) return Nil;
            if ([name isEqualToString:@"CGVirtualDisplayDescriptor"]) return MLTestDescriptor.class;
            if ([name isEqualToString:@"CGVirtualDisplaySettings"]) return MLTestSettings.class;
            if ([name isEqualToString:@"CGVirtualDisplayMode"]) return MLTestMode.class;
            if ([name isEqualToString:@"CGVirtualDisplay"]) return MLTestDisplay.class;
            return Nil;
        });
        Require(MLVirtualDisplay.isAvailable, @"Complete fake API is available");
        MLVirtualDisplay *display = Create();
        Require(display && display.displayID == 777, @"Valid display creation/getter preserves behavior");
        Require([display resizeToPointWidth:1280 pointHeight:720 scale:2], @"Valid resize preserves behavior");
        Require(![display resizeToPointWidth:10 pointHeight:10 scale:1], @"Size bound remains enforced");
        for (NSString *name in @[@"CGVirtualDisplayDescriptor", @"CGVirtualDisplaySettings", @"CGVirtualDisplayMode", @"CGVirtualDisplay"]) {
            missingClass = name;
            Require(!MLVirtualDisplay.isAvailable && !Create(), @"Each missing class cleanly disables creation");
        }
        missingClass = nil;
        for (NSString *selector in @[@"initWithDescriptor:", @"applySettings:", @"displayID", @"initWithWidth:height:refreshRate:",
                                    @"setModes:", @"setHiDPI:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:", @"setSizeInMillimeters:",
                                    @"setName:", @"setVendorID:", @"setProductID:", @"setSerialNum:", @"setQueue:", @"setTerminationHandler:"]) {
            missingSelector = selector;
            Require(!MLVirtualDisplay.isAvailable && !Create(), @"Each missing selector cleanly disables creation");
        }
        missingSelector = nil;
        fault = @"availability";
        Require(!MLVirtualDisplay.isAvailable && !Create(), @"Availability inspection exceptions are contained");
        for (NSString *point in @[@"descriptor.init", @"descriptor.maxPixelsWide", @"descriptor.maxPixelsHigh", @"descriptor.sizeInMillimeters",
                                 @"descriptor.name", @"descriptor.vendorID", @"descriptor.productID", @"descriptor.serialNum", @"descriptor.queue",
                                 @"descriptor.terminationHandler", @"mode.init", @"settings.init", @"settings.modes", @"settings.hiDPI",
                                 @"display.init", @"display.apply", @"display.refuse"]) {
            fault = point;
            Require(!Create(), @"Creation contains private API exceptions/refusals");
        }
        fault = @"display.id";
        Require(display.displayID == kCGNullDirectDisplay, @"A getter exception yields the unavailable display ID");
        for (NSString *point in @[@"mode.init", @"settings.init", @"settings.modes", @"settings.hiDPI", @"display.apply", @"display.refuse"]) {
            fault = point;
            Require(![display resizeToPointWidth:1280 pointHeight:720 scale:1], @"Resize contains exceptions/refusals");
        }
        fault = nil;
        Require([display resizeToPointWidth:1280 pointHeight:720 scale:1], @"A later valid resize still works");
        printf("Private display boundary: %d fake-class checks passed; no real display created.\n", checks);
    }
    return 0;
}
