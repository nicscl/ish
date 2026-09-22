//
//  UITests.m
//  UITests
//
//  Created by Theodore Dubois on 11/13/20.
//

#import <XCTest/XCTest.h>

@interface UITests : XCTestCase
@property XCUIApplication *app;
@end

@implementation UITests

- (void)setUp {
    self.continueAfterFailure = NO;
    self.app = [XCUIApplication new];
    [self.app launch];
    XCTAssert([self.app.webViews.staticTexts.firstMatch waitForExistenceWithTimeout:30]);
}

- (XCUIElementQuery *)terminalLinesContaining:(NSString *)text {
    return [self.app.webViews.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS %@", text]];
}

- (void)waitForTerminalText:(NSString *)text timeout:(NSTimeInterval)timeout {
    XCTAssert([[self terminalLinesContaining:text].firstMatch waitForExistenceWithTimeout:timeout],
              @"expected terminal to show %@", text);
}

// Output produced while the terminal is not on screen must keep flowing: the shell
// must not stall, and the terminal must show everything once it is back.
// Uses the console switch (Cmd+Alt+Shift+1 / +7) to detach and reattach the session terminal.
- (void)testHiddenTerminalKeepsProcessingOutput {
    [self waitForTerminalText:@":~#" timeout:30];
    [self.app typeText:@"clear; seq 1 40000 > /dev/null; seq 1 3000; echo hidden-done-$((20+22))\n"];
    [self.app typeKey:@"1" modifierFlags:XCUIKeyModifierCommand | XCUIKeyModifierAlternate | XCUIKeyModifierShift];
    XCTAssertFalse([[self terminalLinesContaining:@"hidden-done-42"].firstMatch waitForExistenceWithTimeout:3],
                   @"session terminal should be hidden while looking at the console");
    [self.app typeKey:@"7" modifierFlags:XCUIKeyModifierCommand | XCUIKeyModifierAlternate | XCUIKeyModifierShift];
    [self waitForTerminalText:@"hidden-done-42" timeout:20];
    // and the shell is still responsive
    [self.app typeText:@"echo after-$((6*7))\n"];
    [self waitForTerminalText:@"after-42" timeout:15];
}

- (void)typeCommandKey:(NSString *)key {
    [self.app typeKey:key modifierFlags:XCUIKeyModifierCommand];
}

// Cmd+T opens a second shell, Cmd+1/Cmd+2 switch, and typed text lands in the selected one.
- (void)testTabsAreIndependentShells {
    [self waitForTerminalText:@":~#" timeout:30];
    [self.app typeText:@"export TABMARK=one; echo pid-one-$$\n"];
    [self waitForTerminalText:@"pid-one-" timeout:10];

    [self typeCommandKey:@"t"];
    [self waitForTerminalText:@":~#" timeout:30];
    [self.app typeText:@"echo mark-${TABMARK:-unset}; echo pid-two-$$\n"];
    [self waitForTerminalText:@"mark-unset" timeout:10];
    XCTAssertFalse([self terminalLinesContaining:@"pid-one-"].firstMatch.exists, @"new tab must have its own scrollback");

    [self typeCommandKey:@"1"];
    [self waitForTerminalText:@"pid-one-" timeout:10];
    XCTAssertFalse([self terminalLinesContaining:@"pid-two-"].firstMatch.exists, @"first tab must still show its own terminal");
    [self.app typeText:@"echo mark-${TABMARK:-unset}-again\n"];
    [self waitForTerminalText:@"mark-one-again" timeout:10];

    [self typeCommandKey:@"2"];
    [self waitForTerminalText:@"pid-two-" timeout:10];
    // Cmd+W closes the second tab and falls back to the first
    [self typeCommandKey:@"w"];
    [self waitForTerminalText:@"mark-one-again" timeout:10];
    [self.app typeText:@"echo still-$((6*7))\n"];
    [self waitForTerminalText:@"still-42" timeout:10];
    sleep(3); // let the closed shell die, so the log shows its terminal being freed
}

// The tab strip: + opens a tab, tapping a tab selects it, x closes it.
- (void)testTabStripTouch {
    [self waitForTerminalText:@":~#" timeout:30];
    XCUIElement *tabBar = self.app.otherElements[@"tab bar"];
    XCTAssert([tabBar waitForExistenceWithTimeout:5]);
    XCTAssert(self.app.buttons[@"tab 1"].exists);
    XCTAssertFalse(self.app.buttons[@"tab 2"].exists);

    [self.app.buttons[@"new tab"] tap];
    XCTAssert([self.app.buttons[@"tab 2"] waitForExistenceWithTimeout:5]);
    [self waitForTerminalText:@":~#" timeout:30];
    [self.app typeText:@"echo in-tab-two\n"];
    [self waitForTerminalText:@"in-tab-two" timeout:10];
    [self attachScreenshotNamed:@"two tabs"];

    [self.app.buttons[@"tab 1"] tap];
    XCTAssert([[self terminalLinesContaining:@"in-tab-two"].firstMatch waitForNonExistenceWithTimeout:5]);
    [self.app typeText:@"echo in-tab-one\n"];
    [self waitForTerminalText:@"in-tab-one" timeout:10];

    // The close control only shows on the selected (or hovered) tab.
    XCTAssertFalse(self.app.buttons[@"close tab 2"].isHittable);
    [self.app.buttons[@"tab 2"] tap];
    XCTAssert([self.app.buttons[@"close tab 2"] waitForExistenceWithTimeout:5]);
    [self.app.buttons[@"close tab 2"] tap];
    XCTAssert([self.app.buttons[@"tab 2"] waitForNonExistenceWithTimeout:5]);
    [self waitForTerminalText:@"in-tab-one" timeout:5];
}

// Enough tabs to overflow the strip on an iPad: the strip must scroll and stay usable.
- (void)testManyTabsOverflow {
    [self waitForTerminalText:@":~#" timeout:30];
    for (int i = 2; i <= 10; i++) {
        [self.app.buttons[@"new tab"] tap];
        NSString *tab = [NSString stringWithFormat:@"tab %d", i];
        XCTAssert([self.app.buttons[tab] waitForExistenceWithTimeout:5]);
    }
    [self waitForTerminalText:@":~#" timeout:30];
    [self.app typeText:@"echo in-tab-ten\n"];
    [self waitForTerminalText:@"in-tab-ten" timeout:10];
    [self attachScreenshotNamed:@"ten tabs"];
    // A drag that starts on a tab scrolls the strip; it neither selects nor closes that tab.
    XCTAssertFalse(self.app.buttons[@"tab 1"].isHittable);
    [self.app.buttons[@"tab 7"] swipeRight];
    XCTAssert([self.app.buttons[@"tab 1"] waitForExistenceWithTimeout:5]);
    XCTAssert(self.app.buttons[@"tab 1"].isHittable);
    XCTAssert(self.app.buttons[@"tab 7"].exists);
    [self waitForTerminalText:@"in-tab-ten" timeout:5];
    [self.app.buttons[@"tab 1"] tap];
    XCTAssert([[self terminalLinesContaining:@"in-tab-ten"].firstMatch waitForNonExistenceWithTimeout:5]);
    [self attachScreenshotNamed:@"ten tabs, first selected"];
}

// Cmd+I opens the rename dialog for the selected tab; Return confirms.
// Verified on an iPad with a hardware keyboard: in the Simulator the Cmd+I press never
// reaches the app at all (unlike Cmd+T/W), so the test only runs on a device.
- (void)testRenameTabShortcut {
#if TARGET_OS_SIMULATOR
    XCTSkip(@"Cmd+I is swallowed by the Simulator before it reaches the app");
#endif
    [self waitForTerminalText:@":~#" timeout:30];
    [self typeCommandKey:@"i"];
    XCUIElement *alert = self.app.alerts[@"Rename Tab"];
    XCTAssert([alert waitForExistenceWithTimeout:5]);
    [self.app typeText:@"builds\n"];
    XCTAssert([alert waitForNonExistenceWithTimeout:5]);
    XCTAssertEqualObjects(self.app.buttons[@"tab 1"].label, @"builds");
    // the terminal has focus again
    [self.app typeText:@"echo renamed-$((6*7))\n"];
    [self waitForTerminalText:@"renamed-42" timeout:10];
}

// When the only shell exits, a fresh one takes its place.
- (void)testLastShellExitRestarts {
    [self waitForTerminalText:@":~#" timeout:30];
    [self.app typeText:@"echo before-$((6*7)); sleep 2; exit\n"];
    [self waitForTerminalText:@"before-42" timeout:10];
    XCTAssert([[self terminalLinesContaining:@"before-42"].firstMatch waitForNonExistenceWithTimeout:20],
              @"old terminal should be replaced by a new shell");
    [self waitForTerminalText:@":~#" timeout:30];
    [self.app typeText:@"echo after-$((6*7))\n"];
    [self waitForTerminalText:@"after-42" timeout:10];
}

// Kept in the result bundle so the tab strip can be looked at after a run.
- (void)attachScreenshotNamed:(NSString *)name {
    XCTAttachment *attachment = [XCTAttachment attachmentWithScreenshot:[XCUIScreen.mainScreen screenshot]];
    attachment.name = name;
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
}

#pragma mark Commands menu

// A menu item, whichever accessibility type UIKit gives it.
- (XCUIElement *)menuItem:(NSString *)title {
    return self.app.collectionViews.buttons[title];
}

// Opens the tab strip's ⋯ menu and follows the given path of items, tapping each.
- (void)chooseCommand:(NSArray<NSString *> *)path {
    XCUIElement *commands = self.app.buttons[@"commands"];
    XCTAssert([commands waitForExistenceWithTimeout:5], @"the tab strip should have a commands button");
    [commands tap];
    for (NSString *title in path) {
        XCUIElement *item = [self menuItem:title];
        XCTAssert([item waitForExistenceWithTimeout:5], @"menu item %@ should exist", title);
        [item tap];
    }
}

// The ⋯ button offers every command by touch: New Tab opens a second shell.
- (void)testCommandsMenuNewTab {
    [self waitForTerminalText:@":~#" timeout:30];
    // Keep a look at the menu itself in the result bundle.
    [self chooseCommand:@[]];
    XCTAssert([[self menuItem:@"Shell"] waitForExistenceWithTimeout:5]);
    [self attachScreenshotNamed:@"commands menu"];
    [[self menuItem:@"Tabs"] tap];
    XCTAssert([[self menuItem:@"Next Tab"] waitForExistenceWithTimeout:5]);
    [self attachScreenshotNamed:@"tabs submenu"];
    // A tap well away from the menu (which hangs off the top-right corner) dismisses it.
    [[self.app.webViews.firstMatch coordinateWithNormalizedOffset:CGVectorMake(0.1, 0.9)] tap];
    XCTAssert([[self menuItem:@"Next Tab"] waitForNonExistenceWithTimeout:5]);

    [self chooseCommand:@[@"New Tab"]];
    XCTAssert([self.app.buttons[@"tab 2"] waitForExistenceWithTimeout:5]);
    [self waitForTerminalText:@":~#" timeout:30];
    [self.app typeText:@"echo in-new-tab-$((6*7))\n"];
    [self waitForTerminalText:@"in-new-tab-42" timeout:10];
}

// Shell › Duplicate Tab starts the new shell in the current one's directory.
- (void)testDuplicateTabKeepsDirectory {
    [self waitForTerminalText:@":~#" timeout:30];
    [self.app typeText:@"cd /tmp\n"];
    [self waitForTerminalText:@":/tmp#" timeout:10];
    [self chooseCommand:@[@"Shell", @"Duplicate Tab"]];
    XCTAssert([self.app.buttons[@"tab 2"] waitForExistenceWithTimeout:5]);
    [self.app typeText:@"echo dup-$PWD-$((6*7))\n"];
    [self waitForTerminalText:@"dup-/tmp-42" timeout:30];
}

// Shell › Send › Interrupt stops the foreground job like Ctrl+C would.
- (void)testSendInterrupt {
    [self waitForTerminalText:@":~#" timeout:30];
    [self.app typeText:@"sleep 60\n"];
    sleep(1);
    [self chooseCommand:@[@"Shell", @"Send", @"Interrupt (Ctrl+C)"]];
    [self.app typeText:@"echo after-interrupt-$((6*7))\n"];
    [self waitForTerminalText:@"after-interrupt-42" timeout:10];
}

// A saved command runs in the current shell when it is at its prompt, and is offered
// a new tab when a job is in the foreground.
- (void)testSavedCommands {
    // Saved commands persist in the app's defaults, so a name a previous run may have left behind must not collide.
    NSString *name = [NSString stringWithFormat:@"Marker %u", arc4random_uniform(100000)];
    [self waitForTerminalText:@":~#" timeout:30];
    [self chooseCommand:@[@"Tools", @"Saved Commands", @"Add Saved Command…"]];
    XCUIElement *alert = self.app.alerts[@"Add Saved Command"];
    XCTAssert([alert waitForExistenceWithTimeout:5]);
    [[alert.textFields elementBoundByIndex:0] tap];
    [self.app typeText:name];
    [[alert.textFields elementBoundByIndex:1] tap];
    [self.app typeText:@"echo saved-$((6*7))"];
    [alert.buttons[@"Add"] tap];
    XCTAssert([alert waitForNonExistenceWithTimeout:5]);

    [self chooseCommand:@[@"Tools", @"Saved Commands", name]];
    [self waitForTerminalText:@"saved-42" timeout:10];

    [self.app typeText:@"clear; sleep 60\n"];
    sleep(1);
    [self chooseCommand:@[@"Tools", @"Saved Commands", name]];
    XCUIElement *busy = self.app.alerts.firstMatch;
    XCTAssert([busy waitForExistenceWithTimeout:5], @"a busy shell should offer a new tab");
    [busy.buttons[@"Run in New Tab"] tap];
    XCTAssert([self.app.buttons[@"tab 2"] waitForExistenceWithTimeout:5]);
    [self waitForTerminalText:@"saved-42" timeout:30];

    [self chooseCommand:@[@"Tools", @"Saved Commands", @"Remove", name]];
    [self chooseCommand:@[@"Tools", @"Saved Commands"]];
    XCTAssertFalse([self menuItem:name].exists, @"the removed command should be gone from the menu");
}

- (void)testShellRunsCommands {
    [self waitForTerminalText:@":~#" timeout:30];
    [self.app typeText:@"echo smoke-$((6*7)); uname -m\n"];
    [self waitForTerminalText:@"smoke-42" timeout:15];
    [self waitForTerminalText:@"i686" timeout:15];
}

@end
