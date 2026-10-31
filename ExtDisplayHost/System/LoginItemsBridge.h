//
//  LoginItemsBridge.h
//  ExtDisplayHost
//
//  Adds/removes the app in the macOS "Open at Login" list (System Settings → General → Login Items).
//

#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>

NS_ASSUME_NONNULL_BEGIN

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static inline BOOL ExtDisplayOpenAtLoginContains(NSURL *appURL) {
    LSSharedFileListRef list = LSSharedFileListCreate(kCFAllocatorDefault, kLSSharedFileListSessionLoginItems, NULL);
    if (!list) return NO;
    UInt32 seed = 0;
    CFArrayRef snapshot = LSSharedFileListCopySnapshot(list, &seed);
    BOOL found = NO;
    if (snapshot) {
        NSString *targetName = appURL.lastPathComponent;
        CFIndex count = CFArrayGetCount(snapshot);
        for (CFIndex i = 0; i < count; i++) {
            LSSharedFileListItemRef item = (LSSharedFileListItemRef)CFArrayGetValueAtIndex(snapshot, i);
            CFURLRef urlRef = LSSharedFileListItemCopyResolvedURL(item, kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes, NULL);
            if (urlRef) {
                NSURL *itemURL = (__bridge_transfer NSURL *)urlRef;
                if ([itemURL.path isEqualToString:appURL.path] || [itemURL.lastPathComponent isEqualToString:targetName]) {
                    found = YES;
                    break;
                }
            }
        }
        CFRelease(snapshot);
    }
    CFRelease(list);
    return found;
}

static inline BOOL ExtDisplayOpenAtLoginSet(NSURL *appURL, BOOL enabled) {
    LSSharedFileListRef list = LSSharedFileListCreate(kCFAllocatorDefault, kLSSharedFileListSessionLoginItems, NULL);
    if (!list) return NO;
    UInt32 seed = 0;
    CFArrayRef snapshot = LSSharedFileListCopySnapshot(list, &seed);
    NSString *targetName = appURL.lastPathComponent;

    if (snapshot) {
        CFIndex count = CFArrayGetCount(snapshot);
        for (CFIndex i = 0; i < count; i++) {
            LSSharedFileListItemRef item = (LSSharedFileListItemRef)CFArrayGetValueAtIndex(snapshot, i);
            CFURLRef urlRef = LSSharedFileListItemCopyResolvedURL(item, kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes, NULL);
            if (urlRef) {
                NSURL *itemURL = (__bridge_transfer NSURL *)urlRef;
                BOOL sameApp = [itemURL.path isEqualToString:appURL.path] || [itemURL.lastPathComponent isEqualToString:targetName];
                if (sameApp) {
                    LSSharedFileListItemRemove(list, item);
                }
            }
        }
        CFRelease(snapshot);
    }

    if (enabled) {
        NSDictionary *props = @{ (__bridge NSString *)kLSSharedFileListLoginItemHidden: @YES };
        LSSharedFileListItemRef inserted = LSSharedFileListInsertItemURL(
            list, kLSSharedFileListItemLast, NULL, NULL, (__bridge CFURLRef)appURL,
            (__bridge CFDictionaryRef)props, NULL);
        if (inserted) {
            CFRelease(inserted);
        }
    }
    CFRelease(list);
    return YES;
}

#pragma clang diagnostic pop

NS_ASSUME_NONNULL_END

