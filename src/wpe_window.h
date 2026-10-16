#pragma once
// The Properties window (Cocoa). Main thread only.

#include "wpe_backend.h"

#include <memory>
#include <string>
#include <vector>

void wpe_show_properties_window(std::shared_ptr<wpe::Backend> backend);

// Closes every window without writing; one line per window that had unapplied changes (see wpe_entry.h).
std::vector<std::string> wpe_close_all_windows();

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Test hooks used by tests/test_ui.mm. `show == false` never orders the window on screen.
id wpe_create_properties_window(std::shared_ptr<wpe::Backend> backend, bool show);
size_t wpe_open_window_count();
NSWindow* wpe_test_window(id controller);
NSTableView* wpe_test_table(id controller);
NSInteger wpe_test_edit_row(id controller);
NSInteger wpe_test_edit_col(id controller);
bool wpe_test_multiline(id controller);
NSString* wpe_test_editor_text(id controller);
NSString* wpe_test_status(id controller);
bool wpe_test_apply_enabled(id controller);
bool wpe_test_writing(id controller);
NSMenu* wpe_test_menu(id controller);
const wpe::Table& wpe_test_model(id controller);

// Tabs: 0 Metadata, 1 Details, 2 ReplayGain, 3 Artwork.
NSInteger wpe_test_tab(id controller);
void wpe_test_select_tab(id controller, NSInteger tab);
NSSegmentedControl* wpe_test_tab_control(id controller);
NSArray<NSString*>* wpe_test_tab_titles(id controller);
// The tab a new window opens on (in-process memory when window state is not persisted).
void wpe_test_set_last_tab(NSInteger tab);
// Tools (the pull-down), OK, Cancel, Apply: in this order whatever their places in the bar.
NSArray<NSButton*>* wpe_test_buttons(id controller);
// The Tools pull-down's menu (its first item is the button's title).
NSMenu* wpe_test_tools_menu(id controller);
// Whether the status line's spinner is showing (tags, pictures or details being read or written).
bool wpe_test_status_busy(id controller);

NSTableView* wpe_test_art_table(id controller);
NSMenu* wpe_test_art_menu(id controller);
const wpe::art::Table& wpe_test_art_model(id controller);
bool wpe_test_art_thumbnail_ready(id controller, size_t type);
// Copy/paste/drop read and write this pasteboard instead of the general one.
void wpe_test_set_pasteboard(id controller, NSPasteboard* pasteboard);
// Runs "Format from other fields" without its sheet.
bool wpe_test_format(id controller, NSString* field, NSString* pattern);

// Details and ReplayGain pages.
NSTableView* wpe_test_details_table(id controller);
const std::vector<wpe::details::Line>& wpe_test_details(id controller);
NSMenu* wpe_test_details_menu(id controller);
NSTableView* wpe_test_rg_table(id controller);
const wpe::rg::Table& wpe_test_rg_model(id controller);
NSInteger wpe_test_rg_edit_row(id controller);
NSString* wpe_test_rg_editor_text(id controller);
NSMenu* wpe_test_rg_menu(id controller);

// The "Edit Value" sheet (several tracks: double-click a name, or "Edit values per track…").
id wpe_test_value_sheet(id controller);  // the open sheet, or nil
NSWindow* wpe_test_sheet_window(id sheet);
NSTableView* wpe_test_sheet_table(id sheet);
NSString* wpe_test_sheet_heading(id sheet);
NSInteger wpe_test_sheet_edit_row(id sheet);
NSString* wpe_test_sheet_editor_text(id sheet);
bool wpe_test_sheet_multiline(id sheet);
// Pages: 0 Common value, 1 Per-track.
NSInteger wpe_test_sheet_page(id sheet);
void wpe_test_sheet_select_page(id sheet, NSInteger page);
NSTextView* wpe_test_sheet_common_editor(id sheet);
NSArray<NSButton*>* wpe_test_sheet_buttons(id sheet);  // OK, Cancel (in this order; Cancel is left of OK)
NSString* wpe_test_sheet_hint(id sheet);               // nil when hidden
NSSegmentedControl* wpe_test_sheet_tab_control(id sheet);
const wpe::PerTrackEdit& wpe_test_sheet_model(id sheet);

// Asking before unapplied changes are lost (the close button, ⌘W, quitting). The tests' windows are never
// shown, so the prompt is not put up as a sheet: it waits here for an answer (NSAlertFirstButtonReturn
// Apply, NSAlertSecondButtonReturn Cancel, NSAlertThirdButtonReturn Don't Apply).
NSAlert* wpe_test_close_prompt(id controller);  // nil when not asking
void wpe_test_answer_close_prompt(id controller, NSModalResponse response);
// The quit review every window goes through when foobar2000 quits (what the quit guard document runs).
void wpe_test_review_for_quit(void (^done)(bool ok));
// Replaces asking AppKit to quit again after Apply in the quit prompt (nil: -[NSApplication terminate:]).
void wpe_test_set_quit_again(void (^quitAgain)(void));
// Registers the quit guard with the app's document controller (shown windows do it themselves).
NSDocument* wpe_test_install_quit_guard();

// Artwork: what Space shows in Quick Look (the files), the window's temporary folder for them, a row's
// drag-out writer, a drag from this list starting on `row` (-1: none), and Import from file…'s types.
NSArray<NSURL*>* wpe_test_quicklook_items(id controller);
NSString* wpe_test_quicklook_folder(id controller);
id<NSPasteboardWriting> wpe_test_art_writer(id controller, NSInteger row);
void wpe_test_art_drag_row(id controller, NSInteger row);
NSArray<UTType*>* wpe_test_import_types(id controller);
bool wpe_test_quit_can_ask(bool visible, bool miniaturized, bool appHidden);  // the quit review's "can it ask"
#endif
