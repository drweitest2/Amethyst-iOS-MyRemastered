//
// SurfaceViewController+TouchControllerIntegration.m
//
// Category to integrate TouchController message sending with SurfaceViewController touch lifecycle.
// Uses method swizzling to add sending without manual edits in many places.
//
// - Sends AddPointer (type 1) on touch begin and move (updates position).
// - Sends RemovePointer (type 2) on touch end/cancel.
// - Sends ClearPointer (type 3) when no active touches remain.
//
// Pointer indices are allocated monotically increasing and NOT reused (meets TouchController README).
//

#import <objc/runtime.h>
#import "SurfaceViewController.h"
#import "TCTransport.h"

@interface SurfaceViewController (TouchControllerIntegration)
@property (nonatomic, strong) NSMutableDictionary<NSValue*, NSNumber*> *tcPointerMap;
@property (nonatomic, assign) int32_t tcNextPointerIndex;
@end

@implementation SurfaceViewController (TouchControllerIntegration)

- (void)tc_setupTouchController {
    if (!self.tcPointerMap) {
        self.tcPointerMap = [NSMutableDictionary dictionary];
        self.tcNextPointerIndex = 1; // start from 1 and monotonically increase
    }
}

// return existing index or create if createIfMissing==YES; return -1 if not found and not create
- (int32_t)tc_pointerIndexForTouch:(UITouch *)touch createIfMissing:(BOOL)create {
    if (!touch) return -1;
    NSValue *key = [NSValue valueWithNonretainedObject:touch];
    NSNumber *n = self.tcPointerMap[key];
    if (n) return n.intValue;
    if (!create) return -1;
    int32_t idx = self.tcNextPointerIndex++;
    self.tcPointerMap[key] = @(idx);
    return idx;
}

- (void)tc_removePointerForTouch:(UITouch *)touch {
    if (!touch) return;
    NSValue *key = [NSValue valueWithNonretainedObject:touch];
    [self.tcPointerMap removeObjectForKey:key];
}

- (void)tc_handleTouch:(UITouch *)touch event:(int)action {
    // action: 0 = down, 1 = move, 2 = up
    if (!touch) return;

    // Skip indirect pointer touches (they are handled separately in existing code)
    if (touch.type == UITouchTypeIndirectPointer) return;

    CGRect bounds = self.rootView.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;

    CGPoint loc = [touch locationInView:self.rootView];
    float nx = (float)(loc.x / bounds.size.width);
    float ny = (float)(loc.y / bounds.size.height);

    // Clamp to [0,1]
    if (nx < 0.0f) nx = 0.0f;
    if (nx > 1.0f) nx = 1.0f;
    if (ny < 0.0f) ny = 0.0f;
    if (ny > 1.0f) ny = 1.0f;

    if (action == 0) {
        int32_t idx = [self tc_pointerIndexForTouch:touch createIfMissing:YES];
        TC_SendAddPointer(idx, nx, ny);
    } else if (action == 1) {
        int32_t idx = [self tc_pointerIndexForTouch:touch createIfMissing:NO];
        if (idx > 0) {
            TC_SendAddPointer(idx, nx, ny); // AddPointer updates position as well
        }
    } else if (action == 2) {
        int32_t idx = [self tc_pointerIndexForTouch:touch createIfMissing:NO];
        if (idx > 0) {
            TC_SendRemovePointer(idx);
            [self tc_removePointerForTouch:touch];
        }
        // If no active pointers left, clear all pointers on remote
        if (self.tcPointerMap.count == 0) {
            TC_SendClearPointer();
        }
    }
}

#pragma mark - Swizzle helpers

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [self class];

        // viewDidLoad -> call original then tc_setupTouchController
        SEL origVDLSel = @selector(viewDidLoad);
        SEL swzVDLSel = @selector(tc_swizzled_viewDidLoad);
        Method origVDL = class_getInstanceMethod(cls, origVDLSel);
        Method swzVDL = class_getInstanceMethod(cls, swzVDLSel);
        if (origVDL && swzVDL) method_exchangeImplementations(origVDL, swzVDL);

        // touchesBegan:withEvent:
        SEL origBegSel = @selector(touchesBegan:withEvent:);
        SEL swzBegSel = @selector(tc_swizzled_touchesBegan:withEvent:);
        Method origBeg = class_getInstanceMethod(cls, origBegSel);
        Method swzBeg = class_getInstanceMethod(cls, swzBegSel);
        if (origBeg && swzBeg) method_exchangeImplementations(origBeg, swzBeg);

        // touchesMoved:withEvent:
        SEL origMovSel = @selector(touchesMoved:withEvent:);
        SEL swzMovSel = @selector(tc_swizzled_touchesMoved:withEvent:);
        Method origMov = class_getInstanceMethod(cls, origMovSel);
        Method swzMov = class_getInstanceMethod(cls, swzMovSel);
        if (origMov && swzMov) method_exchangeImplementations(origMov, swzMov);

        // touchesEnded:withEvent:
        SEL origEndSel = @selector(touchesEnded:withEvent:);
        SEL swzEndSel = @selector(tc_swizzled_touchesEnded:withEvent:);
        Method origEnd = class_getInstanceMethod(cls, origEndSel);
        Method swzEnd = class_getInstanceMethod(cls, swzEndSel);
        if (origEnd && swzEnd) method_exchangeImplementations(origEnd, swzEnd);

        // touchesCancelled:withEvent:
        SEL origCanSel = @selector(touchesCancelled:withEvent:);
        SEL swzCanSel = @selector(tc_swizzled_touchesCancelled:withEvent:);
        Method origCan = class_getInstanceMethod(cls, origCanSel);
        Method swzCan = class_getInstanceMethod(cls, swzCanSel);
        if (origCan && swzCan) method_exchangeImplementations(origCan, swzCan);
    });
}

#pragma mark - Swizzled implementations

- (void)tc_swizzled_viewDidLoad {
    // call original viewDidLoad (because of swizzle, this calls original implementation)
    [self tc_swizzled_viewDidLoad];

    // Setup our TC pointer map
    [self tc_setupTouchController];
}

- (void)tc_swizzled_touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // call original
    [self tc_swizzled_touchesBegan:touches withEvent:event];

    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) continue;
        [self tc_handleTouch:touch event:0];
    }
}

- (void)tc_swizzled_touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // call original
    [self tc_swizzled_touchesMoved:touches withEvent:event];

    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) continue;
        [self tc_handleTouch:touch event:1];
    }
}

- (void)tc_swizzled_touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // call original
    [self tc_swizzled_touchesEnded:touches withEvent:event];

    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) continue;
        [self tc_handleTouch:touch event:2];
    }
}

- (void)tc_swizzled_touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // call original
    [self tc_swizzled_touchesCancelled:touches withEvent:event];

    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) continue;
        [self tc_handleTouch:touch event:2];
    }
}

#pragma mark - Associated properties

- (void)setTcPointerMap:(NSMutableDictionary<NSValue*,NSNumber*> *)tcPointerMap {
    objc_setAssociatedObject(self, @selector(tcPointerMap), tcPointerMap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSMutableDictionary<NSValue*,NSNumber*> *)tcPointerMap {
    return objc_getAssociatedObject(self, @selector(tcPointerMap));
}

- (void)setTcNextPointerIndex:(int32_t)tcNextPointerIndex {
    objc_setAssociatedObject(self, @selector(tcNextPointerIndex), @(tcNextPointerIndex), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (int32_t)tcNextPointerIndex {
    NSNumber *n = objc_getAssociatedObject(self, @selector(tcNextPointerIndex));
    return n ? n.intValue : 1;
}

@end