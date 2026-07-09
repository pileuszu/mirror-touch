#import <CoreGraphics/CoreGraphics.h>
#import "VirtualDisplay.h"
#import "include/CGVirtualDisplay.h"
#import "include/CGVirtualDisplayDescriptor.h"
#import "include/CGVirtualDisplayMode.h"
#import "include/CGVirtualDisplaySettings.h"

@implementation VirtualDisplayWrapper {
    CGVirtualDisplay *_display;
}

- (instancetype)initWithName:(NSString *)name width:(int)width height:(int)height ppi:(int)ppi hiDPI:(BOOL)hiDPI {
    self = [super init];
    if (self) {
        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.hiDPI = hiDPI;

        CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
        descriptor.queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
        descriptor.name = name;

        descriptor.whitePoint = CGPointMake(0.3125, 0.3291);
        descriptor.bluePrimary = CGPointMake(0.1494, 0.0557);
        descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
        descriptor.redPrimary = CGPointMake(0.6797, 0.3203);
        int maxW = width > 1920 ? width : 1920;
        int maxH = height > 1080 ? height : 1080;
        descriptor.maxPixelsWide = maxW;
        descriptor.maxPixelsHigh = maxH;
        descriptor.sizeInMillimeters = CGSizeMake(25.4 * width / ppi, 25.4 * height / ppi);
        descriptor.serialNum = 1;
        descriptor.productID = 1;
        descriptor.vendorID = 1;

        _display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (!_display) {
            return nil;
        }

        NSMutableArray *modes = [NSMutableArray array];

        int modeWidth = width;
        int modeHeight = height;
        if (hiDPI) {
            modeWidth /= 2;
            modeHeight /= 2;
        }
        [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:modeWidth height:modeHeight refreshRate:60]];

        // Register other common standard modes so that full-screen games (like MapleStory)
        // can successfully query and switch display modes on this virtual screen.
        NSArray *commonResolutions = @[
            @[@1920, @1080],
            @[@1680, @1050],
            @[@1600, @1200],
            @[@1600, @900],
            @[@1440, @900],
            @[@1366, @768],
            @[@1280, @1024],
            @[@1280, @960],
            @[@1280, @800],
            @[@1280, @720],
            @[@1024, @768],
            @[@800, @600]
        ];

        for (NSArray *res in commonResolutions) {
            int w = [res[0] intValue];
            int h = [res[1] intValue];
            if (w == modeWidth && h == modeHeight) continue;
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];
        }

        settings.modes = modes;

        if (![_display applySettings:settings]) {
            return nil;
        }
    }
    return self;
}

- (id)display {
    return _display;
}

- (uint32_t)displayID {
    return _display.displayID;
}

- (void)destroy {
    _display = nil;
}

@end
