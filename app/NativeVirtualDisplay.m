// The private CGVirtualDisplay API, declared here only as the selectors this
// file sends. Classes are looked up at runtime and every selector is checked,
// so a macOS that removes or changes them makes MLVirtualDisplay unavailable
// instead of crashing; MacLink then shares the physical display.
#import "NativeVirtualDisplay.h"

@interface NSObject (MLCGVirtualDisplayPrivate)
- (instancetype)initWithDescriptor:(id)descriptor;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
- (BOOL)applySettings:(id)settings;
- (unsigned int)displayID;
@end

static Class MLClass(NSString *name) { return NSClassFromString(name); }

@implementation MLVirtualDisplay {
    id _display;
}

+ (BOOL)isAvailable {
    Class descriptor = MLClass(@"CGVirtualDisplayDescriptor"), display = MLClass(@"CGVirtualDisplay");
    Class settings = MLClass(@"CGVirtualDisplaySettings"), mode = MLClass(@"CGVirtualDisplayMode");
    return descriptor && display && settings && mode
        && [display instancesRespondToSelector:@selector(initWithDescriptor:)]
        && [display instancesRespondToSelector:@selector(applySettings:)]
        && [display instancesRespondToSelector:@selector(displayID)]
        && [mode instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)]
        && [settings instancesRespondToSelector:NSSelectorFromString(@"setModes:")]
        && [settings instancesRespondToSelector:NSSelectorFromString(@"setHiDPI:")]
        && [descriptor instancesRespondToSelector:NSSelectorFromString(@"setMaxPixelsWide:")];
}

static BOOL MLValidSize(uint32_t width, uint32_t height, uint32_t scale) {
    return (scale == 1 || scale == 2) && width >= 320 && height >= 240 && width <= 7680 && height <= 4320;
}

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
    if (!(self = [super init]) || !MLVirtualDisplay.isAvailable || !MLValidSize(pointWidth, pointHeight, scale)) return nil;
    id descriptor = [[MLClass(@"CGVirtualDisplayDescriptor") alloc] init];
    if (!descriptor) return nil;
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
    if (!_display || ![self resizeToPointWidth:pointWidth pointHeight:pointHeight scale:scale]) return nil;
    return self;
}

- (BOOL)resizeToPointWidth:(uint32_t)pointWidth pointHeight:(uint32_t)pointHeight scale:(uint32_t)scale {
    if (!_display || !MLValidSize(pointWidth, pointHeight, scale)) return NO;
    // HiDPI modes are specified in pixels; macOS presents them at half size.
    id settings = [self settingsForWidth:pointWidth * scale height:pointHeight * scale scale:scale];
    return settings && [_display applySettings:settings];
}

- (CGDirectDisplayID)displayID { return _display ? (CGDirectDisplayID)[_display displayID] : kCGNullDirectDisplay; }

@end
