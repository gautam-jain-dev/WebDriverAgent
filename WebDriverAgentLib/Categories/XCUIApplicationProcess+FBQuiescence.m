/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "XCUIApplicationProcess+FBQuiescence.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import "FBConfiguration.h"
#import "FBLogger.h"
#import "FBSettings.h"

/**
 Newer XCTest runtimes (Xcode >= ~16.3) renamed
 -[XCUIApplicationProcess waitForQuiescenceIncludingAnimationsIdle:] to the two-argument
 -[XCUIApplicationProcess waitForQuiescenceIncludingAnimationsIdle:isPreEvent:].
 The original swizzle-only approach left the one-argument selector undefined on such
 runtimes, so any direct call to it (e.g. from fb_waitUntilStableWithTimeout:) crashed
 with 'unrecognized selector'. This category now handles both API generations:
 - whichever selector exists gets swizzled (to honor waitForIdleTimeout / fb_shouldWaitForQuiescence);
 - whichever selector is missing gets a stub added via class_addMethod, so raw calls
   always resolve and are routed to the best available waiting API.
 */

static SEL oneArgSelector(void)
{
  return @selector(waitForQuiescenceIncludingAnimationsIdle:);
}

static SEL twoArgSelector(void)
{
  return NSSelectorFromString(@"waitForQuiescenceIncludingAnimationsIdle:isPreEvent:");
}

static void (*original_waitForQuiescenceIncludingAnimationsIdle)(id, SEL, BOOL);
static void (*original_waitForQuiescenceIncludingAnimationsIdlePreEvent)(id, SEL, BOOL, BOOL);

static void fb_swizzled_waitForQuiescenceIncludingAnimationsIdle(id self, SEL _cmd, BOOL includingAnimations)
{
  NSString *bundleId = [self bundleID];
  NSNumber *shouldWait = [self fb_shouldWaitForQuiescence];
  [FBLogger logFmt:@"[FBQuiescence] CALLED fb_swizzled_waitForQuiescenceIncludingAnimationsIdle; timeout = %.3fs, shouldWait = %@",
   FBConfiguration.waitForIdleTimeout, shouldWait];
  if (![shouldWait boolValue] || FBConfiguration.waitForIdleTimeout < DBL_EPSILON) {
    [FBLogger logFmt:@"[FBQuiescence] Quiescence disabled for %@; skipping", bundleId];
    return;
  }

  NSTimeInterval desiredTimeout = FBConfiguration.waitForIdleTimeout;
  NSTimeInterval previousTimeout = _XCTApplicationStateTimeout();
  _XCTSetApplicationStateTimeout(desiredTimeout);
  @try {
    if (nil != original_waitForQuiescenceIncludingAnimationsIdle) {
      // Legacy runtime: the one-arg method existed and was swizzled - call the original
      original_waitForQuiescenceIncludingAnimationsIdle(self, _cmd, includingAnimations);
    } else if ([self respondsToSelector:twoArgSelector()]) {
      // Modern runtime: route through the renamed two-arg API
      [FBLogger logFmt:@"[FBQuiescence] Using TWO-ARG API with timeout %.3fs", desiredTimeout];
      @try {
        void (*msgSendTwoArg)(id, SEL, BOOL, BOOL) = (void (*)(id, SEL, BOOL, BOOL))objc_msgSend;
        msgSendTwoArg(self, twoArgSelector(), includingAnimations, NO);
      } @catch (NSException *e) {
        [FBLogger logFmt:@"[FBQuiescence] two-arg invocation failed: %@", e];
      }
    } else if ([self respondsToSelector:@selector(waitForQuiescence)]) {
      [FBLogger logFmt:@"[FBQuiescence] FALLBACK -waitForQuiescence on %@", bundleId];
      [self waitForQuiescence];
    } else {
      [FBLogger logFmt:@"[FBQuiescence] No fallback available for %@; no-op", bundleId];
    }
  } @finally {
    _XCTSetApplicationStateTimeout(previousTimeout);
  }
}

