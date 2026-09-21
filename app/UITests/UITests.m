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

- (void)testShellRunsCommands {
    [self waitForTerminalText:@":~#" timeout:30];
    [self.app typeText:@"echo smoke-$((6*7)); uname -m\n"];
    [self waitForTerminalText:@"smoke-42" timeout:15];
    [self waitForTerminalText:@"i686" timeout:15];
}

@end
