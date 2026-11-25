#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <sys/file.h>
#import <unistd.h>
#import <dlfcn.h>

// These WindowServer interfaces exist at runtime and have no public SDK header.
@interface SamDescriptor : NSObject
@property dispatch_queue_t queue;
@property(copy) NSString *name;
@property unsigned int vendorID, productID, serialNum, serialNumber, maxPixelsWide, maxPixelsHigh;
@property CGSize sizeInMillimeters;
@property CGPoint whitePoint, redPrimary, greenPrimary, bluePrimary;
@end
@interface SamMode : NSObject
-(id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface SamSettings : NSObject
@property(copy) NSArray *modes;
@property unsigned int hiDPI;
@end
@interface SamDisplay : NSObject
-(id)initWithDescriptor:(id)descriptor;
-(BOOL)applySettings:(id)settings;
@property(readonly) CGDirectDisplayID displayID;
@end

static SamDisplay *display;
static CGDirectDisplayID workspaceID;
static NSString *service(void) {return [NSString stringWithFormat:@"local.vd.host.%d",getuid()];}
static NSDictionary *error(NSString *reason) {return @{@"error":reason};}
static NSScreen *workScreen(void) {
    if(!workspaceID || !CGDisplayIsOnline(workspaceID) || CGDisplayIsMain(workspaceID) ||
       CGDisplayIsInMirrorSet(workspaceID) || CGDisplayVendorNumber(workspaceID)!=0x4b41 ||
       CGDisplayModelNumber(workspaceID)!=1)return nil;
    for (NSScreen *screen in NSScreen.screens)
        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]==workspaceID) return screen;
    return nil;
}
static BOOL startDisplay(void) {
    unsigned int hardwareSerial=6701;
    CGDirectDisplayID legacy=0;
    CGDirectDisplayID ids[64];uint32_t count=0;
    if(CGGetOnlineDisplayList(64,ids,&count)==kCGErrorSuccess){
        for(uint32_t i=0;i<count;i++){
            CGDirectDisplayID id=ids[i];
            if(CGDisplayVendorNumber(id)!=0x4b41 || CGDisplayModelNumber(id)!=1 ||
               CGDisplayIsMain(id) || CGDisplayIsInMirrorSet(id))continue;
            unsigned int candidate=CGDisplaySerialNumber(id);
            if(candidate==1701 || candidate==1702)legacy=id;
            if(candidate==hardwareSerial){
                workspaceID=id;
                return YES;
            }
        }
    }
    SamDescriptor *d=[NSClassFromString(@"CGVirtualDisplayDescriptor") new];
    if(!d) return NO;
    d.name=@"Virtual Display"; d.queue=dispatch_get_main_queue();d.vendorID=0x4b41;d.productID=1;d.serialNum=hardwareSerial;
    if([d respondsToSelector:@selector(setSerialNumber:)]) d.serialNumber=hardwareSerial;
    d.maxPixelsWide=2880;d.maxPixelsHigh=1800;d.sizeInMillimeters=CGSizeMake(338,211);
    d.whitePoint=CGPointMake(.3127,.329);d.redPrimary=CGPointMake(.64,.33);d.greenPrimary=CGPointMake(.3,.6);d.bluePrimary=CGPointMake(.15,.06);
    display=[[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:d];
    SamSettings *s=[NSClassFromString(@"CGVirtualDisplaySettings") new];
    NSMutableArray *modes=[NSMutableArray array];
    for(NSNumber *width in @[@1440,@960,@1280,@1680,@1920,@2304,@2560,@2880]){
        unsigned w=width.unsignedIntValue;
        id mode=[[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:w height:w*5/8 refreshRate:60];
        if(mode)[modes addObject:mode];
    }
    if(!display && legacy){
        // Some Macs permit only one extra monitor. Reuse an idle test display there.
        workspaceID=legacy;return YES;
    }
    if(!display || !modes.count || !s)return NO;
    s.modes=modes;
    if(![display applySettings:s])return NO;
    workspaceID=display.displayID;return YES;
}
static NSArray *windows(CGRect bounds) {
    NSArray *info=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    NSMutableArray *result=[NSMutableArray array];
    for(NSDictionary *w in info){
        CGRect rect; if([w[(id)kCGWindowLayer] intValue]!=0 || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&rect)) continue;
        if(CGRectContainsPoint(bounds,CGPointMake(CGRectGetMidX(rect),CGRectGetMidY(rect))))
            [result addObject:@{@"window":w[(id)kCGWindowNumber],@"pid":w[(id)kCGWindowOwnerPID],@"app":w[(id)kCGWindowOwnerName]?:@"",@"title":w[(id)kCGWindowName]?:@""}];
    }return result;
}
extern AXError _AXUIElementGetWindow(AXUIElementRef,CGWindowID*);
static id attribute(AXUIElementRef node, CFStringRef name) {
    CFTypeRef result=NULL;
    AXUIElementCopyAttributeValue(node,name,&result);
    return CFBridgingRelease(result);
}
static void visit(AXUIElementRef node, NSString *path, NSUInteger depth, NSMutableArray *rows) {
    if(depth>=14 || rows.count>=600)return;
    NSString *role=attribute(node,kAXRoleAttribute)?:@"";
    NSMutableDictionary *row=[@{@"id":path,@"role":role,@"title":attribute(node,kAXTitleAttribute)?:@"",
        @"description":attribute(node,kAXDescriptionAttribute)?:@""} mutableCopy];
    if(![attribute(node,kAXSubroleAttribute) isEqual:@"AXSecureTextField"]){
        id value=attribute(node,kAXValueAttribute);
        if([value isKindOfClass:NSString.class])row[@"value"]=[value substringToIndex:MIN(2048,[value length])];
        if([value isKindOfClass:NSNumber.class])row[@"value"]=value;
    }
    [rows addObject:row];
    NSUInteger index=0;
    for(id child in attribute(node,kAXChildrenAttribute)){
        if(rows.count>=600)break;
        visit((__bridge AXUIElementRef)child,[path stringByAppendingFormat:@".%lu",(unsigned long)index++],depth+1,rows);
    }
}
static NSDictionary *accessibility(NSArray<NSString*> *args,CGRect bounds) {
    if(args.count<3)return error(@"Expected PID WINDOW");
    if(!AXIsProcessTrusted())return error(@"Allow Accessibility for the desktop host");
    pid_t pid=args[1].intValue;CGWindowID target=args[2].intValue;
    BOOL belongs=NO;
    for(NSDictionary *w in windows(bounds))
        if([w[@"pid"] intValue]==pid && [w[@"window"] unsignedIntValue]==target){belongs=YES;break;}
    if(!belongs)return error(@"Window is outside Virtual Display's workspace");
    AXUIElementRef app=AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app,0.35);
    NSArray *list=attribute(app,kAXWindowsAttribute);CFRelease(app);
    for(id item in list){
        AXUIElementRef node=(__bridge AXUIElementRef)item;CGWindowID number=0;
        if(_AXUIElementGetWindow(node,&number)!=kAXErrorSuccess || number!=target)continue;
        if([args[0] isEqual:@"raise"])return AXUIElementPerformAction(node,kAXRaiseAction)==kAXErrorSuccess?@{@"ok":@YES}:error(@"App declined to raise its window");
        if([args[0] isEqual:@"inspect"]){
            NSMutableArray *rows=[NSMutableArray array];visit(node,args[2],0,rows);return @{@"controls":rows};
        }
        if(args.count!=([args[0] isEqual:@"set"]?5:4))return error(@"Expected element path and optional value");
        NSArray *parts=[args[3] componentsSeparatedByString:@"."];
        if(![parts.firstObject isEqual:args[2]])return error(@"Element belongs to a different window");
        id __attribute__((objc_precise_lifetime)) current=item;
        for(NSUInteger i=1;i<parts.count;i++){
            NSString *part=parts[i];NSScanner *scanner=[NSScanner scannerWithString:part];NSInteger index=-1;
            NSArray *children=attribute((__bridge AXUIElementRef)current,kAXChildrenAttribute);
            if(![scanner scanInteger:&index] || !scanner.isAtEnd || index<0 || index>=children.count)return error(@"Tree changed; inspect again");
            current=children[index];
        }
        node=(__bridge AXUIElementRef)current;
        AXError result=[args[0] isEqual:@"press"]?AXUIElementPerformAction(node,kAXPressAction):
            AXUIElementSetAttributeValue(node,kAXValueAttribute,(__bridge CFStringRef)args[4]);
        return result==kAXErrorSuccess?@{@"ok":@YES}:error(@"Control declined the operation");
    }
    return error(@"Window is unavailable");
}
// Quartz display coordinates are top-left based. Keyboard delivery is only
// unambiguous when the background process owns one visible document window.
static NSDictionary *input(NSArray<NSString*> *args, CGRect displayBounds) {
    NSString *cmd=args.firstObject;
    if(args.count<4)return error(@"Expected PID, window number and arguments");
    pid_t pid=args[1].intValue;
    CGWindowID wid=args[2].intValue;
    if(pid<=0 || !wid)return error(@"Invalid window identity");
    if(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==pid)
        return error(@"The target is your foreground app; use a separate workspace instance");
    CFArrayRef infoRef=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
    NSArray *info=CFBridgingRelease(infoRef);
    CGRect frame=CGRectNull;int count=0;
    for(NSDictionary *w in info) {
        if([w[(id)kCGWindowOwnerPID] intValue]!=pid || [w[(id)kCGWindowLayer] intValue]!=0)continue;
        count++;
        if([w[(id)kCGWindowNumber] unsignedIntValue]==wid)
            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&frame);
    }
    if(CGRectIsNull(frame)||!CGRectContainsPoint(displayBounds,CGPointMake(CGRectGetMidX(frame),CGRectGetMidY(frame))))
        return error(@"Window is outside the workspace");
    if(!CGPreflightPostEventAccess())return error(@"Allow Accessibility to send input to native apps");
    if([cmd isEqual:@"type"] || [cmd isEqual:@"key"]){
        if(count!=1 || args.count!=4)return error(@"Keyboard input requires one visible window in the target process");
        BOOL text=[cmd isEqual:@"type"];
        if(!text && (args[3].integerValue<0 || args[3].integerValue>127))return error(@"Expected a macOS virtual key code (0–127)");
        NSUInteger length=args[3].length;
        if(text && length>8192)return error(@"Text exceeds 8192 UTF-16 units");
        NSMutableData *chars=[NSMutableData dataWithLength:length*sizeof(UniChar)];
        if(text)[args[3] getCharacters:chars.mutableBytes range:NSMakeRange(0,length)];
        for(NSNumber *down in @[@YES,@NO]){
            CGEventRef e=CGEventCreateKeyboardEvent(NULL,text?0:args[3].intValue,down.boolValue);
            if(!e)return error(@"Could not create keyboard event");
            if(text)CGEventKeyboardSetUnicodeString(e,length,chars.bytes);
            CGEventPostToPid(pid,e);CFRelease(e);
        }
    }else{
        BOOL drag=[cmd isEqual:@"drag"], scroll=[cmd isEqual:@"scroll"];
        if(args.count!=(drag?7:scroll?6:5))return error(@"Invalid coordinate count");
        CGPoint start=CGPointMake(args[3].doubleValue,args[4].doubleValue);
        CGPoint end=drag?CGPointMake(args[5].doubleValue,args[6].doubleValue):start;
        CGRect local=(CGRect){CGPointZero,frame.size};
        if(!CGRectContainsPoint(local,start)||!CGRectContainsPoint(local,end))return error(@"Point outside window");
        typedef void (*WindowLocation)(CGEventRef,CGPoint);
        WindowLocation setLocation=(WindowLocation)dlsym(RTLD_DEFAULT,"CGEventSetWindowLocation");
        if(!setLocation)return error(@"Window-local input unavailable on this macOS release");
        NSArray *types=scroll?@[@(kCGEventScrollWheel)]:(drag?@[@(kCGEventLeftMouseDown),@(kCGEventLeftMouseDragged),@(kCGEventLeftMouseUp)]:@[@(kCGEventLeftMouseDown),@(kCGEventLeftMouseUp)]);
        for(NSNumber *n in types){
            CGEventType t=n.unsignedIntValue;
            CGPoint point=t==kCGEventLeftMouseDown?start:end;
            CGPoint global=CGPointMake(frame.origin.x+point.x,frame.origin.y+point.y);
            CGPoint appKitPoint=CGPointMake(point.x,frame.size.height-point.y);
            CGEventRef e=NULL;
            if(scroll)e=CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitPixel,1,args[5].intValue);
            else{
                NSEvent *mouse=[NSEvent mouseEventWithType:(NSEventType)t location:appKitPoint modifierFlags:0
                    timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:wid context:nil eventNumber:1 clickCount:1 pressure:1];
                if(mouse.CGEvent)e=CGEventCreateCopy(mouse.CGEvent);
            }
            if(!e)return error(@"Could not create pointer event");
            CGEventSetLocation(e,global);
            CGEventSetIntegerValueField(e,kCGMouseEventWindowUnderMousePointer,wid);
            CGEventSetIntegerValueField(e,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,wid);
            if(!scroll)CGEventSetIntegerValueField(e,kCGMouseEventClickState,1);
            CGEventSetIntegerValueField(e,(CGEventField)51,wid);
            CGEventSetIntegerValueField(e,kCGEventTargetUnixProcessID,pid);
            CGEventSetIntegerValueField(e,kCGMouseEventSubtype,3);
            // Quartz expects a top-left window point and AppKit flips it on receipt.
            setLocation(e,point);CGEventPostToPid(pid,e);CFRelease(e);
        }
    }
    return @{@"dispatched":@YES,@"verifyWindow":@(wid)};
}
static NSDictionary *perform(NSArray<NSString*> *a) {
    NSString *cmd=a.firstObject;
    if([cmd isEqual:@"stop"]){
        dispatch_async(dispatch_get_main_queue(),^{display=nil;[NSApp terminate:nil];});
        return @{@"ok":@YES};
    }
    if([cmd isEqual:@"permissions"] || [cmd isEqual:@"authorize"]){
        BOOL prompt=[cmd isEqual:@"authorize"];
        BOOL ax=AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString*)kAXTrustedCheckOptionPrompt:@(prompt)});
        BOOL capture=prompt?CGRequestScreenCaptureAccess():CGPreflightScreenCaptureAccess();
        return @{@"accessibility":@(ax),@"screenRecording":@(capture)};
    }
    if([cmd isEqual:@"all-windows"])return @{@"windows":windows(CGRectInfinite)};
    NSScreen *screen=workScreen();
    if(!screen && [cmd isEqual:@"start"]){
        display=nil;
        if(startDisplay())screen=workScreen();
    }
    if(!screen)return error(@"No extended VD display is ready. Run vd start.");
    CGRect bounds=CGDisplayBounds(workspaceID);
    if([cmd isEqual:@"viewer-zoom"] && a.count==3){
        if([a[1] longLongValue]!=workspaceID)return error(@"Zoom is available on the VD workspace only.");
        NSInteger step=[a[2] integerValue];
        size_t current=CGRectGetWidth(bounds), best=0;
        NSArray *modes=CFBridgingRelease(CGDisplayCopyAllDisplayModes(workspaceID,NULL));
        CGDisplayModeRef chosen=NULL;
        for(id item in modes){
            CGDisplayModeRef mode=(__bridge CGDisplayModeRef)item;
            size_t w=CGDisplayModeGetWidth(mode);
            if(!CGDisplayModeIsUsableForDesktopGUI(mode) || CGDisplayModeGetHeight(mode)*8!=w*5)continue;
            if((step==0 && w==1440) || (step>0 && w>current && (!best || w<best)) ||
               (step<0 && w<current && w>best)){chosen=mode;best=w;}
        }
        if(chosen && best!=current && CGDisplaySetDisplayMode(workspaceID,chosen,NULL)!=kCGErrorSuccess)
            return error(@"macOS could not change the virtual display resolution.");
        return @{@"changed":@(chosen && best!=current),@"width":@(best?:current)};
    }
    if([@[@"inspect",@"press",@"set",@"raise"] containsObject:cmd])return accessibility(a,bounds);
    if([@[@"click",@"drag",@"scroll",@"type",@"key"] containsObject:cmd])return input(a,bounds);
    if([cmd isEqual:@"status"] || [cmd isEqual:@"start"])
        return @{@"display":@(workspaceID),@"worker":@(getpid()),@"windows":windows(bounds),@"bounds":NSStringFromRect(bounds)};
    if(([cmd isEqual:@"window-image"] && a.count==4) || ([cmd isEqual:@"display-image"] && a.count==2)){
        if(!CGPreflightScreenCaptureAccess())return error(@"Allow Screen Recording for Virtual Display to capture another application's window.");
        if(@available(macOS 14,*)){
            BOOL full=[cmd isEqual:@"display-image"];
            pid_t pid=full?0:[a[1] intValue];CGWindowID wid=full?0:[a[2] intValue];
            BOOL belongs=NO;
            for(NSDictionary *w in windows(bounds))if([w[@"pid"] intValue]==pid && [w[@"window"] unsignedIntValue]==wid)belongs=YES;
            if(!full && !belongs)return error(@"The window left Virtual Display's workspace.");
            dispatch_semaphore_t done=dispatch_semaphore_create(0);
            __block NSBitmapImageRep *bitmap=nil;
            __block NSString *failure=nil;
            [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content,NSError *issue){
                SCWindow *target=nil;
                for(SCWindow *w in content.windows)if(w.windowID==wid && w.owningApplication.processID==pid)target=w;
                SCContentFilter *filter=nil;
                CGRect frame=CGRectZero;
                if(full){
                    for(SCDisplay *screen in content.displays)if(screen.displayID==workspaceID){
                        filter=[[SCContentFilter alloc] initWithDisplay:screen excludingWindows:@[]];frame=bounds;break;
                    }
                }else if(target){filter=[[SCContentFilter alloc] initWithDesktopIndependentWindow:target];frame=target.frame;}
                if(!filter){failure=issue.localizedDescription?:@"Capture target unavailable.";dispatch_semaphore_signal(done);return;}
                SCStreamConfiguration *cfg=[SCStreamConfiguration new];
                cfg.width=MAX(1,CGRectGetWidth(frame));cfg.height=MAX(1,CGRectGetHeight(frame));cfg.showsCursor=NO;
                [SCScreenshotManager captureImageWithFilter:filter configuration:cfg completionHandler:^(CGImageRef image,NSError *issue){
                    if(image)bitmap=[[NSBitmapImageRep alloc] initWithCGImage:image];
                    failure=issue.localizedDescription;dispatch_semaphore_signal(done);
                }];
            }];
            if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC)))return error(@"Window capture timed out.");
            if(!bitmap)return error(failure?:@"Could not capture window.");
            NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            NSError *issue=nil;
            if(![png writeToFile:a.lastObject options:NSDataWritingAtomic error:&issue])return error(issue.localizedDescription?:@"Could not save image.");
            return @{@"ok":@YES,@"width":@(bitmap.pixelsWide),@"height":@(bitmap.pixelsHigh)};
        }
        return error(@"Window capture requires macOS 14 or later.");
    }
    if([cmd isEqual:@"all-windows"])return @{@"windows":windows(CGRectInfinite)};
    if([cmd isEqual:@"windows"])return @{@"windows":windows(bounds)};
    if(([cmd isEqual:@"place"] || [cmd isEqual:@"return"]) && a.count==3){
        BOOL returning=[cmd isEqual:@"return"];
        if(returning){
            BOOL onVD=NO;
            for(NSDictionary *w in windows(bounds))if([w[@"pid"] intValue]==[a[1] intValue] && [w[@"window"] intValue]==[a[2] intValue])onVD=YES;
            if(!onVD)return error(@"Window is outside VD");
            CGDirectDisplayID main=CGMainDisplayID();
            if(main==workspaceID)return error(@"Main display is VD");
            bounds=CGDisplayBounds(main);
        }
        if(!AXIsProcessTrusted())return error(@"Allow Accessibility for the desktop host to place external app windows");
        pid_t pid=a[1].intValue;CGWindowID target=a[2].intValue;
        AXUIElementRef app=AXUIElementCreateApplication(pid);CFTypeRef list=NULL;
        AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&list);CFRelease(app);
        BOOL moved=NO;for(id item in CFBridgingRelease(list)){
            AXUIElementRef element=(__bridge AXUIElementRef)item;CGWindowID wid=0;
            if(_AXUIElementGetWindow(element,&wid)!=kAXErrorSuccess||wid!=target)continue;
            CGPoint position=CGPointMake(bounds.origin.x+40,bounds.origin.y+50);
            AXValueRef value=AXValueCreate(kAXValueCGPointType,&position);
            moved=AXUIElementSetAttributeValue(element,kAXPositionAttribute,value)==kAXErrorSuccess;CFRelease(value);break;
        }if(!moved)return error(@"Window unavailable or refused placement");
    }
    else return error(@"Invalid command or no document open");
    return @{@"ok":@YES};
}
static CFDataRef handle(CFMessagePortRef port,SInt32 msg,CFDataRef data,void *ctx){
    @autoreleasepool{
        NSArray *a=[NSJSONSerialization JSONObjectWithData:(__bridge NSData*)data options:0 error:nil];
        NSDictionary *result=[a isKindOfClass:NSArray.class]?perform(a):error(@"Invalid request");
        return CFBridgingRetain([NSJSONSerialization dataWithJSONObject:result options:0 error:nil]);
    }
}
int listViewerDisplays(void);
int runViewer(CGDirectDisplayID target,NSString *path);
int main(int argc,char **argv){@autoreleasepool{
    NSArray *args=NSProcessInfo.processInfo.arguments;

    if(argc==2 && [args[1] isEqual:@"viewer-displays"])return listViewerDisplays();
    if(argc==4 && [args[1] isEqual:@"viewer-stream"])return runViewer([args[2] intValue],args[3]);
    if(argc>=2 && [args[1] isEqual:@"doctor"]){
        CGDirectDisplayID ids[64];uint32_t count=0;
        CGError result=CGGetOnlineDisplayList(64,ids,&count);
        if(result!=kCGErrorSuccess){fprintf(stderr,"Could not enumerate displays (%d)\n",result);return 1;}
        NSMutableArray *owned=[NSMutableArray array];
        for(uint32_t i=0;i<count;i++){
            CGDirectDisplayID id=ids[i];
            if(CGDisplayVendorNumber(id)==0x4b41 && CGDisplayModelNumber(id)==1)
                [owned addObject:@{@"display":@(id),@"serial":@(CGDisplaySerialNumber(id)),@"awake":@(!CGDisplayIsAsleep(id))}];
        }
        NSDictionary *session=CFBridgingRelease(CGSessionCopyCurrentDictionary());
        NSDictionary *report=@{@"sessionLocked":@([session[@"CGSSessionScreenIsLocked"] boolValue]),@"workspaceDisplays":owned};
        NSData *data=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
        puts([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] UTF8String]);return 0;
    }
    if(argc==1 || [args[1] hasPrefix:@"-psn"] || [args[1] isEqual:@"serve"]){
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        CFMessagePortRef port=CFMessagePortCreateLocal(NULL,(__bridge CFStringRef)service(),handle,NULL,NULL);
        if(!port){fputs("Workspace IPC registration failed.\n",stderr);return 1;}

        CFRunLoopSourceRef src=CFMessagePortCreateRunLoopSource(NULL,port,0);CFRunLoopAddSource(CFRunLoopGetMain(),src,kCFRunLoopCommonModes);
        [NSApp run];return 0;
    }
    CFMessagePortRef remote=CFMessagePortCreateRemote(NULL,(__bridge CFStringRef)service());
    if(!remote){fprintf(stderr,"Virtual Display display offline. Run start first.\n");return 1;}
    NSData *data=[NSJSONSerialization dataWithJSONObject:[args subarrayWithRange:NSMakeRange(1,argc-1)] options:0 error:nil];
    CFDataRef reply=NULL;SInt32 status=CFMessagePortSendRequest(remote,1,(__bridge CFDataRef)data,3,12,kCFRunLoopDefaultMode,&reply);
    if(status!=0||!reply){fprintf(stderr,"Desktop host did not reply\n");return 1;}
    NSData *body=CFBridgingRelease(reply);puts([[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] UTF8String]);
    return [[NSJSONSerialization JSONObjectWithData:body options:0 error:nil] objectForKey:@"error"]?1:0;
}}
