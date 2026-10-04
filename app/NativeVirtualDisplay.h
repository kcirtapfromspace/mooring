// A virtual display sized to the viewing Mac's screen. The only use of a
// private Apple API in MacLink (see AGENTS.md): CoreGraphics' CGVirtualDisplay,
// which Apple's own Screen Sharing uses for High Performance sessions.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface MLVirtualDisplay : NSObject
/// Whether this macOS still provides every class and selector used here.
@property (class, readonly) BOOL isAvailable;
/// The display ID while the display exists.
@property (readonly) CGDirectDisplayID displayID;
/// A display of `pointWidth` × `pointHeight` points at `scale` 1 or 2, or nil
/// when the private API is missing or refuses the size. It disappears when
/// this object is released or the process exits.
- (nullable instancetype)initWithName:(NSString *)name
                           pointWidth:(uint32_t)pointWidth
                          pointHeight:(uint32_t)pointHeight
                                scale:(uint32_t)scale NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// Changes the size in place; NO if the private API refuses it.
- (BOOL)resizeToPointWidth:(uint32_t)pointWidth pointHeight:(uint32_t)pointHeight scale:(uint32_t)scale;
@end

#if defined(ML_VIRTUAL_DISPLAY_TESTING)
// Local CI resolves fake classes; this seam is absent from the app binary.
void MLVirtualDisplaySetClassResolver(Class _Nullable (^ _Nullable resolver)(NSString *));
#endif

NS_ASSUME_NONNULL_END
