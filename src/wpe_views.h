#pragma once
// Views shared by the Properties window (wpe_window.mm, where they are implemented) and its
// "Edit Value" sheet (wpe_value_sheet.mm). Cocoa only (no SDK).

#import <Cocoa/Cocoa.h>

#include <foobar2000/helpers-mac/foobar2000-mac-helpers.h>

#define WPEWindow FB2K_OBJC_CLASS(WPEWindow)
#define WPEWindowOwner FB2K_OBJC_CLASS(WPEWindowOwner)
#define WPEPageTableView FB2K_OBJC_CLASS(WPEPageTableView)
#define WPEPageTableOwner FB2K_OBJC_CLASS(WPEPageTableOwner)
#define WPEHeaderCorner FB2K_OBJC_CLASS(WPEHeaderCorner)

// A Name | Value list whose clicks, keys and menu are decided by its owner (Details, ReplayGain, the
// Edit Value sheet).
@protocol WPEPageTableOwner <NSObject>
- (BOOL)wpePage:(NSTableView*)table mouseDown:(NSEvent*)event;
- (BOOL)wpePage:(NSTableView*)table keyDown:(NSEvent*)event;
- (NSMenu*)wpePage:(NSTableView*)table menuForEvent:(NSEvent*)event;
- (NSView*)wpePageEditingView:(NSTableView*)table;
- (void)wpePageCopy:(NSTableView*)table;
- (void)wpePageDelete:(NSTableView*)table;
- (BOOL)wpePage:(NSTableView*)table validate:(SEL)action;
@end

@protocol WPEWindowOwner <NSObject>
- (void)wpeCancel;
- (BOOL)wpeWindowShortcut:(NSEvent*)event;
@end

@interface WPEPageTableView : NSTableView
@property(weak) id<WPEPageTableOwner> owner;
@end

// Keypad Enter acts as Return, Escape and Command-period reach the owner's wpeCancel, and the
// standard editing shortcuts work even when the host's Edit menu does not bind them.
@interface WPEWindow : NSWindow
@property(weak) id<WPEWindowOwner> owner;
@property(readonly, strong) NSEvent* currentKeyEvent;
@end

// Above a legacy (always shown) vertical scroller: continues the white list header.
@interface WPEHeaderCorner : NSView
@end