static void fb_swizzled_waitForQuiescenceIncludingAnimationsIdlePreEvent(id self, SEL _cmd, BOOL includingAnimations, BOOL isPreEvent)
{
  NSString *bundleId = [self bundleID];
  if (![[self fb_shouldWaitForQuiescence] boolValue] || FBConfiguration.waitForIdleTimeout < DBL_EPSILON) {
    [FBLogger logFmt:@"[FBQuiescence] Quiescence disabled for %@; skipping", bundleId];
    return;
  }

  NSTimeInterval desiredTimeout = FBConfiguration.waitForIdleTimeout;
  NSTimeInterval previousTimeout = _XCTApplicationStateTimeout();
  _XCTSetApplicationStateTimeout(desiredTimeout);
  @try {
    original_waitForQuiescenceIncludingAnimationsIdlePreEvent(self, _cmd, includingAnimations, isPreEvent);
  } @finally {
    _XCTSetApplicationStateTimeout(previousTimeout);
  }
}

// Stub installed when the two-arg selector is absent (legacy runtimes). Routes
// callers of the modern API onto whatever this runtime does provide.
static void fb_stub_waitForQuiescenceIncludingAnimationsIdlePreEvent(id self, SEL _cmd, BOOL includingAnimations, BOOL isPreEvent)
{
  [FBLogger logFmt:@"[FBQuiescence]  twoArgStub; isPreEvent=%@", isPreEvent ? @"YES" : @"NO"];
  if (nil != original_waitForQuiescenceIncludingAnimationsIdle) {
    original_waitForQuiescenceIncludingAnimationsIdle(self, oneArgSelector(), includingAnimations);
  } else if ([self respondsToSelector:@selector(waitForQuiescence)]) {
    [self waitForQuiescence];
  }
}

@implementation XCUIApplicationProcess (FBQuiescence)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-load-method"

+ (void)load
{
  Method oneArgMethod = class_getInstanceMethod(self.class, oneArgSelector());
  if (nil != oneArgMethod) {
    original_waitForQuiescenceIncludingAnimationsIdle = (void (*)(id, SEL, BOOL)) method_setImplementation(oneArgMethod, (IMP)fb_swizzled_waitForQuiescenceIncludingAnimationsIdle);
    [FBLogger log:@"[FBQuiescence] Swizzled one-arg method"];
  } else {
    // The one-arg API is gone on this runtime, but WebDriverAgent code still calls it
    // directly. Install our implementation as a stub so the raw call always resolves.
    class_addMethod(self.class, oneArgSelector(), (IMP)fb_swizzled_waitForQuiescenceIncludingAnimationsIdle, "v@:B");
    [FBLogger log:@"[FBQuiescence] Added one-arg stub"];
  }

  Method twoArgMethod = class_getInstanceMethod(self.class, twoArgSelector());
  if (nil != twoArgMethod) {
    original_waitForQuiescenceIncludingAnimationsIdlePreEvent = (void (*)(id, SEL, BOOL, BOOL)) method_setImplementation(twoArgMethod, (IMP)fb_swizzled_waitForQuiescenceIncludingAnimationsIdlePreEvent);
    [FBLogger log:@"[FBQuiescence] Swizzled two-arg method"];
  } else {
    class_addMethod(self.class, twoArgSelector(), (IMP)fb_stub_waitForQuiescenceIncludingAnimationsIdlePreEvent, "v@:BB");
    [FBLogger log:@"[FBQuiescence] Added two-arg stub"];
  }
}

#pragma clang diagnostic pop

- (void)fb_waitForQuiescenceIncludingAnimationsIdle:(BOOL)includingAnimations
{
  if ([self respondsToSelector:twoArgSelector()]) {
    void (*msgSendTwoArg)(id, SEL, BOOL, BOOL) = (void (*)(id, SEL, BOOL, BOOL))objc_msgSend;
    msgSendTwoArg(self, twoArgSelector(), includingAnimations, NO);
    return;
  }
  if ([self respondsToSelector:oneArgSelector()]) {
    [self waitForQuiescenceIncludingAnimationsIdle:includingAnimations];
    return;
  }
  [FBLogger log:@"[FBQuiescence] No quiescence selector found; skipping wait"];
}

static char XCUIAPPLICATIONPROCESS_SHOULD_WAIT_FOR_QUIESCENCE;

@dynamic fb_shouldWaitForQuiescence;

- (NSNumber *)fb_shouldWaitForQuiescence
{
  id result = objc_getAssociatedObject(self, &XCUIAPPLICATIONPROCESS_SHOULD_WAIT_FOR_QUIESCENCE);
  if (nil == result) {
    return @(YES);
  }
  return (NSNumber *)result;
}

- (void)setFb_shouldWaitForQuiescence:(NSNumber *)value
{
  objc_setAssociatedObject(self, &XCUIAPPLICATIONPROCESS_SHOULD_WAIT_FOR_QUIESCENCE, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
