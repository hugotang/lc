#import "MonsterStrikeTextInput.h"
#import "TextSyncInput.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/loader.h>
#include <string.h>

// This is an allowlist for the supplied Japanese 33.0.0 binary. No engine
// function pointer is invoked. Offsets are used only for bounded, checked reads.
// See docs/MonsterStrikeTextInput.md for the independently verified layout.
static uintptr_t LCMSImageBase;
static Class LCMSOwnerClass, LCMSFieldClass;
static NSString *LCMSState;
static const uint8_t LCMSImageUUID[16] = {0x0f,0xb0,0x91,0xe2,0x19,0x1b,0x38,0x4b,0xa6,0x4a,0x49,0x2e,0x99,0x80,0x07,0x0a};

static uintptr_t LCMSAddress(uintptr_t unslid) { return LCMSImageBase + (unslid - 0x100000000ULL); }
static BOOL LCMSRead(uintptr_t address, void *output, size_t size) {
    if (!address || !output || !size || size > 32768 || address > UINTPTR_MAX - size) return NO;
    vm_size_t copied = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)address, (vm_size_t)size, (vm_address_t)output, &copied) == KERN_SUCCESS && copied == size;
}
static BOOL LCMSPointer(uintptr_t address, uintptr_t *value) { return LCMSRead(address, value, sizeof(*value)); }
static BOOL LCMSPointerEquals(uintptr_t address, uintptr_t expected) {
    uintptr_t value = 0;
    return LCMSPointer(address, &value) && value == expected;
}
static BOOL LCMSMethod(Class cls, const char *name, uintptr_t address) {
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    return method && (uintptr_t)method_getImplementation(method) == LCMSAddress(address);
}
static BOOL LCMSHeaderMatches(uintptr_t base) {
    struct mach_header_64 header;
    if (!LCMSRead(base, &header, sizeof(header)) || header.magic != MH_MAGIC_64 ||
        header.ncmds > 256 || header.sizeofcmds > 65536) return NO;
    uintptr_t cursor = base + sizeof(header), limit = cursor + header.sizeofcmds;
    if (limit < cursor) return NO;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        struct load_command command;
        if (cursor > limit || limit - cursor < sizeof(command) || !LCMSRead(cursor, &command, sizeof(command)) ||
            command.cmdsize < sizeof(command) || command.cmdsize > limit - cursor) return NO;
        if (command.cmd == LC_UUID) {
            struct uuid_command uuid;
            return command.cmdsize == sizeof(uuid) && LCMSRead(cursor, &uuid, sizeof(uuid)) &&
                memcmp(uuid.uuid, LCMSImageUUID, sizeof(LCMSImageUUID)) == 0;
        }
        cursor += command.cmdsize;
    }
    return NO;
}
static BOOL LCMSEnabled(void) {
    if (!NSThread.isMainThread) return NO;
    if (!LCMSImageBase) {
        NSBundle *bundle = NSBundle.mainBundle;
        if (![bundle.bundleIdentifier isEqual:@"jp.co.mixi.monsterstrike"]) return NO;
        LCMSState = @"imageUnsupported";
        if (![bundle.infoDictionary[@"CFBundleShortVersionString"] isEqual:@"33.0.0"] ||
            ![bundle.infoDictionary[@"CFBundleVersion"] isEqual:@"33.0.0.1"]) return NO;
        Class owner = NSClassFromString(@"EditBoxImplIOS"), field = NSClassFromString(@"CustomUITextField");
        Method method = class_getInstanceMethod(owner, sel_registerName("textFieldDidEndEditing:"));
        Dl_info info;
        if (!method || !dladdr((const void *)method_getImplementation(method), &info) || !LCMSHeaderMatches((uintptr_t)info.dli_fbase)) return NO;
        uintptr_t base = (uintptr_t)info.dli_fbase;
        if ((uintptr_t)owner != base + 0x37A11D0 || (uintptr_t)field != base + 0x37A11F8 ||
            class_getSuperclass(field) != UITextField.class) return NO;
        Ivar fieldIvar = class_getInstanceVariable(owner, "textField_");
        Ivar implIvar = class_getInstanceVariable(owner, "editBox_");
        if (!fieldIvar || !implIvar || ivar_getOffset(fieldIvar) != 8 || ivar_getOffset(implIvar) != 16) return NO;
        LCMSImageBase = base;
        LCMSOwnerClass = owner;
        LCMSFieldClass = field;
        LCMSState = @"noRememberedField";
    }
    // Recheck the methods used by replay, including after an external tweak
    // replaces a delegate method. Never call an unverified refresh selector.
    return LCMSMethod(LCMSOwnerClass, "textField", 0x10117C83C) &&
        LCMSMethod(LCMSOwnerClass, "editBox", 0x101645490) &&
        LCMSMethod(LCMSOwnerClass, "textChanged", 0x100EE3C14) &&
        LCMSMethod(LCMSOwnerClass, "textFieldDidEndEditing:", 0x100729D44) &&
        LCMSMethod(LCMSOwnerClass, "textField:shouldChangeCharactersInRange:replacementString:", 0x101265A50);
}

