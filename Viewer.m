#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

static BOOL virtualScreen(CGDirectDisplayID display) {
    if (!CGDisplayIsOnline(display) || CGDisplayIsInMirrorSet(display)) return NO;
    if (CGDisplayVendorNumber(display)==0x4b41 && CGDisplayModelNumber(display)==1) return YES;
    static CFDictionaryRef (*info)(CGDirectDisplayID);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *library=dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",RTLD_LAZY);
        if (library) info=dlsym(library,"CoreDisplay_DisplayCreateInfoDictionary");
    });
    NSDictionary *properties=info?CFBridgingRelease(info(display)):nil;
    return [properties[@"kCGDisplayIsVirtualDevice"] boolValue];
}

int listViewerDisplays(void) {
    NSMutableArray *rows=[NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *number=screen.deviceDescription[@"NSScreenNumber"];
        if (virtualScreen(number.unsignedIntValue))
            [rows addObject:@{@"id":number,@"name":screen.localizedName,
                              @"vd":@(CGDisplayVendorNumber(number.unsignedIntValue)==0x4b41 && CGDisplayModelNumber(number.unsignedIntValue)==1)}];
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
    puts([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] UTF8String]);
    return 0;
}

@interface VDViewer : NSObject <SCStreamOutput,SCStreamDelegate>
@property(nonatomic) int fd;
@property(nonatomic,strong) CIContext *context;
@property(nonatomic,strong) SCStream *stream;
@end
@implementation VDViewer
- (void)sendBytes:(const void *)bytes size:(size_t)length {
    const char *ptr=bytes;
    while (length) {
        ssize_t sent=write(self.fd,ptr,length);
        if(sent<0 && errno==EINTR)continue;
        if(sent<=0)_exit(0);
        ptr+=sent; length-=sent;
    }
}
- (void)packet:(NSData *)data {
    uint32_t length=htonl((uint32_t)data.length);
    [self sendBytes:&length size:sizeof(length)];
    [self sendBytes:data.bytes size:data.length];
}
- (void)fail:(NSString *)message {
    [self packet:[message dataUsingEncoding:NSUTF8StringEncoding]]; _exit(1);
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    // Closing the connection also wakes a viewer waiting on an idle screen.
    shutdown(self.fd,SHUT_RDWR); _exit(1);
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    @autoreleasepool {
        if(type!=SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample))return;
        NSArray *attachments=(__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample,false);
        if ([attachments.firstObject[SCStreamFrameInfoStatus] integerValue]!=SCFrameStatusComplete)return;
        CVImageBufferRef buffer=CMSampleBufferGetImageBuffer(sample);
        if(!buffer)return;
        CIImage *source=[CIImage imageWithCVPixelBuffer:buffer];
        CGImageRef image=[self.context createCGImage:source fromRect:source.extent];
        if(!image)return;
        NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithCGImage:image];
        CGImageRelease(image);
        NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if(png)[self packet:png];
    }
}
@end

int runViewer(CGDirectDisplayID target,NSString *path) {
    struct sockaddr_un address={.sun_family=AF_UNIX};
    if(strlcpy(address.sun_path,path.fileSystemRepresentation,sizeof(address.sun_path))>=sizeof(address.sun_path))return 1;
    int fd=socket(AF_UNIX,SOCK_STREAM,0);
    if(fd<0 || connect(fd,(struct sockaddr *)&address,sizeof(address))<0)return 1;
    int yes=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
    VDViewer *viewer=[VDViewer new];viewer.fd=fd;
    if(!virtualScreen(target))[viewer fail:@"The selected virtual display is offline or mirrored."];
    if(!CGPreflightScreenCaptureAccess())[viewer fail:@"Screen Recording is off for Virtual Display.app."];
    dispatch_source_t closed=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,dispatch_get_main_queue());
    dispatch_source_set_event_handler(closed,^{ _exit(0); });
    dispatch_resume(closed);
    viewer.context=[CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content,NSError *err){
        SCDisplay *selected=nil;
        for(SCDisplay *display in content.displays)if(display.displayID==target)selected=display;
        if(!selected)[viewer fail:err.localizedDescription?:@"Display is unavailable for capture."];
        SCStreamConfiguration *config=[SCStreamConfiguration new];
        config.width=selected.width;config.height=selected.height;config.showsCursor=YES;
        config.minimumFrameInterval=CMTimeMake(1,8);config.queueDepth=3;
        SCContentFilter *filter=[[SCContentFilter alloc] initWithDisplay:selected excludingWindows:@[]];
        viewer.stream=[[SCStream alloc] initWithFilter:filter configuration:config delegate:viewer];
        NSError *issue=nil;
        if(![viewer.stream addStreamOutput:viewer type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_queue_create("vd.viewer.frames",DISPATCH_QUEUE_SERIAL) error:&issue])
            [viewer fail:issue.localizedDescription?:@"Could not attach display stream."];
        [viewer.stream startCaptureWithCompletionHandler:^(NSError *failure){if(failure)[viewer fail:failure.localizedDescription];}];
    }];
    dispatch_main();
}
