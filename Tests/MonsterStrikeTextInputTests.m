#import <XCTest/XCTest.h>
// Compile the production reader in this translation unit to test its bounded
// memory checks without bypassing the game's runtime/version allowlist.
#import "../TweakLoader/MonsterStrikeTextInput.m"
#import "../MultitaskSupport/TapSyncDiagnostics.h"

typedef struct {
    struct mach_header_64 header;
    struct source_version_command preceding;
    struct uuid_command uuid;
} LCMSFixtureImage;

static LCMSFixtureImage LCMSKnownImage(void) {
    LCMSFixtureImage image = {0};
    image.header.magic = MH_MAGIC_64;
    image.header.ncmds = 2;
    image.header.sizeofcmds = sizeof(image.preceding) + sizeof(image.uuid);
    image.preceding.cmd = LC_SOURCE_VERSION;
    image.preceding.cmdsize = sizeof(image.preceding);
    image.uuid.cmd = LC_UUID;
    image.uuid.cmdsize = sizeof(image.uuid);
    const uint8_t verifiedUUID[16] = {0x0f,0xb0,0x91,0xe2,0x19,0x1b,0x38,0x4b,0xa6,0x4a,0x49,0x2e,0x99,0x80,0x07,0x0a};
    memcpy(image.uuid.uuid, verifiedUUID, sizeof(verifiedUUID));
    return image;
}

static void LCMSPutPointer(uintptr_t address, uintptr_t value) {
    memcpy((void *)address, &value, sizeof(value));
}
static void LCMSPutByte(uintptr_t address, uint8_t value) {
    memcpy((void *)address, &value, sizeof(value));
}

@interface MonsterStrikeTextInputTests : XCTestCase
@property(nonatomic) uintptr_t previousBase, table;
@property(nonatomic) Class previousOwnerClass, previousFieldClass;
@property(nonatomic, strong) LCMonsterStrikeTextBinding *previousRemembered;
@property(nonatomic, copy) NSString *previousState;
@property(nonatomic, strong) NSMutableArray<NSMutableData *> *buffers;
@end

@implementation MonsterStrikeTextInputTests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    self.previousBase = LCMSImageBase;
    self.previousOwnerClass = LCMSOwnerClass;
    self.previousFieldClass = LCMSFieldClass;
    self.previousRemembered = LCMSRemembered;
    self.previousState = LCMSState;
    LCMSRemembered = nil;
    LCMSState = nil;
    LCMSImageBase = 0x170000000ULL;
    self.buffers = [NSMutableArray new];
    self.table = [self bytes:640];
    // Known Cocos node methods, relocated as they would be in an ASLR image.
    LCMSPutPointer(self.table + 312, LCMSImageBase + 0x266E5DC);
    LCMSPutPointer(self.table + 440, LCMSImageBase + 0x266E52C);
    LCMSPutPointer(self.table + 456, LCMSImageBase + 0x266E75C);
    LCMSPutPointer(self.table + 632, LCMSImageBase + 0x266E754);
}
- (void)tearDown {
    LCMSRemembered = self.previousRemembered;
    LCMSImageBase = self.previousBase;
    LCMSOwnerClass = self.previousOwnerClass;
    LCMSFieldClass = self.previousFieldClass;
    LCMSState = self.previousState;
    self.previousRemembered = nil;
    self.buffers = nil;
    [super tearDown];
}
- (uintptr_t)bytes:(NSUInteger)length {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    [self.buffers addObject:data];
    return (uintptr_t)data.mutableBytes;
}
- (uintptr_t)node {
    uintptr_t node = [self bytes:544];
    LCMSPutPointer(node, self.table);
    LCMSPutByte(node + 264, 1);
    LCMSPutByte(node + 268, 1);
    return node;
}
- (uintptr_t)setChildren:(NSArray<NSNumber *> *)children of:(uintptr_t)parent {
    uintptr_t array = [self bytes:32];
    uintptr_t data = [self bytes:16];
    uintptr_t entries = [self bytes:MAX(1, children.count) * sizeof(uintptr_t)];
    for (NSUInteger i = 0; i < children.count; i++) {
        uintptr_t child = (uintptr_t)children[i].unsignedLongLongValue;
        LCMSPutPointer(entries + i * sizeof(uintptr_t), child);
        if (child) LCMSPutPointer(child + 200, parent);
    }
    struct { uint32_t count, capacity; uintptr_t entries; } items = {
        (uint32_t)children.count, (uint32_t)children.count, entries
    };
    memcpy((void *)data, &items, sizeof(items));
    LCMSPutPointer(array, LCMSImageBase + 0x35300E0);
    LCMSPutPointer(array + 24, data);
    LCMSPutPointer(parent + 192, array);
    return data;
}