static BOOL LCMSNode(uintptr_t node, BOOL visible) {
    uintptr_t table = 0;
    uint8_t running = 0, shown = 0;
    return LCMSPointer(node, &table) &&
        LCMSPointerEquals(table + 312, LCMSAddress(0x10266E5DC)) &&
        LCMSPointerEquals(table + 440, LCMSAddress(0x10266E52C)) &&
        LCMSPointerEquals(table + 456, LCMSAddress(0x10266E75C)) &&
        LCMSPointerEquals(table + 632, LCMSAddress(0x10266E754)) &&
        LCMSRead(node + 264, &running, 1) && running == 1 &&
        LCMSRead(node + 268, &shown, 1) && (!visible || shown == 1);
}
static NSNumber *LCMSChildIndex(uintptr_t parent, uintptr_t child) {
    uintptr_t array = 0, data = 0;
    struct { uint32_t count, capacity; uintptr_t entries; } items;
    if (!LCMSPointer(parent + 192, &array) || !LCMSPointerEquals(array, LCMSAddress(0x1035300E0)) ||
        !LCMSPointer(array + 24, &data) || !LCMSRead(data, &items, sizeof(items)) ||
        !items.count || items.count > 4096 || items.count > items.capacity) return nil;
    uintptr_t entries[4096];
    if (!LCMSRead(items.entries, entries, items.count * sizeof(uintptr_t))) return nil;
    NSNumber *index = nil;
    for (uint32_t i = 0; i < items.count; i++) if (entries[i] == child) {
        if (index) return nil;
        index = @(i);
    }
    return index;
}
static NSArray<NSNumber *> *LCMSPath(uintptr_t node, uintptr_t scene) {
    NSMutableArray *path = [NSMutableArray new];
    uintptr_t visited[65];
    NSUInteger count = 0;
    while (node) {
        if (count >= 65 || !LCMSNode(node, YES)) return nil;
        for (NSUInteger i = 0; i < count; i++) if (visited[i] == node) return nil;
        visited[count++] = node;
        if (node == scene) return path.copy;
        uintptr_t parent = 0;
        if (!LCMSPointer(node + 200, &parent) || !parent || !LCMSNode(parent, YES)) return nil;
        NSNumber *index = LCMSChildIndex(parent, node);
        if (!index) return nil;
        [path insertObject:index atIndex:0];
        node = parent;
    }
    return nil;
}
static BOOL LCMSLabels(uintptr_t impl, uintptr_t node) {
    uintptr_t text = 0, placeholder = 0;
    if (!LCMSPointer(impl + 24, &text) || !LCMSPointer(impl + 32, &placeholder) ||
        !text || !placeholder || text == placeholder) return NO;
    for (NSNumber *value in @[@(text), @(placeholder)]) {
        uintptr_t label = value.unsignedLongLongValue;
        if (!LCMSPointerEquals(label, LCMSAddress(0x1035310C0)) ||
            !LCMSPointerEquals(label + 200, node) || !LCMSNode(label, NO) || !LCMSChildIndex(node, label)) return NO;
    }
    return YES;
}
static BOOL LCMSCurrentScene(uintptr_t *scene) {
    uintptr_t director = 0;
    return LCMSPointer(LCMSAddress(0x104B9C608), &director) &&
        LCMSPointerEquals(director, LCMSAddress(0x10352FEC8)) &&
        LCMSPointerEquals(director + 184, 0) && LCMSPointer(director + 176, scene) && *scene;
}
static BOOL LCMSRootVisible(UIView *root, UIWindow *window) {
    if (!root || !window || root.window != window || window.hidden || window.alpha <= 0.01 ||
        CGRectIsEmpty(root.bounds) || !CGRectIntersectsRect([root convertRect:root.bounds toView:window], window.bounds)) return NO;
    for (UIView *view = root; view; view = view.superview)
        if (view.hidden || view.alpha <= 0.01 || !view.userInteractionEnabled) return NO;
    return YES;
}

@interface LCMonsterStrikeTextBinding ()
@property(nonatomic, weak, readwrite) UITextField *field;
@property(nonatomic, copy, readwrite) NSDictionary *signature;
@property(nonatomic, weak) id owner;
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic, weak) UIView *root;
@property(nonatomic) uintptr_t implementation, node, scene;
@property(nonatomic) CGRect frame;
@property(nonatomic) BOOL invalidated;
@end

