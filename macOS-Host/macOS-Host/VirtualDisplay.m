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
        descriptor.maxPixelsHigh = height;
        descriptor.maxPixelsWide = width;
        descriptor.sizeInMillimeters = CGSizeMake(25.4 * width / ppi, 25.4 * height / ppi);
        descriptor.serialNum = 1;
        descriptor.productID = 1;
        descriptor.vendorID = 1;

        _display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (!_display) {
            return nil;
        }

        int modeWidth = width;
        int modeHeight = height;
        if (hiDPI) {
            modeWidth /= 2;
            modeHeight /= 2;
        }

        CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:modeWidth
                                                                          height:modeHeight
                                                                     refreshRate:60];
        settings.modes = @[mode];

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
