// Copyright (c) 2026 Ali Razavi. All rights reserved. Owned and controlled solely by Ali Razavi: no licence check, no remote control, no backdoor. Terms: see the LICENSE file.
// System calls macOS has but does not list publicly: showing a bar across the whole Touch Bar, screen and keyboard brightness, Night Shift, lock, show desktop, media.
#import <AppKit/AppKit.h>

extern void DFRElementSetControlStripPresenceForIdentifier(NSTouchBarItemIdentifier, BOOL);
@interface NSTouchBarItem (Private)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;
@end
@interface NSTouchBar (Private)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar placement:(long long)placement systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar *)touchBar;
@end

extern int DisplayServicesGetBrightness(CGDirectDisplayID, float *);
extern int DisplayServicesSetBrightness(CGDirectDisplayID, float);
extern void CoreDockSendNotification(CFStringRef, void *);
extern void SACLockScreenImmediate(void);
extern Boolean MRMediaRemoteSendCommand(unsigned int, id);

typedef struct { int hour; int minute; } CBTime;
typedef struct { CBTime fromTime; CBTime toTime; } CBSchedule;
typedef struct { BOOL active; BOOL enabled; BOOL sunSchedulePermitted; int mode; CBSchedule schedule; unsigned long long disableFlags; BOOL available; } CBBlueLightStatus;
@interface CBBlueLightClient : NSObject
- (BOOL)setEnabled:(BOOL)enabled;
- (BOOL)getBlueLightStatus:(CBBlueLightStatus *)status;
@end
@interface KeyboardBrightnessClient : NSObject
- (float)brightnessForKeyboard:(unsigned long long)kb;
- (BOOL)setBrightness:(float)b forKeyboard:(unsigned long long)kb;
- (NSArray *)copyKeyboardBacklightIDs;
@end
