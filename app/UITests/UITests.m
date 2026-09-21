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

- (void)testShellRunsCommands {
    [self waitForTerminalText:@":~#" timeout:30];
    [self.app typeText:@"echo smoke-$((6*7)); uname -m\n"];
    [self waitForTerminalText:@"smoke-42" timeout:15];
    [self waitForTerminalText:@"i686" timeout:15];
}

@end
