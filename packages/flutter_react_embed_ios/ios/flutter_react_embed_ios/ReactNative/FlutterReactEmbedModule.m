#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

// Exports the Swift class FlutterReactEmbedModule (Objective-C name
// FlutterReactEmbed) as NativeModules.FlutterReactEmbed.
@interface RCT_EXTERN_MODULE(FlutterReactEmbed, RCTEventEmitter)

RCT_EXTERN_METHOD(postMessage:(NSString *)runtimeId frame:(NSString *)frame)

@end