- (void)testVerifiedImageUUIDAcceptsRelocatedMemoryAndRejectsEveryChangedByte {
    LCMSFixtureImage image = LCMSKnownImage();
    XCTAssertTrue(LCMSHeaderMatches((uintptr_t)&image));
    for (NSUInteger i = 0; i < sizeof(image.uuid.uuid); i++) {
        image.uuid.uuid[i] ^= 0x80;
        XCTAssertFalse(LCMSHeaderMatches((uintptr_t)&image), @"UUID byte %lu", (unsigned long)i);
        image.uuid.uuid[i] ^= 0x80;
    }
    image.uuid.cmd = LC_SOURCE_VERSION;
    XCTAssertFalse(LCMSHeaderMatches((uintptr_t)&image));
}
- (void)testMalformedMachHeadersAndLoadCommandsAreRejected {
    LCMSFixtureImage valid = LCMSKnownImage(), image = valid;
    image.header.magic = MH_MAGIC;
    XCTAssertFalse(LCMSHeaderMatches((uintptr_t)&image));
    image = valid; image.header.ncmds = 257;
    XCTAssertFalse(LCMSHeaderMatches((uintptr_t)&image));
    image = valid; image.header.sizeofcmds = 65537;
    XCTAssertFalse(LCMSHeaderMatches((uintptr_t)&image));
    image = valid; image.header.sizeofcmds--;
    XCTAssertFalse(LCMSHeaderMatches((uintptr_t)&image));
    image = valid; image.preceding.cmdsize = 0;
    XCTAssertFalse(LCMSHeaderMatches((uintptr_t)&image));
    image = valid; image.preceding.cmdsize = sizeof(struct load_command) - 1;
    XCTAssertFalse(LCMSHeaderMatches((uintptr_t)&image));
    image = valid; image.preceding.cmdsize = UINT32_MAX;
    XCTAssertFalse(LCMSHeaderMatches((uintptr_t)&image));
    image = valid; image.uuid.cmdsize--;
    XCTAssertFalse(LCMSHeaderMatches((uintptr_t)&image));
    image = valid; image.header.ncmds = 1;
    XCTAssertFalse(LCMSHeaderMatches((uintptr_t)&image));
}
- (void)testMemoryReaderRejectsUnreadableOverflowAndOversizedRanges {
    uintptr_t source = [self bytes:32769], destination = [self bytes:32769];
    LCMSPutByte(source, 0x37);
    XCTAssertTrue(LCMSRead(source, (void *)destination, 32768));
    XCTAssertEqual(*(uint8_t *)destination, 0x37);
    XCTAssertFalse(LCMSRead(source, (void *)destination, 32769));
    XCTAssertFalse(LCMSRead(source, (void *)destination, 0));
    XCTAssertFalse(LCMSRead(0, (void *)destination, 1));
    XCTAssertFalse(LCMSRead(1, (void *)destination, 8));
    XCTAssertFalse(LCMSRead(UINTPTR_MAX - 3, (void *)destination, 8));
    XCTAssertFalse(LCMSRead(source, NULL, 1));
    XCTAssertFalse(LCMSHeaderMatches(1));
}
- (void)testScenePathRecordsOrderedChildIndicesAcrossAncestors {
    uintptr_t scene = [self node], sibling = [self node], panel = [self node], field = [self node];
    [self setChildren:@[@(sibling), @(panel)] of:scene];
    [self setChildren:@[@0, @0, @(field)] of:panel];
    XCTAssertEqualObjects(LCMSPath(field, scene), (@[@1, @2]));
    XCTAssertEqualObjects(LCMSPath(scene, scene), @[]);
    // Reordering changes the identity used to match equivalent account fields.
    [self setChildren:@[@(panel), @(sibling)] of:scene];
    XCTAssertEqualObjects(LCMSPath(field, scene), (@[@0, @2]));
}
- (void)testScenePathRejectsHiddenOrStoppedNodeAndAncestor {
    uintptr_t scene = [self node], panel = [self node], field = [self node];
    [self setChildren:@[@(panel)] of:scene];
    [self setChildren:@[@(field)] of:panel];
    for (NSNumber *address in @[@(field), @(panel), @(scene)]) {
        uintptr_t node = (uintptr_t)address.unsignedLongLongValue;
        for (NSNumber *offset in @[@264, @268]) {
            LCMSPutByte(node + offset.unsignedIntegerValue, 0);
            XCTAssertNil(LCMSPath(field, scene));
            LCMSPutByte(node + offset.unsignedIntegerValue, 1);
            XCTAssertNotNil(LCMSPath(field, scene));
        }
    }
}
- (void)testScenePathRejectsUnknownVTableEntries {
    uintptr_t node = [self node];
    for (NSNumber *offset in @[@312, @440, @456, @632]) {
        uintptr_t slot = self.table + offset.unsignedIntegerValue, original = 0;
        memcpy(&original, (void *)slot, sizeof(original));
        LCMSPutPointer(slot, original + 4);
        XCTAssertNil(LCMSPath(node, node));
        LCMSPutPointer(slot, original);
    }
    XCTAssertEqualObjects(LCMSPath(node, node), @[]);
}
- (void)testScenePathRejectsDetachedWrongParentAndDuplicateChild {
    uintptr_t scene = [self node], parent = [self node], field = [self node], other = [self node];
    XCTAssertNil(LCMSPath(field, scene));
    [self setChildren:@[@(field)] of:scene];
    [self setChildren:@[@(other)] of:parent];
    LCMSPutPointer(field + 200, parent);
    XCTAssertNil(LCMSPath(field, scene));
    [self setChildren:@[@(field), @(field)] of:scene];
    XCTAssertNil(LCMSPath(field, scene));
    [self setChildren:@[@(field)] of:scene];
    XCTAssertEqualObjects(LCMSPath(field, scene), @[@0]);
}
- (void)testScenePathRejectsCyclesThatHaveConsistentChildLinks {
    uintptr_t scene = [self node], first = [self node], second = [self node];
    [self setChildren:@[@(first)] of:second];
    [self setChildren:@[@(second)] of:first];
    XCTAssertNil(LCMSPath(first, scene));
    [self setChildren:@[@(first)] of:first];
    XCTAssertNil(LCMSPath(first, scene));
}
- (void)testScenePathDepthIsBoundedAtSixtyFourEdges {
    uintptr_t scene = [self node], current = scene;
    for (NSUInteger i = 0; i < 64; i++) {
        uintptr_t child = [self node];
        [self setChildren:@[@(child)] of:current];
        current = child;
    }
    XCTAssertEqual(LCMSPath(current, scene).count, 64u);
    uintptr_t tooDeep = [self node];
    [self setChildren:@[@(tooDeep)] of:current];
    XCTAssertNil(LCMSPath(tooDeep, scene));
}
- (void)testChildArrayBoundariesRejectCorruptionBeforeReadingEntries {
    uintptr_t scene = [self node], field = [self node];
    NSMutableArray *children = [NSMutableArray arrayWithCapacity:4096];
    for (NSUInteger i = 0; i < 4095; i++) [children addObject:@0];
    [children addObject:@(field)];
    uintptr_t data = [self setChildren:children of:scene];
    XCTAssertEqualObjects(LCMSChildIndex(scene, field), @4095);
    uint32_t *counts = (uint32_t *)data;
    counts[0] = 4097; counts[1] = 4097;
    XCTAssertNil(LCMSChildIndex(scene, field));
    counts[0] = 4096; counts[1] = 4095;
    XCTAssertNil(LCMSChildIndex(scene, field));
    counts[0] = 0; counts[1] = 4096;
    XCTAssertNil(LCMSChildIndex(scene, field));
    counts[0] = 1;
    LCMSPutPointer(data + 8, 1);
    XCTAssertNil(LCMSChildIndex(scene, field));
    [self setChildren:@[@(field)] of:scene];
    uintptr_t array = 0;
    memcpy(&array, (void *)(scene + 192), sizeof(array));
    LCMSPutPointer(array, LCMSImageBase + 0x35300E8);
    XCTAssertNil(LCMSChildIndex(scene, field));
}
- (void)testCurrentSceneRequiresKnownDirectorAndNoPendingTransition {
    uintptr_t slot = [self bytes:sizeof(uintptr_t)], director = [self bytes:192], scene = [self node];
    LCMSImageBase = slot - 0x4B9C608;
    LCMSPutPointer(slot, director);
    LCMSPutPointer(director, LCMSImageBase + 0x352FEC8);
    LCMSPutPointer(director + 176, scene);
    uintptr_t current = 0;
    XCTAssertTrue(LCMSCurrentScene(&current));
    XCTAssertEqual(current, scene);
    LCMSPutPointer(director + 184, scene);
    XCTAssertFalse(LCMSCurrentScene(&current));
    LCMSPutPointer(director + 184, 0);
    LCMSPutPointer(director + 176, 0);
    XCTAssertFalse(LCMSCurrentScene(&current));
    LCMSPutPointer(director + 176, scene);
    LCMSPutPointer(director, LCMSImageBase + 0x352FEC9);
    XCTAssertFalse(LCMSCurrentScene(&current));
    LCMSPutPointer(slot, 1);
    XCTAssertFalse(LCMSCurrentScene(&current));
}
- (void)testRenderedLabelsMustBeDistinctLiveChildrenWithKnownClasses {
    uintptr_t labelTable = [self bytes:640];
    LCMSImageBase = labelTable - 0x35310C0;
    LCMSPutPointer(labelTable + 312, LCMSImageBase + 0x266E5DC);
    LCMSPutPointer(labelTable + 440, LCMSImageBase + 0x266E52C);
    LCMSPutPointer(labelTable + 456, LCMSImageBase + 0x266E75C);
    LCMSPutPointer(labelTable + 632, LCMSImageBase + 0x266E754);
    uintptr_t impl = [self bytes:40], node = [self node], text = [self node], placeholder = [self node];
    LCMSPutPointer(text, labelTable);
    LCMSPutPointer(placeholder, labelTable);
    LCMSPutPointer(impl + 24, text);
    LCMSPutPointer(impl + 32, placeholder);
    [self setChildren:@[@(text), @(placeholder)] of:node];
    XCTAssertTrue(LCMSLabels(impl, node));
    // Cocos hides the placeholder when it displays entered text. Hidden labels
    // remain valid while they still belong to this live edit box.
    LCMSPutByte(placeholder + 268, 0);
    XCTAssertTrue(LCMSLabels(impl, node));
    LCMSPutPointer(impl + 32, text);
    XCTAssertFalse(LCMSLabels(impl, node));
    LCMSPutPointer(impl + 32, placeholder);
    for (NSNumber *value in @[@(text), @(placeholder)]) {
        uintptr_t label = value.unsignedLongLongValue;
        LCMSPutPointer(label, self.table);
        XCTAssertFalse(LCMSLabels(impl, node));
        LCMSPutPointer(label, labelTable);
        LCMSPutPointer(label + 200, 0);
        XCTAssertFalse(LCMSLabels(impl, node));
        LCMSPutPointer(label + 200, node);
        LCMSPutByte(label + 264, 0);
        XCTAssertFalse(LCMSLabels(impl, node));
        LCMSPutByte(label + 264, 1);
        XCTAssertTrue(LCMSLabels(impl, node));
    }
    [self setChildren:@[@(text)] of:node];
    XCTAssertFalse(LCMSLabels(impl, node));
    [self setChildren:@[@(text), @(placeholder)] of:node];
    LCMSPutPointer(impl + 32, 1);
    XCTAssertFalse(LCMSLabels(impl, node));
    LCMSPutPointer(impl + 32, 0);
    XCTAssertFalse(LCMSLabels(impl, node));
}
- (void)testDiscardInvalidatesOutstandingBindingReferences {
    LCMonsterStrikeTextBinding *binding = [LCMonsterStrikeTextBinding new];
    LCMSRemembered = binding;
    XCTAssertFalse(binding.invalidated);
    [LCMonsterStrikeTextInput discard];
    XCTAssertNil(LCMSRemembered);
    XCTAssertTrue(binding.invalidated);
    // A client retaining an earlier binding must not revive it after discard.
    XCTAssertFalse([binding validate]);
    [LCMonsterStrikeTextInput discard];
    XCTAssertTrue(binding.invalidated);
}
- (void)testUnrelatedHostCannotEnableGameAdapter {
    LCMSImageBase = 0;
    LCMSOwnerClass = Nil;
    LCMSFieldClass = Nil;
    XCTAssertFalse(LCMSEnabled());
    UITextField *field = [UITextField new];
    [LCMonsterStrikeTextInput didBeginEditing:field];
    XCTAssertNil(LCMSRemembered);
    XCTAssertNil([LCMonsterStrikeTextInput bindingForWindow:[UIWindow new] field:field]);
}
- (void)testDiagnosticsOnlyCopyKnownGameStateTokens {
    NSMutableDictionary *failure = [@{@"reason": @"noFocusedInput", @"stage": @"guestPrepare", @"mode": @"text"} mutableCopy];
    for (NSString *token in @[@"imageUnsupported", @"noRememberedField", @"bindingInvalidated", @"fieldChanged",
        @"geometryChanged", @"ownerChanged", @"sceneChanged", @"nodeChanged", @"ready", @"selectionRejected"]) {
        failure[@"gameTextState"] = token;
        XCTAssertEqualObjects(LCTapSyncSanitizedInputFailure(failure)[@"gameTextState"], token);
    }
    for (id rejected in @[@"search text typed by a user", @"ready\nprivate text", @"Ready", @"", @7, @[@"ready"], @{@"text": @"private"}, NSNull.null]) {
        failure[@"gameTextState"] = rejected;
        NSDictionary *sanitized = LCTapSyncSanitizedInputFailure(failure);
        XCTAssertNotNil(sanitized);
        XCTAssertNil(sanitized[@"gameTextState"]);
        XCTAssertEqualObjects(sanitized[@"reason"], @"noFocusedInput");
    }
}
@end
