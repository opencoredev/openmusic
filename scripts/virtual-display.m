// A temporary HiDPI (2x) virtual display, so screenshots on a Mac without a Retina screen (the build Mac's is
// 1080p at 1x) come out at Retina density. Used by scripts/demo-shots.sh; never part of the app.
//
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics scripts/virtual-display.m -o build/virtual-display
//   build/virtual-display <width-points> <height-points> <seconds>
//
// The display exists while the process runs and disappears when it exits (or after <seconds>). It uses
// CoreGraphics' CGVirtualDisplay classes, which have no public header; they are declared here.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        unsigned int w = argc > 1 ? (unsigned int)atoi(argv[1]) : 1800;
        unsigned int h = argc > 2 ? (unsigned int)atoi(argv[2]) : 1125;
        double seconds = argc > 3 ? atof(argv[3]) : 900;

        CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = @"OpenMusic Screenshots";
        descriptor.maxPixelsWide = w * 2;
        descriptor.maxPixelsHigh = h * 2;
        // About a 16" Retina panel, so macOS picks 2x.
        descriptor.sizeInMillimeters = CGSizeMake(345, 345.0 * h / w);
        descriptor.productID = 0x4d53;
        descriptor.vendorID = 0x4d44;
        descriptor.serialNum = 0x0001;

        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (!display) { fprintf(stderr, "virtual-display: could not create a display\n"); return 1; }
        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.hiDPI = 1;
        settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];
        if (![display applySettings:settings]) { fprintf(stderr, "virtual-display: settings refused\n"); return 1; }

        printf("virtual-display: id %u, %ux%u points at 2x\n", display.displayID, w, h);
        fflush(stdout);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
    }
    return 0;
}
