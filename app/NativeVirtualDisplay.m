// The private CGVirtualDisplay API, declared here only as the selectors this
// file sends. Classes are looked up at runtime and every selector is checked,
// so a macOS that removes or changes them makes MLVirtualDisplay unavailable
// instead of crashing; Mooring then shares the physical display.
#import "NativeVirtualDisplay.h"

@interface NSObject (MLCGVirtualDisplayPrivate)
- (instancetype)initWithDescriptor:(id)descriptor;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
- (BOOL)applySettings:(id)settings;
- (unsigned int)displayID;
@end

#if defined(ML_VIRTUAL_DISPLAY_TESTING)
static Class (^MLTestClassResolver)(NSString *);
void MLVirtualDisplaySetClassResolver(Class (^resolver)(NSString *)) { MLTestClassResolver = [resolver copy]; }
#endif
static Class MLClass(NSString *name) {
#if defined(ML_VIRTUAL_DISPLAY_TESTING)
    if (MLTestClassResolver) return MLTestClassResolver(name);
#endif
    return NSClassFromString(name);
}

@implementation MLVirtualDisplay {
    id _display;
}

+ (BOOL)isAvailable {
    @try {
        Class descriptor = MLClass(@"CGVirtualDisplayDescriptor"), display = MLClass(@"CGVirtualDisplay");
        Class settings = MLClass(@"CGVirtualDisplaySettings"), mode = MLClass(@"CGVirtualDisplayMode");
        return descriptor && display && settings && mode
            && [display instancesRespondToSelector:@selector(initWithDescriptor:)]
            && [display instancesRespondToSelector:@selector(applySettings:)]
            && [display instancesRespondToSelector:@selector(displayID)]
            && [mode instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)]
            && [settings instancesRespondToSelector:NSSelectorFromString(@"setModes:")]
            && [settings instancesRespondToSelector:NSSelectorFromString(@"setHiDPI:")]
            && [descriptor instancesRespondToSelector:NSSelectorFromString(@"setMaxPixelsWide:")]
            && [descriptor instancesRespondToSelector:NSSelectorFromString(@"setMaxPixelsHigh:")]
            && [descriptor instancesRespondToSelector:NSSelectorFromString(@"setSizeInMillimeters:")]
            && [descriptor instancesRespondToSelector:NSSelectorFromString(@"setName:")]
            && [descriptor instancesRespondToSelector:NSSelectorFromString(@"setVendorID:")]
            && [descriptor instancesRespondToSelector:NSSelectorFromString(@"setProductID:")]
            && [descriptor instancesRespondToSelector:NSSelectorFromString(@"setSerialNum:")]
            && [descriptor instancesRespondToSelector:NSSelectorFromString(@"setQueue:")]
            && [descriptor instancesRespondToSelector:NSSelectorFromString(@"setTerminationHandler:")];
    } @catch (__unused NSException *exception) { return NO; }
}

static BOOL MLValidSize(uint32_t width, uint32_t height, uint32_t scale) {
    return (scale == 1 || scale == 2) && width >= 320 && height >= 240 && width <= 7680 && height <= 4320;
}

/// Modes are given in points: with hiDPI on, macOS presents a mode of W×H at
/// 2W×2H pixels and makes it the default.
- (nullable id)settingsForWidth:(uint32_t)width height:(uint32_t)height scale:(uint32_t)scale {
    id mode = [[MLClass(@"CGVirtualDisplayMode") alloc] initWithWidth:width height:height refreshRate:60];
    id settings = [[MLClass(@"CGVirtualDisplaySettings") alloc] init];
    if (!mode || !settings) return nil;
    [settings setValue:@[mode] forKey:@"modes"];
    [settings setValue:@(scale == 2 ? 1u : 0u) forKey:@"hiDPI"];
    return settings;
}

- (nullable instancetype)initWithName:(NSString *)name pointWidth:(uint32_t)pointWidth
                          pointHeight:(uint32_t)pointHeight scale:(uint32_t)scale {
    @try {
        if (!(self = [super init]) || !MLVirtualDisplay.isAvailable || !MLValidSize(pointWidth, pointHeight, scale)) return nil;
        // Private calls may autorelease; drain here so releasing this object
        // removes the display at once.
        @autoreleasepool { if (![self createNamed:name width:pointWidth height:pointHeight scale:scale]) return nil; }
        return self;
    } @catch (__unused NSException *exception) { return nil; }
}

- (BOOL)createNamed:(NSString *)name width:(uint32_t)pointWidth height:(uint32_t)pointHeight scale:(uint32_t)scale {
    id descriptor = [[MLClass(@"CGVirtualDisplayDescriptor") alloc] init];
    if (!descriptor) return NO;
    // The largest size this display may later be resized to: 8K, in pixels.
    [descriptor setValue:@(7680u * 2) forKey:@"maxPixelsWide"];
    [descriptor setValue:@(4320u * 2) forKey:@"maxPixelsHigh"];
    // About a 14-inch laptop panel, so macOS picks sensible text sizes.
    [descriptor setValue:[NSValue valueWithSize:NSMakeSize(302, 196)] forKey:@"sizeInMillimeters"];
    [descriptor setValue:name forKey:@"name"];
    [descriptor setValue:@(0x4D4Cu) forKey:@"vendorID"];   // "ML"
    [descriptor setValue:@(0x5644u) forKey:@"productID"];  // "VD"
    [descriptor setValue:@(1u) forKey:@"serialNum"];
    [descriptor setValue:dispatch_get_main_queue() forKey:@"queue"];
    [descriptor setValue:^(id display, id error) {} forKey:@"terminationHandler"];
    _display = [[MLClass(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    return _display && [self resizeToPointWidth:pointWidth pointHeight:pointHeight scale:scale];
}

- (BOOL)resizeToPointWidth:(uint32_t)pointWidth pointHeight:(uint32_t)pointHeight scale:(uint32_t)scale {
    @try {
        if (!_display || !MLVirtualDisplay.isAvailable || !MLValidSize(pointWidth, pointHeight, scale)) return NO;
        @autoreleasepool {
            id settings = [self settingsForWidth:pointWidth height:pointHeight scale:scale];
            return settings && [_display applySettings:settings];
        }
    } @catch (__unused NSException *exception) { return NO; }
}

- (CGDirectDisplayID)displayID {
    @try {
        @autoreleasepool { return _display ? (CGDirectDisplayID)[_display displayID] : kCGNullDirectDisplay; }
    } @catch (__unused NSException *exception) { return kCGNullDirectDisplay; }
}

@end
