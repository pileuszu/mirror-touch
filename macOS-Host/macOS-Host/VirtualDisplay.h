#import <Foundation/Foundation.h>

@interface VirtualDisplayWrapper : NSObject

@property (nonatomic, readonly) id display;
@property (nonatomic, readonly) uint32_t displayID;

- (instancetype)initWithName:(NSString *)name width:(int)width height:(int)height ppi:(int)ppi hiDPI:(BOOL)hiDPI;
- (void)destroy;

@end
