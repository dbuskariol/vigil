#ifndef KeyboardBacklightBridge_h
#define KeyboardBacklightBridge_h

#include <stdbool.h>

bool ANSKeyboardBacklightIsAvailable(void);
bool ANSKeyboardBacklightGetBrightness(float *brightness);
bool ANSKeyboardBacklightSetBrightness(float brightness);

#endif