@implementation LCMonsterStrikeTextBinding
- (BOOL)validate {
    if (!LCMSEnabled()) return NO;
    LCMSState = @"bindingInvalidated";
    if (self.invalidated) return NO;
    UITextField *field = self.field;
    id owner = self.owner;
    LCMSState = @"fieldChanged";
    if (!field || !owner || object_getClass(field) != LCMSFieldClass || object_getClass(owner) != LCMSOwnerClass ||
        LCTextSyncOriginalDelegate(field) != owner || field.secureTextEntry || !field.enabled || !field.userInteractionEnabled) return NO;
    LCMSState = @"geometryChanged";
    if (self.window.rootViewController.viewIfLoaded != self.root || !LCMSRootVisible(self.root, self.window) ||
        !CGRectEqualToRect(field.frame, self.frame) || CGRectIsEmpty(field.bounds)) return NO;
    if (field.superview && (field.superview != self.root || field.window != self.window)) return NO;
    uintptr_t impl = self.implementation, node = self.node, current = 0, table = 0;
    LCMSState = @"ownerChanged";
    if (!impl || !node || !LCMSPointerEquals((uintptr_t)(__bridge void *)owner + 8, (uintptr_t)(__bridge void *)field) ||
        !LCMSPointerEquals((uintptr_t)(__bridge void *)owner + 16, impl) ||
        !LCMSPointerEquals(impl, LCMSAddress(0x10339DC20)) ||
        !LCMSPointerEquals(impl + 16, node) || !LCMSPointerEquals(impl + 64, (uintptr_t)(__bridge void *)owner) ||
        !LCMSPointerEquals(node + 536, impl) || !LCMSPointer(node, &table) ||
        (table != LCMSAddress(0x1031F4170) && table != LCMSAddress(0x1034AB858)) || !LCMSLabels(impl, node)) return NO;
    LCMSState = @"sceneChanged";
    if (!LCMSCurrentScene(&current) || current != self.scene) return NO;
    LCMSState = @"nodeChanged";
    NSArray *path = LCMSPath(node, current);
    if (!path || ![path isEqual:self.signature[@"path"]]) return NO;
    LCMSState = @"ready";
    return YES;
}
- (BOOL)refreshRenderedText {
    if (![self validate]) return NO;
    UITextField *field = self.field;
    // The exact allowlisted method only refreshes labels through impl +208.
    // It does not call shouldEnd, normalize text, submit, or acquire the keyboard.
    if (field.hidden) {
        id owner = self.owner;
        ((void (*)(id, SEL, id))objc_msgSend)(owner, sel_registerName("textFieldDidEndEditing:"), field);
    }
    return [self validate];
}
@end

static LCMonsterStrikeTextBinding *LCMSRemembered;

@implementation LCMonsterStrikeTextInput
+ (void)didBeginEditing:(UIView *)view {
    if (!NSThread.isMainThread) return;
    [self discard];
    if (!LCMSEnabled() || object_getClass(view) != LCMSFieldClass) return;
    LCMSState = @"selectionRejected";
    UITextField *field = (UITextField *)view;
    UIWindow *window = field.window;
    UIView *root = window.rootViewController.viewIfLoaded;
    id owner = LCTextSyncOriginalDelegate(field);
    if (object_getClass(owner) != LCMSOwnerClass || !field.isFirstResponder || field.hidden || field.superview != root ||
        field.secureTextEntry || !field.enabled || !LCMSRootVisible(root, window)) return;
    uintptr_t impl = 0, node = 0, scene = 0;
    if (!LCMSPointer((uintptr_t)(__bridge void *)owner + 16, &impl) || !LCMSPointer(impl + 16, &node) ||
        !LCMSCurrentScene(&scene)) return;
    NSArray *path = LCMSPath(node, scene);
    if (!path.count) return;
    LCMonsterStrikeTextBinding *binding = [LCMonsterStrikeTextBinding new];
    binding.field = field;
    binding.owner = owner;
    binding.window = window;
    binding.root = root;
    binding.frame = field.frame;
    binding.implementation = impl;
    binding.node = node;
    binding.scene = scene;
    binding.signature = @{@"kind": @"field", @"path": path, @"identifier": @"monsterstrike-33-native"};
    if ([binding validate]) LCMSRemembered = binding;
}
+ (LCMonsterStrikeTextBinding *)bindingForWindow:(UIWindow *)window field:(UITextField *)field {
    if (!NSThread.isMainThread || !LCMSEnabled()) return nil;
    if (field.isFirstResponder && (LCMSRemembered.field != field || ![LCMSRemembered validate])) [self didBeginEditing:field];
    LCMonsterStrikeTextBinding *binding = LCMSRemembered;
    if (!binding) return nil;
    if (binding.window != window || (field && binding.field != field) || ![binding validate]) return nil;
    return binding;
}
+ (void)observeEvent:(UIEvent *)event {
    if (!LCMSRemembered || !NSThread.isMainThread) return;
    if (event.type == UIEventTypePresses) {
        if (!LCMSRemembered.field.isFirstResponder) [self discard];
        return;
    }
    if (event.type != UIEventTypeTouches) return;
    for (UITouch *touch in event.allTouches) if (touch.phase == UITouchPhaseBegan && touch.window == LCMSRemembered.window) {
        UITextField *field = LCMSRemembered.field;
        if (field.isFirstResponder && (touch.view == field || [touch.view isDescendantOfView:field])) continue;
        // Observe before UIKit dispatch: a new editing notification can select
        // the field again. Unrelated navigation invalidates even a retained node.
        [self discard];
        break;
    }
}
+ (void)discard {
    if (LCMSRemembered) LCMSState = @"bindingInvalidated";
    LCMSRemembered.invalidated = YES;
    LCMSRemembered = nil;
}
+ (NSString *)diagnosticState { return NSThread.isMainThread ? LCMSState : nil; }
@end
