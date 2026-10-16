#pragma once
// The "Edit Value : <field>" sheet (Cocoa, main thread only): one Metadata row's value on each of the
// window's tracks, edited one track at a time, in the window's lists and chrome. It follows the host's
// own FB2KPropertiesEditMulti sheet: a "Common value" page and a "Per-track" page (Item | Value), the
// "Delimit multiple values with ;" hint for multi-value fields, and OK / Cancel. Nothing is written:
// OK hands the edited wpe::PerTrackEdit back to the window, which stages it.

#import <Cocoa/Cocoa.h>

#include "wpe_model.h"

#include <foobar2000/helpers-mac/foobar2000-mac-helpers.h>

#include <functional>

#define WPEEditValueSheet FB2K_OBJC_CLASS(WPEEditValueSheet)

@interface WPEEditValueSheet : NSWindowController
// `names` and `toolTips` have one entry per track (the Item column and its tool tips). `done` runs
// once, when OK (true) or Cancel (false) ends the sheet; -edit is then still valid.
- (instancetype)initWithEdit:(wpe::PerTrackEdit)edit
                       title:(NSString*)title
                       names:(NSArray<NSString*>*)names
                    toolTips:(NSArray<NSString*>*)toolTips
                        size:(NSSize)size
                        done:(std::function<void(bool ok)>)done;
- (const wpe::PerTrackEdit&)edit;
// Attaches the sheet to `parent`. With a nil parent (a window that is not on screen, as in the tests)
// the sheet is never ordered on screen either; it still takes events sent to its window.
- (void)beginForWindow:(NSWindow*)parent;
// Ends the sheet as OK (an open edit is committed first) or Cancel. Idempotent.
- (void)finish:(BOOL)ok;
@end
