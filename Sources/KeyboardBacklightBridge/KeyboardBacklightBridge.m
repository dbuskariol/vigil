#import "KeyboardBacklightBridge.h"
#import <Foundation/Foundation.h>

@interface NSObject (ANSKeyboardBrightnessClient)
- (id)copyKeyboardBacklightIDs;
- (float)brightnessForKeyboard:(unsigned long long)keyboard;
- (BOOL)setBrightness:(float)brightness forKeyboard:(unsigned long long)keyboard;
@end

static id ANSKeyboardBrightnessClient(void) {
    static id client = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/CoreBrightness.framework"];
        [bundle load];
        Class cls = NSClassFromString(@"KeyboardBrightnessClient");
        if (cls != Nil) {
            client = [[cls alloc] init];
        }
    });
    return client;
}

static unsigned long long ANSKeyboardID(void) {
    id client = ANSKeyboardBrightnessClient();
    if (client == nil || ![client respondsToSelector:@selector(copyKeyboardBacklightIDs)]) {
        return 1;
    }

    id ids = [client copyKeyboardBacklightIDs];
    if ([ids respondsToSelector:@selector(count)] && [ids count] > 0) {
        id first = [ids objectAtIndex:0];
        if ([first respondsToSelector:@selector(unsignedLongLongValue)]) {
            return [first unsignedLongLongValue];
        }
    }

    return 1;
}

bool ANSKeyboardBacklightIsAvailable(void) {
    id client = ANSKeyboardBrightnessClient();
    return client != nil
        && [client respondsToSelector:@selector(brightnessForKeyboard:)]
        && [client respondsToSelector:@selector(setBrightness:forKeyboard:)];
}

bool ANSKeyboardBacklightGetBrightness(float *brightness) {
    if (brightness == NULL || !ANSKeyboardBacklightIsAvailable()) {
        return false;
    }

    *brightness = [ANSKeyboardBrightnessClient() brightnessForKeyboard:ANSKeyboardID()];
    return true;
}

bool ANSKeyboardBacklightSetBrightness(float brightness) {
    if (!ANSKeyboardBacklightIsAvailable()) {
        return false;
    }

    if (brightness < 0.0f) {
        brightness = 0.0f;
    } else if (brightness > 1.0f) {
        brightness = 1.0f;
    }

    return [ANSKeyboardBrightnessClient() setBrightness:brightness forKeyboard:ANSKeyboardID()];
}
