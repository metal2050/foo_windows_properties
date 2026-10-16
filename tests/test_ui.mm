// Drives the real Properties window (never shown on screen) with synthesized key and mouse events
// against an in-memory backend. No foobar2000, no user defaults, and only private pasteboards.
// With WPE_SNAPSHOT_DIR set, the last test also renders the window's pages to PNG files there.

#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <Quartz/Quartz.h>

#include "test.h"
#include "../src/wpe_window.h"
#import "../src/wpe_chrome.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

namespace {

using wpe::FieldValues;
using wpe::TrackFields;
using wpe::Values;
namespace art = wpe::art;
namespace rg = wpe::rg;

class MemoryBackend : public wpe::Backend {
public:
    explicit MemoryBackend(std::vector<TrackFields> t) : tracks(std::move(t)) {}

    size_t trackCount() const override { return tracks.size(); }
    std::string windowTitle() override { return wpe::window_title(tracks.size(), "single"); }
    wpe::Config config() override { return wpe::Config::defaults(); }
    bool load(bool, std::function<void(std::vector<TrackFields>, std::vector<rg::Info>)> done) override {
        ++loads;
        rg.resize(tracks.size());
        if (deferLoad) {
            auto snapshot = tracks;
            auto gains = rg;
            finishLoad = [done, snapshot, gains] { done(snapshot, gains); };
            return false;
        }
        done(tracks, rg);
        return true;
    }
    void write(const wpe::Plan& plan, const std::vector<size_t>& which, std::function<void(wpe::WriteResult)> done) override {
        ++writes;
        written = which;
        wpe::WriteResult r;
        if (abortNext) {
            abortNext = false;
            r.code = wpe::WriteResult::Aborted;  // the user pressed Abort in the host's progress window
        } else if (failNext) {
            failNext = false;
            r.code = wpe::WriteResult::Errors;
            r.errors.push_back({"file:///music/x.flac", "Access denied"});
        } else {
            rg.resize(tracks.size());
            for (size_t t : which) {
                wpe::MemoryStore s(tracks[t]);
                wpe::apply(plan, t, s);
                tracks[t] = s.fields;
                rg::apply(plan.rg, this->rg[t]);
            }
            lastPlan = plan;
        }
        if (deferWrite) {
            finishWrite = [done, r] { done(r); };
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            done(r);
        });
    }
    void setChangeHandler(std::function<void()> f) override { onChange = std::move(f); }
    void setDisplayChangeHandler(std::function<void()> f) override { onDisplayChange = std::move(f); }
    void loadDetails(std::function<void(std::vector<wpe::details::Entry>)> done) override {
        ++detailsLoads;
        if (deferDetails) {
            auto snapshot = details;
            finishDetails = [done, snapshot] { done(snapshot); };
            return;
        }
        done(details);
    }
    bool persistWindowState() const override { return false; }

    std::vector<std::string> trackPaths() const override {
        if (!paths.empty()) return paths;
        std::vector<std::string> out;
        for (size_t i = 0; i < tracks.size(); ++i) out.push_back("file:///music/track" + std::to_string(i) + ".flac");
        return out;
    }
    std::vector<std::string> trackTitles() override {
        if (!titles.empty()) return titles;
        return wpe::Backend::trackTitles();
    }
    void loadArt(std::function<void(wpe::ArtLoad)> done) override {
        ++artLoads;
        wpe::ArtLoad l;
        l.tracks = art;
        l.tracks.resize(tracks.size());
        if (deferArt) {
            finishArt = [done, l] { done(l); };
            return;
        }
        done(l);
    }
    void writeArt(std::vector<art::FileOps> files, std::function<void(wpe::WriteResult)> done) override {
        ++artWrites;
        artWritten = files;
        wpe::WriteResult r;
        if (failNextArt) {
            failNextArt = false;
            r.code = wpe::WriteResult::Errors;
            r.errors.push_back({"file:///music/x.flac", "Attached picture editing failure: Access denied"});
        } else {
            art.resize(tracks.size());
            for (auto& f : files)
                for (size_t t : f.tracks)
                    for (auto& op : f.ops) art[t].pictures[op.type] = op.picture;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            done(r);
        });
    }
    // %field% (values joined with ", ") and literal text: enough to test the staging.
    bool formatFields(const std::string& pattern, const std::vector<TrackFields>& fields, std::vector<std::string>& out,
                      std::string& error) override {
        out.clear();
        if (std::count(pattern.begin(), pattern.end(), '%') % 2) {
            error = "bad pattern";
            return false;
        }
        for (auto& f : fields) {
            wpe::MemoryStore store(f);
            std::string text;
            for (size_t i = 0; i < pattern.size(); ++i) {
                if (pattern[i] != '%') {
                    text += pattern[i];
                    continue;
                }
                const size_t end = pattern.find('%', i + 1);
                std::string joined;
                for (auto& v : store.get(pattern.substr(i + 1, end - i - 1))) joined += (joined.empty() ? "" : ", ") + v;
                text += joined;
                i = end;
            }
            out.push_back(text);
        }
        return true;
    }
    void cancelPending() override { ++cancels; }

    Values get(size_t track, const char* field) const {
        wpe::MemoryStore s(tracks[track]);
        return s.get(field);
    }

    std::vector<TrackFields> tracks;
    std::vector<rg::Info> rg;
    wpe::Plan lastPlan;
    std::function<void()> onChange;
    std::function<void()> onDisplayChange;
    std::vector<wpe::details::Entry> details;
    int detailsLoads = 0;
    bool deferDetails = false;
    std::function<void()> finishDetails;
    std::vector<size_t> written;
    int writes = 0;
    int loads = 0;
    bool failNext = false;
    bool abortNext = false;
    bool deferWrite = false;
    std::function<void()> finishWrite;
    bool deferLoad = false;
    std::function<void()> finishLoad;

    std::vector<art::TrackArt> art;
    std::vector<std::string> paths;
    std::vector<std::string> titles;
    std::vector<art::FileOps> artWritten;
    int artLoads = 0;
    int artWrites = 0;
    int cancels = 0;
    bool failNextArt = false;
    bool deferArt = false;
    std::function<void()> finishArt;
};

void spin(int n = 6) {
    for (int i = 0; i < n; ++i) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, false);
}

struct UI {
    std::shared_ptr<MemoryBackend> backend;
    id c = nil;
    NSWindow* w = nil;
    NSTableView* table = nil;

    explicit UI(std::vector<TrackFields> tracks, std::vector<art::TrackArt> pictures = {},
                std::vector<std::string> paths = {}) {
        backend = std::make_shared<MemoryBackend>(std::move(tracks));
        backend->art = std::move(pictures);
        backend->paths = std::move(paths);
        c = wpe_create_properties_window(backend, false);
        w = wpe_test_window(c);
        table = wpe_test_table(c);
        spin();
    }
    ~UI() {
        [w close];
        spin();
        wpe_test_set_last_tab(0);
    }

    const wpe::Table& model() const { return wpe_test_model(c); }
    size_t row(const char* field) const { return model().find(field); }
    std::string shown(const char* field) const { return model().display(row(field)).text; }
    NSInteger editRow() const { return wpe_test_edit_row(c); }
    NSInteger editCol() const { return wpe_test_edit_col(c); }
    std::string editor() const {
        NSString* s = wpe_test_editor_text(c);
        return s ? std::string(s.UTF8String) : std::string("<not editing>");
    }
    bool editing() const { return editRow() >= 0; }
    void select(size_t r) {
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:r] byExtendingSelection:NO];
        [w makeFirstResponder:table];
    }

    NSEvent* key(NSString* chars, unsigned short code, NSEventModifierFlags mods = 0, NSString* ign = nil) const {
        return [NSEvent keyEventWithType:NSEventTypeKeyDown
                                location:NSZeroPoint
                           modifierFlags:mods
                               timestamp:NSProcessInfo.processInfo.systemUptime
                            windowNumber:w.windowNumber
                                 context:nil
                              characters:chars
             charactersIgnoringModifiers:ign ?: chars
                               isARepeat:NO
                                 keyCode:code];
    }
    // Same order as -[NSApplication sendEvent:]: key equivalents first, then the window.
    void send(NSEvent* e, bool settle = true) {
        if (![w performKeyEquivalent:e]) [w sendEvent:e];
        if (settle) spin();
    }
    static NSString* fn(unichar c) { return [NSString stringWithCharacters:&c length:1]; }
    void ret(NSEventModifierFlags m = 0) { send(key(@"\r", 36, m)); }
    void tab() { send(key(@"\t", 48)); }
    void backtab() { send(key(@"\x19", 48, NSEventModifierFlagShift)); }
    void esc() { send(key(@"\x1b", 53)); }
    void backspace() { send(key(@"\x7f", 51)); }
    void fwdDelete() { send(key(fn(NSDeleteFunctionKey), 117, NSEventModifierFlagFunction)); }
    void up() { send(key(fn(NSUpArrowFunctionKey), 126, NSEventModifierFlagFunction | NSEventModifierFlagNumericPad)); }
    void down() { send(key(fn(NSDownArrowFunctionKey), 125, NSEventModifierFlagFunction | NSEventModifierFlagNumericPad)); }
    void f2() { send(key(fn(NSF2FunctionKey), 120, NSEventModifierFlagFunction)); }
    void insert() { send(key(fn(NSHelpFunctionKey), 114, NSEventModifierFlagFunction)); }
    void enter(NSEventModifierFlags m = NSEventModifierFlagNumericPad) { send(key(@"\x03", 76, m)); }
    void type(NSString* text, bool settle = true) {
        for (NSUInteger i = 0; i < text.length; ++i) {
            NSString* ch = [text substringWithRange:NSMakeRange(i, 1)];
            send(key(ch, 0), false);
        }
        if (settle) spin();
    }

    NSEvent* mouse(NSEventType type, NSPoint p, NSInteger count) const {
        return [NSEvent mouseEventWithType:type
                                  location:p
                             modifierFlags:0
                                 timestamp:NSProcessInfo.processInfo.systemUptime
                              windowNumber:w.windowNumber
                                   context:nil
                               eventNumber:0
                                clickCount:count
                                  pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
    }
    // Clicks are delivered to the table directly, as NSWindow does for every click of a multi-click
    // that started on the table. A mouse-up is queued first for any tracking loop a text view runs.
    void click(size_t r, NSInteger col, NSInteger count = 1) {
        const NSRect cell = [table frameOfCellAtColumn:col row:(NSInteger)r];
        const NSPoint p = [table convertPoint:NSMakePoint(NSMidX(cell), NSMidY(cell)) toView:nil];
        [NSApp postEvent:mouse(NSEventTypeLeftMouseUp, p, count) atStart:NO];
        [table mouseDown:mouse(NSEventTypeLeftMouseDown, p, count)];
        spin();
        while (NSEvent* e = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp
                                               untilDate:nil
                                                  inMode:NSDefaultRunLoopMode
                                                 dequeue:YES])
            (void)e;
    }
    NSMenu* rightClickBelowRows() {
        const NSRect last = [table rectOfRow:table.numberOfRows - 1];
        const NSPoint p = [table convertPoint:NSMakePoint(NSMidX(last), NSMaxY(last) + 40) toView:nil];
        NSMenu* m = [table menuForEvent:mouse(NSEventTypeRightMouseDown, p, 1)];
        spin();
        return m;
    }
    void action(SEL sel, id arg = nil) {
        [NSApp sendAction:sel to:c from:arg];
        spin();
    }
};

TrackFields tf(std::initializer_list<FieldValues> f) { return TrackFields(f); }

NSData* makePNG(NSInteger w, NSInteger h, NSColor* color) {
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
                                                                    pixelsWide:w
                                                                    pixelsHigh:h
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:0
                                                                  bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [color setFill];
    NSRectFill(NSMakeRect(0, 0, w, h));
    [NSGraphicsContext restoreGraphicsState];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

art::Picture picOf(NSData* d) { return art::make_picture(d.bytes, d.length); }

art::TrackArt artWith(std::initializer_list<std::pair<size_t, art::Picture>> pictures) {
    art::TrackArt t;
    for (auto& [type, p] : pictures) t.pictures[type] = p;
    return t;
}

NSTableCellView* cellAt(NSTableView* t, NSInteger col, NSInteger row) {
    [t layoutSubtreeIfNeeded];
    return [t viewAtColumn:col row:row makeIfNecessary:YES];
}

std::string cellText(NSTableView* t, NSInteger col, NSInteger row) {
    NSTableCellView* v = cellAt(t, col, row);
    return v.textField ? std::string(v.textField.stringValue.UTF8String) : std::string("<no text>");
}

NSButton* cellButton(NSTableView* t, NSInteger col, NSInteger row) {
    for (NSView* v in cellAt(t, col, row).subviews)
        if ([v isKindOfClass:[NSButton class]]) return (NSButton*)v;
    return nil;
}

std::vector<std::string> titles(NSMenu* m) {
    std::vector<std::string> out;
    for (NSMenuItem* i in m.itemArray) out.push_back(i.isSeparatorItem ? "-" : i.title.UTF8String);
    return out;
}

std::string str(NSString* s) { return s ? std::string(s.UTF8String) : std::string("<nil>"); }

// A pasteboard of its own, so tests never touch the user's clipboard.
struct PrivatePasteboard {
    NSPasteboard* pb = [NSPasteboard pasteboardWithUniqueName];
    ~PrivatePasteboard() { [pb releaseGlobally]; }
};

rg::Info gains(rg::Value tg, rg::Value tp = std::nullopt, rg::Value ag = std::nullopt, rg::Value ap = std::nullopt) {
    rg::Info i;
    i.values = {tg, tp, ag, ap};
    return i;
}

// A click on a cell of any list, delivered like UI::click.
void clickCell(UI& ui, NSTableView* t, NSInteger row, NSInteger col, NSInteger count = 1) {
    [t layoutSubtreeIfNeeded];
    const NSRect cell = [t frameOfCellAtColumn:col row:row];
    const NSPoint p = [t convertPoint:NSMakePoint(NSMidX(cell), NSMidY(cell)) toView:nil];
    [NSApp postEvent:ui.mouse(NSEventTypeLeftMouseUp, p, count) atStart:NO];
    [t mouseDown:ui.mouse(NSEventTypeLeftMouseDown, p, count)];
    spin();
    while (NSEvent* e = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES])
        (void)e;
}

}

TEST(opens_with_no_row_selected_and_list_focused) {
    UI ui({tf({{"ARTIST", {"A"}}}), tf({{"ARTIST", {"B"}}})});
    CHECK_EQ(std::string(ui.w.title.UTF8String), std::string("Properties \xE2\x80\x94 2 Tracks"));
    CHECK(ui.w.representedURL == nil);  // no proxy icon for several files
    CHECK_EQ((size_t)ui.table.numberOfRows, ui.model().size() + 1);  // + "add new"
    CHECK_EQ(ui.table.selectedRow, NSInteger(-1));  // as on Windows: no highlighted row at first
    CHECK_EQ(wpe_test_rg_table(ui.c).selectedRow, NSInteger(-1));
    CHECK(ui.w.firstResponder == ui.table);
    CHECK(!wpe_test_apply_enabled(ui.c));
    CHECK(!ui.editing());
    CHECK(!ui.w.visible);
}

TEST(return_edits_tab_commits_and_moves_shift_tab_goes_back) {
    UI ui({tf({{"ARTIST", {"Old"}}, {"TITLE", {"Song"}}})});
    ui.ret();
    CHECK_EQ(ui.editRow(), NSInteger(0));
    CHECK_EQ(ui.editCol(), NSInteger(1));
    CHECK_EQ(ui.editor(), std::string("Old"));
    ui.type(@"New");
    CHECK_EQ(ui.editor(), std::string("New"));
    ui.tab();
    CHECK_EQ(ui.editRow(), NSInteger(1));
    CHECK_EQ(ui.editor(), std::string("Song"));
    CHECK_EQ(ui.shown("ARTIST"), std::string("New"));
    CHECK(wpe_test_apply_enabled(ui.c));
    ui.backtab();
    CHECK_EQ(ui.editRow(), NSInteger(0));
    CHECK_EQ(ui.editor(), std::string("New"));
    ui.esc();
    CHECK(!ui.editing());
    CHECK(ui.w.firstResponder == ui.table);
    CHECK_EQ(ui.table.selectedRow, NSInteger(0));
    CHECK_EQ(ui.shown("ARTIST"), std::string("New"));
}

TEST(return_wraps_shift_return_reverses_arrows_do_not_wrap) {
    UI ui({tf({{"TITLE", {"t"}}, {"YEAR", {"y"}}, {"ZONE", {"z"}}})});
    const size_t last = ui.model().size() - 1;
    CHECK(!ui.model().isMultiline(last) && !ui.model().isMultiline(last - 1));
    ui.select(last);
    ui.f2();
    CHECK_EQ(ui.editRow(), NSInteger(last));
    ui.ret();
    CHECK_EQ(ui.editRow(), NSInteger(0));
    ui.ret(NSEventModifierFlagShift);
    CHECK_EQ(ui.editRow(), NSInteger(last));
    ui.up();
    CHECK_EQ(ui.editRow(), NSInteger(last - 1));
    ui.down();
    CHECK_EQ(ui.editRow(), NSInteger(last));
    ui.down();
    CHECK_EQ(ui.editRow(), NSInteger(last));
    CHECK(ui.editing());
    ui.esc();
    CHECK(!ui.model().dirty());
}

TEST(typing_on_the_list_replaces_the_value) {
    UI ui({tf({{"TITLE", {"Song"}}})});
    ui.select(ui.row("TITLE"));
    ui.type(@"xy");
    CHECK_EQ(ui.editRow(), NSInteger(ui.row("TITLE")));
    CHECK_EQ(ui.editor(), std::string("xy"));
    ui.ret();
    CHECK_EQ(ui.shown("TITLE"), std::string("xy"));
}

TEST(keys_typed_before_the_next_editor_opens_are_not_lost) {
    UI ui({tf({{"ARTIST", {"a"}}, {"TITLE", {"t"}}})});
    ui.ret();
    ui.send(ui.key(@"\t", 48), false);
    ui.send(ui.key(@"q", 12), false);
    spin();
    CHECK_EQ(ui.editRow(), NSInteger(1));
    CHECK_EQ(ui.editor(), std::string("q"));
}

TEST(escape_cancels_the_edit_then_closes_the_window) {
    UI ui({tf({{"TITLE", {"Song"}}})});
    const size_t before = wpe_open_window_count();
    ui.ret();
    ui.type(@"zzz");
    ui.esc();
    CHECK(!ui.editing());
    CHECK(!ui.model().dirty());
    CHECK_EQ(wpe_open_window_count(), before);
    ui.esc();
    CHECK_EQ(wpe_open_window_count(), before - 1);
    CHECK_EQ(ui.backend->writes, 0);
}

TEST(delete_removes_fields_and_clears_standard_rows) {
    UI ui({tf({{"ARTIST", {"A"}}, {"MOOD", {"m"}}})});
    const size_t n = ui.model().size();
    ui.select(ui.row("ARTIST"));
    ui.backspace();
    CHECK_EQ(ui.model().size(), n);
    CHECK_EQ(ui.shown("ARTIST"), std::string(""));
    ui.select(ui.row("MOOD"));
    ui.fwdDelete();
    CHECK_EQ(ui.model().size(), n - 1);
    CHECK_EQ(ui.row("MOOD"), wpe::npos);
    CHECK_EQ((size_t)ui.table.numberOfRows, n - 1 + 1);
}

TEST(insert_adds_a_field_name_first_then_value) {
    UI ui({tf({{"TITLE", {"t"}}}), tf({{"TITLE", {"u"}}})});
    const size_t n = ui.model().size();
    ui.insert();
    CHECK_EQ(ui.editRow(), NSInteger(n));
    CHECK_EQ(ui.editCol(), NSInteger(0));
    ui.type(@"rating");
    ui.ret();
    CHECK_EQ(ui.editRow(), NSInteger(n));
    CHECK_EQ(ui.editCol(), NSInteger(1));
    ui.type(@"5");
    ui.ret();
    CHECK_EQ(ui.shown("RATING"), std::string("5"));
    CHECK_EQ(ui.model().row(ui.row("RATING")).label, std::string("<RATING>"));
    CHECK_EQ(ui.editRow(), NSInteger(0));
    ui.esc();
}

TEST(insert_with_existing_name_jumps_to_that_field) {
    UI ui({tf({{"MOOD", {"calm"}}})});
    const size_t n = ui.model().size();
    ui.action(@selector(addField:));
    ui.type(@"mood");
    ui.tab();
    CHECK_EQ(ui.model().size(), n);
    CHECK_EQ(ui.editRow(), NSInteger(ui.row("MOOD")));
    CHECK_EQ(ui.editCol(), NSInteger(1));
    CHECK_EQ(ui.editor(), std::string("calm"));
    CHECK([wpe_test_status(ui.c) containsString:@"already exists"]);
}

TEST(escape_or_empty_name_discards_the_new_row) {
    UI ui({tf({{"TITLE", {"t"}}})});
    const size_t n = ui.model().size();
    ui.insert();
    ui.esc();
    CHECK_EQ(ui.model().size(), n);
    CHECK_EQ((size_t)ui.table.numberOfRows, n + 1);
    ui.insert();
    ui.ret();
    CHECK_EQ(ui.model().size(), n);
    CHECK(!ui.editing());
    CHECK(!ui.model().dirty());
}

TEST(double_click_on_a_name_renames_then_edits_the_value) {
    UI ui({tf({{"MOOD", {"calm"}}})});
    const size_t mood = ui.row("MOOD");
    ui.click(mood, 0, 2);
    CHECK_EQ(ui.editRow(), NSInteger(mood));
    CHECK_EQ(ui.editCol(), NSInteger(0));
    CHECK_EQ(ui.editor(), std::string("MOOD"));
    ui.type(@"feel");
    ui.ret();
    CHECK_EQ(ui.model().row(mood).label, std::string("<FEEL>"));
    CHECK_EQ(ui.editRow(), NSInteger(mood));
    CHECK_EQ(ui.editCol(), NSInteger(1));
    ui.esc();
    CHECK(ui.model().dirty());
}

TEST(double_click_on_a_standard_label_edits_its_value) {
    UI ui({tf({{"ARTIST", {"A"}}})});
    ui.click(0, 0, 2);
    CHECK_EQ(ui.editRow(), NSInteger(0));
    CHECK_EQ(ui.editCol(), NSInteger(1));
    ui.esc();
}

TEST(single_click_on_a_value_edits_at_once_and_clicking_away_commits) {
    UI ui({tf({{"ARTIST", {"A"}}, {"TITLE", {"T"}}, {"ALBUM", {"L"}}})});
    ui.click(1, 1);
    CHECK_EQ(ui.editRow(), NSInteger(1));
    CHECK_EQ(ui.editor(), std::string("T"));
    ui.type(@"abc");
    ui.click(2, 1);
    CHECK_EQ(ui.shown("TITLE"), std::string("abc"));
    CHECK_EQ(ui.editRow(), NSInteger(2));
    CHECK_EQ(ui.editor(), std::string("L"));
    ui.esc();
}

TEST(unchanged_multiple_values_stay_per_track) {
    UI ui({tf({{"ALBUM", {"A"}}}), tf({{"ALBUM", {"B"}}})});
    const size_t album = ui.row("ALBUM");
    CHECK(ui.model().display(album).mixed);
    ui.click(album, 1);
    CHECK_EQ(ui.editor(), std::string("A; B"));
    ui.ret();
    CHECK(!ui.model().dirty());
    ui.ret(NSEventModifierFlagCommand);
    CHECK_EQ(ui.backend->writes, 0);
    CHECK_EQ(ui.backend->get(0, "ALBUM"), Values{"A"});
}

TEST(command_return_commits_writes_and_closes) {
    UI ui({tf({{"ALBUM", {"A"}}, {"DATE", {"1999"}}}), tf({{"ALBUM", {"B"}}})});
    const size_t before = wpe_open_window_count();
    ui.click(ui.row("DATE"), 1);
    ui.type(@"2001");
    ui.ret(NSEventModifierFlagCommand);
    CHECK_EQ(ui.backend->writes, 1);
    CHECK_EQ(ui.backend->written, (std::vector<size_t>{0, 1}));
    CHECK_EQ(ui.backend->get(0, "DATE"), Values{"2001"});
    CHECK_EQ(ui.backend->get(1, "DATE"), Values{"2001"});
    CHECK_EQ(ui.backend->get(0, "ALBUM"), Values{"A"});
    CHECK_EQ(ui.backend->get(1, "ALBUM"), Values{"B"});
    CHECK_EQ(wpe_open_window_count(), before - 1);
}

TEST(apply_writes_reloads_and_keeps_the_window) {
    UI ui({tf({{"TITLE", {"t"}}, {"MOOD", {"m"}}})});
    ui.select(ui.row("MOOD"));
    ui.ret();
    ui.type(@"happy");
    ui.ret();
    ui.esc();
    ui.select(ui.row("MOOD"));
    CHECK(wpe_test_apply_enabled(ui.c));
    const int loads = ui.backend->loads;
    ui.action(@selector(applyPressed:));
    CHECK_EQ(ui.backend->writes, 1);
    CHECK_EQ(ui.backend->loads, loads + 1);
    CHECK(!wpe_test_writing(ui.c));
    CHECK(!ui.model().dirty());
    CHECK(!wpe_test_apply_enabled(ui.c));
    CHECK_EQ(ui.shown("MOOD"), std::string("happy"));
    CHECK_EQ(std::string(wpe_test_status(ui.c).UTF8String), std::string("Updated 1 file."));
    CHECK_EQ(ui.table.selectedRow, NSInteger(ui.row("MOOD")));
}

TEST(write_errors_are_reported_in_the_window_and_edits_kept) {
    UI ui({tf({{"TITLE", {"t"}}})});
    ui.backend->failNext = true;
    ui.select(ui.row("TITLE"));
    ui.type(@"x");
    ui.ret();
    ui.action(@selector(okPressed:));
    CHECK_EQ(ui.backend->writes, 1);
    CHECK([wpe_test_status(ui.c) containsString:@"could not be updated"]);
    CHECK([wpe_test_status(ui.c) containsString:@"Access denied"]);
    CHECK(ui.model().dirty());
    CHECK(wpe_test_apply_enabled(ui.c));
    CHECK(wpe_open_window_count() > 0);
}

TEST(multiline_field_uses_a_text_view_and_option_return_adds_a_line) {
    UI ui({tf({{"COMMENT", {"old"}}, {"MOOD", {"m"}}})});
    ui.select(ui.row("COMMENT"));
    ui.ret();
    CHECK(wpe_test_multiline(ui.c));
    ui.type(@"line1");
    ui.ret(NSEventModifierFlagOption);
    ui.type(@"line2");
    CHECK_EQ(ui.editor(), std::string("line1\nline2"));
    ui.ret();
    CHECK(!wpe_test_multiline(ui.c));
    CHECK_EQ(ui.model().editText(ui.row("COMMENT")), std::string("line1\nline2"));
    CHECK_EQ(ui.editRow(), NSInteger(ui.row("COMMENT") + 1));
    ui.esc();
}

TEST(option_return_turns_a_single_line_editor_into_a_multiline_one) {
    UI ui({tf({{"TITLE", {"t"}}})});
    ui.select(ui.row("TITLE"));
    ui.type(@"a");
    ui.ret(NSEventModifierFlagOption);
    CHECK(wpe_test_multiline(ui.c));
    CHECK_EQ(ui.editor(), std::string("a\n"));
    ui.esc();
    CHECK(!ui.editing());
    CHECK(!ui.model().dirty());
}

TEST(context_menu_has_the_windows_items) {
    UI ui({tf({{"TITLE", {"t"}}})});
    NSMutableArray* titles = [NSMutableArray array];
    for (NSMenuItem* i in wpe_test_menu(ui.c).itemArray) [titles addObject:i.isSeparatorItem ? @"-" : i.title];
    CHECK([titles isEqualToArray:(@[ @"Edit", @"Add New Field", @"Remove", @"-", @"Copy", @"Paste", @"-", @"Capitalize",
                                    @"Auto Track Number" ])]);
}

TEST(paste_auto_track_number_and_capitalize) {
    UI ui({tf({{"TITLE", {"hello world"}}}), tf({{"TITLE", {"good bye"}}})});
    ui.action(@selector(autoTrackNumber:));
    CHECK_EQ(ui.shown("TRACKNUMBER"), std::string(wpe::kMultipleValues) + " 1; 2");
    CHECK_EQ(ui.shown("TOTALTRACKS"), std::string("2"));
    ui.select(ui.row("TITLE"));
    ui.action(@selector(capitalizeSelected:));
    CHECK_EQ(ui.shown("TITLE"), std::string(wpe::kMultipleValues) + " Hello World; Good Bye");
    ui.action(@selector(pasteText:), @"MOOD=calm\nGENRE=Rock; Pop");
    CHECK_EQ(ui.shown("MOOD"), std::string("calm"));
    CHECK_EQ(ui.model().row(ui.row("GENRE")).all, (Values{"Rock", "Pop"}));
    ui.action(@selector(applyPressed:));
    CHECK_EQ(ui.backend->get(1, "TRACKNUMBER"), Values{"2"});
    CHECK_EQ(ui.backend->get(1, "TITLE"), Values{"Good Bye"});
    CHECK_EQ(ui.backend->get(0, "MOOD"), Values{"calm"});
}

TEST(outside_tag_changes_reload_only_a_clean_window) {
    UI ui({tf({{"TITLE", {"t"}}})});
    ui.backend->tracks[0] = tf({{"TITLE", {"changed"}}});
    ui.backend->onChange();
    spin();
    CHECK_EQ(ui.shown("TITLE"), std::string("changed"));
    ui.select(ui.row("TITLE"));
    ui.type(@"mine");
    ui.ret();
    ui.esc();
    ui.backend->tracks[0] = tf({{"TITLE", {"again"}}});
    ui.backend->onChange();
    spin();
    CHECK_EQ(ui.shown("TITLE"), std::string("mine"));
}

TEST(tab_on_the_list_does_not_start_editing) {
    UI ui({tf({{"TITLE", {"t"}}})});
    ui.select(1);
    ui.tab();
    CHECK(!ui.editing());
    CHECK(!ui.model().dirty());
}

TEST(right_click_selects_the_row_under_the_mouse_and_commits_edits) {
    UI ui({tf({{"ARTIST", {"A"}}, {"TITLE", {"T"}}, {"MOOD", {"m"}}})});
    ui.click(0, 1);
    ui.type(@"B");
    const NSRect cell = [ui.table frameOfCellAtColumn:0 row:(NSInteger)ui.row("MOOD")];
    const NSPoint p = [ui.table convertPoint:NSMakePoint(NSMidX(cell), NSMidY(cell)) toView:nil];
    NSEvent* e = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown
                                    location:p
                               modifierFlags:0
                                   timestamp:NSProcessInfo.processInfo.systemUptime
                                windowNumber:ui.w.windowNumber
                                     context:nil
                                 eventNumber:0
                                  clickCount:1
                                    pressure:1];
    NSMenu* menu = [ui.table menuForEvent:e];
    spin();
    CHECK(menu == wpe_test_menu(ui.c));
    CHECK(!ui.editing());
    CHECK_EQ(ui.shown("ARTIST"), std::string("B"));
    CHECK_EQ(ui.table.selectedRow, NSInteger(ui.row("MOOD")));
    ui.select(1);
    [ui.table selectRowIndexes:[NSIndexSet indexSetWithIndex:ui.row("MOOD")] byExtendingSelection:YES];
    [ui.table menuForEvent:e];
    CHECK_EQ(ui.table.selectedRowIndexes.count, NSUInteger(2));
    ui.action(@selector(removeSelected:));
    CHECK_EQ(ui.row("MOOD"), wpe::npos);
    CHECK_EQ(ui.shown("TITLE"), std::string(""));
}

TEST(home_end_and_page_keys_move_the_selection) {
    UI ui({tf({{"TITLE", {"t"}}, {"MOOD", {"m"}}})});
    const NSInteger last = (NSInteger)ui.model().size() - 1;
    ui.select(3);
    ui.send(ui.key(UI::fn(NSEndFunctionKey), 119, NSEventModifierFlagFunction));
    CHECK_EQ(ui.table.selectedRow, last);
    ui.send(ui.key(UI::fn(NSHomeFunctionKey), 115, NSEventModifierFlagFunction));
    CHECK_EQ(ui.table.selectedRow, NSInteger(0));
    ui.send(ui.key(UI::fn(NSPageDownFunctionKey), 121, NSEventModifierFlagFunction));
    CHECK(ui.table.selectedRow > 0);
    ui.send(ui.key(UI::fn(NSPageUpFunctionKey), 116, NSEventModifierFlagFunction));
    CHECK_EQ(ui.table.selectedRow, NSInteger(0));
    ui.send(ui.key(UI::fn(NSEndFunctionKey), 119, NSEventModifierFlagFunction | NSEventModifierFlagShift));
    CHECK_EQ((NSInteger)ui.table.selectedRowIndexes.count, last + 1);
    ui.down();
    CHECK(!ui.editing());
}

TEST(remove_while_naming_a_new_field_never_touches_another_field) {
    UI ui({tf({{"TITLE", {"t"}}, {"MOOD", {"m"}}, {"ZZZ", {"z"}}})});
    const size_t n = ui.model().size();
    ui.insert();
    ui.action(@selector(removeSelected:));
    CHECK_EQ(ui.model().size(), n);
    CHECK(ui.row("ZZZ") != wpe::npos);
    CHECK(!ui.model().dirty());
    ui.action(@selector(okPressed:));
    CHECK_EQ(ui.backend->writes, 0);
    CHECK_EQ(ui.backend->get(0, "ZZZ"), Values{"z"});
}

TEST(remove_or_paste_while_naming_keeps_standard_and_existing_fields) {
    UI ui({tf({{"TITLE", {"t"}}, {"COMMENT", {"c"}}, {"MOOD", {"calm"}}})});
    ui.insert();
    ui.action(@selector(removeSelected:));
    CHECK_EQ(ui.shown("COMMENT"), std::string("c"));
    CHECK_EQ(ui.shown("MOOD"), std::string("calm"));
    CHECK(!ui.model().dirty());

    ui.insert();
    ui.type(@"mood");
    ui.action(@selector(removeSelected:));
    CHECK(ui.row("MOOD") != wpe::npos);
    CHECK_EQ(ui.shown("MOOD"), std::string("calm"));
    CHECK(!ui.model().dirty());

    ui.insert();
    ui.action(@selector(pasteText:), @"hello");
    CHECK_EQ(ui.shown("MOOD"), std::string("calm"));
    CHECK(!ui.model().dirty());

    ui.insert();
    ui.type(@"rating");
    ui.action(@selector(pasteText:), @"5");
    CHECK_EQ(ui.shown("RATING"), std::string("5"));
    CHECK_EQ(ui.shown("MOOD"), std::string("calm"));
}

TEST(context_menu_while_naming_leaves_nothing_selected) {
    UI ui({tf({{"TITLE", {"t"}}, {"MOOD", {"calm"}}})});
    ui.insert();
    CHECK(ui.rightClickBelowRows() == wpe_test_menu(ui.c));
    CHECK(!ui.editing());
    CHECK_EQ(ui.table.selectedRowIndexes.count, NSUInteger(0));
    ui.action(@selector(removeSelected:));
    ui.action(@selector(pasteText:), @"hello");
    CHECK(!ui.model().dirty());
    CHECK_EQ(ui.shown("MOOD"), std::string("calm"));
}

TEST(outside_changes_during_an_edit_reload_when_it_ends) {
    UI ui({tf({{"TITLE", {"t"}}, {"MOOD", {"calm"}}})});
    ui.click(ui.row("MOOD"), 1);
    CHECK(ui.editing());
    ui.backend->tracks[0] = tf({{"TITLE", {"t"}}, {"MOOD", {"angry"}}});
    ui.backend->onChange();
    spin();
    CHECK(ui.editing());
    ui.esc();
    spin();
    CHECK_EQ(ui.shown("MOOD"), std::string("angry"));
    ui.select(ui.row("MOOD"));
    ui.action(@selector(capitalizeSelected:));
    ui.action(@selector(okPressed:));
    CHECK_EQ(ui.backend->get(0, "MOOD"), Values{"Angry"});
}

TEST(outside_changes_while_tabbing_do_not_cancel_the_next_editor) {
    UI ui({tf({{"ARTIST", {"a"}}, {"TITLE", {"t"}}})});
    ui.ret();
    ui.backend->tracks[0] = tf({{"ARTIST", {"a"}}, {"TITLE", {"new"}}});
    ui.backend->onChange();
    ui.tab();
    CHECK_EQ(ui.editRow(), NSInteger(1));
    ui.esc();
    spin();
    CHECK_EQ(ui.shown("TITLE"), std::string("new"));
}

TEST(outside_changes_while_loading_reload_afterwards) {
    UI ui({tf({{"MOOD", {"calm"}}})});
    ui.backend->deferLoad = true;
    ui.backend->tracks[0] = tf({{"MOOD", {"tense"}}});
    ui.backend->onChange();
    CHECK(ui.backend->finishLoad != nullptr);
    ui.backend->tracks[0] = tf({{"MOOD", {"angry"}}});
    ui.backend->onChange();
    ui.backend->deferLoad = false;
    auto finish = ui.backend->finishLoad;
    finish();
    spin();
    CHECK_EQ(ui.shown("MOOD"), std::string("angry"));
}

TEST(keypad_enter_and_fn_return_edit_like_return) {
    UI ui({tf({{"ARTIST", {"a"}}, {"TITLE", {"Song"}}, {"ALBUM", {"l"}}})});
    const size_t before = wpe_open_window_count();
    const NSInteger title = (NSInteger)ui.row("TITLE");
    ui.select((size_t)title);
    ui.enter();
    CHECK_EQ(wpe_open_window_count(), before);
    CHECK_EQ(ui.editRow(), title);
    ui.type(@"zz");
    ui.enter();
    CHECK_EQ(ui.backend->writes, 0);
    CHECK_EQ(wpe_open_window_count(), before);
    CHECK_EQ(ui.editRow(), title + 1);
    CHECK_EQ(ui.shown("TITLE"), std::string("zz"));
    ui.enter(NSEventModifierFlagNumericPad | NSEventModifierFlagShift);
    CHECK_EQ(ui.editRow(), title);
    ui.enter(NSEventModifierFlagFunction);
    CHECK_EQ(ui.editRow(), title + 1);
    ui.esc();
    CHECK(!ui.editing());
    ui.enter(NSEventModifierFlagFunction);
    CHECK(ui.editing());
    ui.esc();
    CHECK_EQ(ui.backend->writes, 0);
    CHECK_EQ(wpe_open_window_count(), before);
}

TEST(double_click_on_a_value_keeps_the_editor_open) {
    UI ui({tf({{"TITLE", {"Some Song"}}, {"ALBUM", {"l"}}})});
    const NSInteger title = (NSInteger)ui.row("TITLE");
    ui.click((size_t)title, 1);
    CHECK_EQ(ui.editRow(), title);
    ui.click((size_t)title, 1, 2);
    CHECK_EQ(ui.editRow(), title);
    CHECK_EQ(ui.editCol(), NSInteger(1));
    CHECK_EQ(ui.editor(), std::string("Some Song"));
    ui.click((size_t)title, 1, 3);
    CHECK_EQ(ui.editRow(), title);
    ui.esc();
    const NSInteger album = (NSInteger)ui.row("ALBUM");
    ui.click((size_t)album, 1, 2);
    CHECK_EQ(ui.editRow(), album);
    ui.esc();
    CHECK(!ui.model().dirty());
}

TEST(one_local_file_gets_a_proxy_icon_and_its_title) {
    {
        UI ui({tf({{"TITLE", {"t"}}})}, {}, {"file:///music/My Song.flac"});
        CHECK_EQ(str(ui.w.title), std::string("Properties \xE2\x80\x94 single"));
        CHECK(ui.w.representedURL.isFileURL);
        CHECK_EQ(str(ui.w.representedURL.path), std::string("/music/My Song.flac"));
    }
    {
        // Not a local file (an archive member, a stream): no proxy icon.
        UI ui({tf({{"TITLE", {"t"}}})}, {}, {"unpack://zip|10|file:///music/a.zip|b.flac"});
        CHECK(ui.w.representedURL == nil);
        CHECK_EQ(str(ui.w.title), std::string("Properties \xE2\x80\x94 single"));
    }
}

TEST(page_control_has_the_pages_and_shortcuts_switch_them) {
    UI ui({tf({{"TITLE", {"t"}}})});
    NSSegmentedControl* pages = wpe_test_tab_control(ui.c);
    CHECK([pages isKindOfClass:[NSSegmentedControl class]]);
    CHECK([wpe_test_tab_titles(ui.c) isEqualToArray:(@[ @"Metadata", @"Details", @"ReplayGain", @"Artwork" ])]);
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(0));
    CHECK_EQ(pages.selectedSegment, NSInteger(0));
    NSTableView* art = wpe_test_art_table(ui.c);
    CHECK(!ui.table.enclosingScrollView.hidden);
    CHECK(art.enclosingScrollView.hidden);
    CHECK_EQ(ui.backend->artLoads, 0);  // pictures are read only when the Artwork tab is opened
    ui.send(ui.key(@"2", 19, NSEventModifierFlagCommand));
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(1));
    CHECK_EQ(pages.selectedSegment, NSInteger(1));
    CHECK(ui.table.enclosingScrollView.hidden);
    ui.send(ui.key(@"\t", 48, NSEventModifierFlagControl));
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(2));
    ui.send(ui.key(@"\x19", 48, NSEventModifierFlagControl | NSEventModifierFlagShift));
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(1));
    ui.send(ui.key(@"4", 21, NSEventModifierFlagCommand));
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(3));
    CHECK_EQ(pages.selectedSegment, NSInteger(3));
    CHECK(!art.enclosingScrollView.hidden);
    CHECK(ui.w.firstResponder == art);
    CHECK_EQ(ui.backend->artLoads, 1);
    ui.send(ui.key(@"\t", 48, NSEventModifierFlagControl));
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(0));  // wraps
    CHECK(ui.w.firstResponder == ui.table);
    ui.send(ui.key(@"\x19", 48, NSEventModifierFlagControl | NSEventModifierFlagShift));
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(3));
    ui.send(ui.key(@"1", 18, NSEventModifierFlagCommand));
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(0));
    CHECK_EQ(pages.selectedSegment, NSInteger(0));
    CHECK_EQ(ui.backend->artLoads, 1);  // loaded once
    CHECK(!ui.model().dirty());
}

namespace {

// The accessibility element of segment `index` of a segmented control (AppKit's own: one per segment).
id segmentElement(NSSegmentedControl* c, NSInteger index) {
    NSArray* children = c.accessibilityChildren;
    if (children.count == 1 && [children[0] accessibilityChildren].count == (NSUInteger)c.segmentCount)
        children = [children[0] accessibilityChildren];
    return index < (NSInteger)children.count ? children[(NSUInteger)index] : nil;
}

// Picks segment `index` as a click does: the control selects it and sends its action. (A synthesized
// click cannot drive NSSegmentedControl's tracking in a window that is not on screen: it reads the real
// mouse button state.)
void clickSegment(NSWindow* w, NSSegmentedControl* c, NSInteger index) {
    (void)w;
    c.selectedSegment = index;
    [c sendAction:c.action to:c.target];
    spin();
}

// Presses segment `index` through accessibility (VoiceOver's press), AppKit's own segment element.
bool pressSegment(NSSegmentedControl* c, NSInteger index) {
    id e = segmentElement(c, index);
    if (!e) return false;
    [e accessibilityPerformPress];
    spin();
    return true;
}

}

TEST(clicking_or_pressing_a_segment_switches_pages) {
    UI ui({tf({{"TITLE", {"t"}}})});
    NSSegmentedControl* pages = wpe_test_tab_control(ui.c);
    clickSegment(ui.w, pages, 3);
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(3));
    CHECK_EQ(pages.selectedSegment, NSInteger(3));
    CHECK(ui.w.firstResponder == wpe_test_art_table(ui.c));
    clickSegment(ui.w, pages, 1);
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(1));
    // VoiceOver: AppKit's own segment elements, one per page, named and pressable.
    id replayGain = segmentElement(pages, 2);
    CHECK(replayGain != nil);
    if (replayGain) {
        CHECK_EQ(str([replayGain accessibilityLabel].length ? [replayGain accessibilityLabel] : [replayGain accessibilityTitle]),
                 std::string("ReplayGain"));
        CHECK(pressSegment(pages, 2));
        CHECK_EQ(wpe_test_tab(ui.c), NSInteger(2));
        CHECK_EQ(pages.selectedSegment, NSInteger(2));
    }
    // The control takes keyboard focus (with Full Keyboard Access), unlike the old drawn tab strip.
    CHECK(pages.acceptsFirstResponder);
    // A page picked from the keyboard on the control (Tab to it, arrow, Space) keeps the focus on it, as
    // AppKit's segmented controls do; a click (above) or a shortcut moves it to the page's list.
    CHECK([ui.w makeFirstResponder:pages]);
    clickSegment(ui.w, pages, 0);
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(0));
    CHECK(ui.w.firstResponder == pages);
    clickSegment(ui.w, pages, 3);
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(3));
    CHECK(ui.w.firstResponder == pages);
    wpe_test_select_tab(ui.c, 2);
    CHECK(ui.w.firstResponder == wpe_test_rg_table(ui.c));
    // A ReplayGain value that does not parse keeps its page, and the control shows it again.
    ui.backend->rg = {gains(-6.54f)};
    ui.backend->onChange();
    spin();
    clickCell(ui, wpe_test_rg_table(ui.c), 0, 1);
    ui.type(@"abc");
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(0));
    clickSegment(ui.w, pages, 0);
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(2));
    CHECK_EQ(pages.selectedSegment, NSInteger(2));
    pressSegment(pages, 3);
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(2));
    CHECK_EQ(pages.selectedSegment, NSInteger(2));
    ui.esc();
}

TEST(editing_is_committed_when_switching_tabs_and_the_last_tab_is_remembered) {
    {
        UI ui({tf({{"TITLE", {"t"}}})});
        ui.click(ui.row("TITLE"), 1);
        ui.type(@"new");
        CHECK(ui.editing());
        ui.send(ui.key(@"4", 21, NSEventModifierFlagCommand));
        CHECK(!ui.editing());
        CHECK_EQ(ui.shown("TITLE"), std::string("new"));
        CHECK_EQ(wpe_test_tab(ui.c), NSInteger(3));
        [ui.w close];
        spin();
        UI again({tf({{"TITLE", {"t"}}})});
        CHECK_EQ(wpe_test_tab(again.c), NSInteger(3));
        CHECK(again.w.firstResponder == wpe_test_art_table(again.c));
        CHECK_EQ(again.backend->artLoads, 1);
    }
    UI fresh({tf({{"TITLE", {"t"}}})});
    CHECK_EQ(wpe_test_tab(fresh.c), NSInteger(0));
}

TEST(button_bar_is_in_mac_order_with_a_real_default_button) {
    UI ui({tf({{"TITLE", {"t"}}})});
    NSArray<NSButton*>* buttons = wpe_test_buttons(ui.c);
    CHECK_EQ(buttons.count, NSUInteger(4));
    std::vector<std::string> names;
    for (NSButton* b in buttons) names.push_back(b.title.UTF8String);
    CHECK_EQ(names, (std::vector<std::string>{"Tools", "OK", "Cancel", "Apply"}));
    CHECK(buttons[0].enabled && buttons[1].enabled && buttons[2].enabled);
    CHECK(!buttons[3].enabled);
    // Tools is a pull-down (it opens a menu), not a push button.
    CHECK([buttons[0] isKindOfClass:[NSPopUpButton class]] && ((NSPopUpButton*)buttons[0]).pullsDown);
    // Mac order: Tools at the leading edge; Apply, Cancel, OK at the trailing edge, OK rightmost.
    [ui.w.contentView layoutSubtreeIfNeeded];
    auto box = [](NSButton* b) { return [b alignmentRectForFrame:b.frame]; };
    CHECK(NSMaxX(box(buttons[0])) < NSMinX(box(buttons[3])));
    CHECK(NSMaxX(box(buttons[3])) < NSMinX(box(buttons[2])));
    CHECK(NSMaxX(box(buttons[2])) < NSMinX(box(buttons[1])));
    // OK is the window's default button (accent-filled while the window is key), on Command-Return.
    CHECK(ui.w.defaultButtonCell == buttons[1].cell);
    CHECK_EQ(str(buttons[1].keyEquivalent), std::string("\r"));
    CHECK_EQ(buttons[1].keyEquivalentModifierMask & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption |
                                                      NSEventModifierFlagControl),
             NSEventModifierFlagCommand);
    // The status line has nothing to say while nothing happens (no "Ready.").
    CHECK_EQ(str(wpe_test_status(ui.c)), std::string(""));
    CHECK(!wpe_test_status_busy(ui.c));
    ui.select(ui.row("TITLE"));
    ui.type(@"x");
    ui.ret();
    CHECK(buttons[3].enabled);
    CHECK_EQ(str(wpe_test_status(ui.c)), std::string(""));
}

// The default button never takes plain Return: on the lists it edits, in the editors it moves on, and on
// the read-only pages it does nothing. Only Command-Return is OK.
TEST(return_never_reaches_the_default_button) {
    UI ui({tf({{"TITLE", {"t"}}})}, {}, {});
    ui.backend->details = {{"General", 0, "Items selected", "1"}};
    ui.select(ui.row("TITLE"));
    ui.type(@"x");
    ui.ret();  // commits, opens the next row's editor
    ui.esc();
    CHECK(ui.model().dirty());
    const size_t before = wpe_open_window_count();
    for (NSInteger tab : {1, 3, 2, 0}) {
        wpe_test_select_tab(ui.c, tab);
        spin();
        ui.ret();
        if (wpe_test_rg_edit_row(ui.c) >= 0 || ui.editing()) ui.esc();
        ui.send(ui.key(@"\r", 36, NSEventModifierFlagOption));
        if (wpe_test_rg_edit_row(ui.c) >= 0 || ui.editing()) ui.esc();
        CHECK_EQ(ui.backend->writes, 0);
        CHECK_EQ(wpe_open_window_count(), before);
    }
    // Return with the page control or a button focused (Full Keyboard Access) is not OK either.
    for (NSView* v in @[ (NSView*)wpe_test_tab_control(ui.c), wpe_test_buttons(ui.c)[3] ]) {
        [ui.w makeFirstResponder:v];
        ui.ret();
        CHECK_EQ(ui.backend->writes, 0);
        CHECK_EQ(wpe_open_window_count(), before);
    }
    [ui.w makeFirstResponder:ui.table];
    ui.ret(NSEventModifierFlagCommand);
    CHECK_EQ(ui.backend->writes, 1);
    CHECK_EQ(wpe_open_window_count(), before - 1);
}

TEST(status_line_shows_news_errors_and_a_spinner_while_busy) {
    using namespace wpe::ui;
    UI ui({tf({{"TITLE", {"t"}}})});
    NSArray<NSButton*>* buttons = wpe_test_buttons(ui.c);
    NSView* bar = buttons[1].superview;
    NSTextField* status = nil;
    NSProgressIndicator* spinner = nil;
    for (NSView* v in bar.subviews) {
        if ([v isKindOfClass:[NSTextField class]]) status = (NSTextField*)v;
        if ([v isKindOfClass:[NSProgressIndicator class]]) spinner = (NSProgressIndicator*)v;
    }
    CHECK(status != nil && spinner != nil);
    if (!status || !spinner) return;
    // No Win32 status bar or size grip: the button bar is the window's last row.
    [ui.w.contentView layoutSubtreeIfNeeded];
    CHECK_EQ(NSMinY(bar.frame), CGFloat(0));
    CHECK_EQ(status.font.pointSize, kStatusFontSize);
    CHECK([status.textColor isEqual:NSColor.secondaryLabelColor]);
    CHECK_EQ(status.lineBreakMode, NSLineBreakByTruncatingTail);
    // Between Tools and Apply.
    auto box = [](NSView* v) { return [v alignmentRectForFrame:v.frame]; };
    // Reading tags: the text and a spinner.
    ui.backend->deferLoad = true;
    ui.backend->onChange();
    spin();
    CHECK_EQ(str(wpe_test_status(ui.c)), std::string("Reading tags…"));
    CHECK(wpe_test_status_busy(ui.c));
    [ui.w.contentView layoutSubtreeIfNeeded];
    CHECK(!spinner.hidden);
    CHECK(NSMinX(box(spinner)) >= NSMaxX(box(buttons[0])) + kBarSpacing - 0.5);
    CHECK(NSMinX(status.frame) >= NSMaxX(box(spinner)));
    ui.backend->finishLoad();
    spin();
    CHECK_EQ(str(wpe_test_status(ui.c)), std::string(""));
    CHECK(!wpe_test_status_busy(ui.c));
    [ui.w.contentView layoutSubtreeIfNeeded];
    CHECK(NSMinX(box(status)) >= NSMaxX(box(buttons[0])) + kBarSpacing - 2.5);  // the label's own inset
    CHECK(NSMaxX(status.frame) <= NSMinX(box(buttons[3])) - kBarSpacing + 0.5);
    // An error turns red and keeps its font; the whole text is the tool tip.
    ui.backend->failNext = true;
    ui.select(ui.row("TITLE"));
    ui.type(@"x");
    ui.ret();
    ui.action(@selector(applyPressed:));
    spin();
    CHECK([wpe_test_status(ui.c) containsString:@"Access denied"]);
    CHECK([status.textColor isEqual:NSColor.systemRedColor]);
    CHECK_EQ(status.font.pointSize, kStatusFontSize);
    CHECK_EQ(str(status.toolTip), str(wpe_test_status(ui.c)));
    CHECK(!wpe_test_status_busy(ui.c));
}

// The lists keep the row and header heights measured from screenshots of the Windows dialog (175% scaling: px / 1.75 = pt);
// their text is the system font at standard sizes with no tracking, like the chrome around them.
TEST(list_metrics_follow_the_screenshots_and_the_chrome_is_native) {
    using namespace wpe::ui;
    UI ui({tf({{"TITLE", {"t"}}})});
    wpe_test_select_tab(ui.c, 0);
    spin();
    CHECK_EQ([WPEHeaderAttributes(nil, nil)[NSFontAttributeName] pointSize], kChromeFontSize);
    CHECK(WPEHeaderAttributes(nil, nil)[NSTrackingAttributeName] == nil);
    CHECK(WPEHeaderAttributes(nil, nil)[NSKernAttributeName] == nil);
    CHECK(WPEListAttributes(nil, nil)[NSTrackingAttributeName] == nil);
    // List cells: 12 pt, plain text (no tracking or kerning attributes), truncated at the tail, in a text
    // field that fills the cell (WPEListTextCell places the line), its text rect kCellInset in.
    for (NSInteger col : {0, 1}) {
        NSTableCellView* cell = cellAt(ui.table, col, (NSInteger)ui.row("TITLE"));
        NSTextField* field = cell.textField;
        [cell layoutSubtreeIfNeeded];
        CHECK_EQ(field.font.pointSize, kListFontSize);
        CHECK([field.font isEqual:[NSFont systemFontOfSize:kListFontSize]]);
        NSAttributedString* text = field.attributedStringValue;
        CHECK(text.length > 0);
        if (text.length) {
            CHECK([text attribute:NSTrackingAttributeName atIndex:0 effectiveRange:nullptr] == nil);
            CHECK([text attribute:NSKernAttributeName atIndex:0 effectiveRange:nullptr] == nil);
        }
        CHECK_EQ(field.lineBreakMode, NSLineBreakByTruncatingTail);
        CHECK([field.cell isKindOfClass:[WPEListTextCell class]]);
        CHECK(NSEqualRects(field.frame, cell.bounds));
        // The glyphs start kCellInset in (the text rect kTextPadding before them) and end kCellInset before
        // the cell's edge.
        const NSRect textRect = [field.cell titleRectForBounds:field.bounds];
        CHECK_EQ(NSMinX(textRect) + kTextPadding, kCellInset);
        CHECK_EQ(NSMaxX(textRect) - kTextPadding, NSWidth(field.bounds) - kCellInset);
    }

    // Pages: a select-one segmented control, regular size, leading-aligned.
    NSSegmentedControl* pages = wpe_test_tab_control(ui.c);
    CHECK_EQ(pages.trackingMode, NSSegmentSwitchTrackingSelectOne);
    CHECK_EQ(pages.controlSize, NSControlSizeRegular);
    CHECK_EQ(pages.segmentCount, NSInteger(4));
    CHECK_EQ(pages.font.pointSize, [NSFont systemFontSizeForControlSize:NSControlSizeRegular]);
    // Buttons: stock regular controls in the 13 pt system font with no tracking; push buttons rounded.
    for (NSButton* b in wpe_test_buttons(ui.c)) {
        CHECK_EQ(b.controlSize, NSControlSizeRegular);
        CHECK_EQ(b.font.pointSize, [NSFont systemFontSizeForControlSize:NSControlSizeRegular]);
        NSAttributedString* t = b.attributedTitle;
        if (t.length) {
            CHECK([t attribute:NSTrackingAttributeName atIndex:0 effectiveRange:nullptr] == nil);
            CHECK([t attribute:NSKernAttributeName atIndex:0 effectiveRange:nullptr] == nil);
        }
        if (![b isKindOfClass:[NSPopUpButton class]]) {
            CHECK_EQ(b.bezelStyle, NSBezelStylePush);
            CHECK([b isMemberOfClass:[NSButton class]]);  // stock, nothing drawn by us
            CHECK(b.bordered);
        }
    }
    // The Edit Value sheet's chrome likewise (see edit_value_sheet_bar_follows_the_window_bar).
}

TEST(add_new_row_starts_a_field) {
    UI ui({tf({{"TITLE", {"t"}}})});
    const size_t n = ui.model().size();
    CHECK_EQ((NSInteger)ui.table.numberOfRows, NSInteger(n + 1));
    CHECK_EQ(cellText(ui.table, 0, (NSInteger)n), std::string("add new"));
    CHECK_EQ(cellText(ui.table, 1, (NSInteger)n), std::string(""));
    // A plus.circle.fill glyph where the names' text starts (kCellInset), then the text; spoken as a
    // command, not as "add new".
    {
        NSTableCellView* add = cellAt(ui.table, 0, (NSInteger)n);
        NSTableCellView* name = cellAt(ui.table, 0, 0);
        [add layoutSubtreeIfNeeded];
        [name layoutSubtreeIfNeeded];
        auto box = [](NSView* v) { return [v alignmentRectForFrame:v.frame]; };
        // Where a cell's glyphs start (its text rect plus the line fragment padding, in the cell's coordinates).
        auto textStart = [](NSTableCellView* c) {
            NSTextField* f = c.textField;
            return NSMinX([c convertRect:[f.cell titleRectForBounds:f.bounds] fromView:f]) + wpe::ui::kTextPadding;
        };
        CHECK(add.imageView.image != nil);
        CHECK(add.imageView.image.isTemplate);
        CHECK_EQ(NSMinX(box(add.imageView)), textStart(name));
        CHECK_EQ(textStart(name), wpe::ui::kCellInset);
        CHECK(std::fabs(textStart(add) - NSMaxX(box(add.imageView)) - wpe::ui::kAddGlyphGap) < 0.01);
        // The glyph on the row's centre line, where the text's capitals are centred.
        CHECK(std::fabs(NSMidY(box(add.imageView)) - NSMidY(add.bounds)) < 0.5);
        CHECK_EQ(str(add.textField.accessibilityLabel), std::string("Add New Field"));
        CHECK(!add.imageView.isAccessibilityElement);
        CHECK([add.textField.textColor isEqual:NSColor.secondaryLabelColor]);
    }

    ui.click(n, 0);
    CHECK_EQ(ui.editRow(), NSInteger(n));
    CHECK_EQ(ui.editCol(), NSInteger(0));
    ui.type(@"mood");
    ui.ret();
    CHECK_EQ(ui.editCol(), NSInteger(1));
    ui.type(@"calm");
    ui.ret();
    CHECK_EQ(ui.shown("MOOD"), std::string("calm"));
    ui.esc();
    CHECK_EQ((NSInteger)ui.table.numberOfRows, NSInteger(ui.model().size() + 1));
    CHECK_EQ(cellText(ui.table, 0, ui.table.numberOfRows - 1), std::string("add new"));

    // Return on the selected "add new" row, or typing on it, starts a new field too.
    ui.select(ui.model().size());
    ui.ret();
    CHECK_EQ(ui.editCol(), NSInteger(0));
    CHECK_EQ(ui.editor(), std::string(""));
    ui.esc();
    ui.select(ui.model().size());
    ui.type(@"r");
    CHECK_EQ(ui.editCol(), NSInteger(0));
    CHECK_EQ(ui.editor(), std::string("r"));
    ui.esc();
    // Delete on it removes nothing.
    ui.select(ui.model().size());
    ui.backspace();
    CHECK_EQ(ui.shown("MOOD"), std::string("calm"));
    CHECK_EQ(ui.shown("TITLE"), std::string("t"));
}

TEST(rows_are_shaded_alternately_without_grid_lines) {
    UI ui({tf({{"TITLE", {"t"}}})});
    CHECK_EQ(ui.table.gridStyleMask, NSTableViewGridNone);
    CHECK(!ui.table.usesAlternatingRowBackgroundColors);
    CHECK_EQ(ui.table.rowHeight, CGFloat(21));
    CHECK_EQ(ui.table.headerView.frame.size.height, CGFloat(18));
    NSArray<NSTableColumn*>* cols = ui.table.tableColumns;
    CHECK([[cols[0] title] isEqualToString:@"Name"]);
    CHECK([[cols[1] title] isEqualToString:@"Value"]);
    const CGFloat nameShare = [cols[0] width] / NSWidth(ui.table.bounds);
    CHECK(nameShare > 0.25 && nameShare < 0.31);
    [ui.w setContentSize:NSMakeSize(1200, 600)];
    [ui.w.contentView layoutSubtreeIfNeeded];
    spin();
    const CGFloat wider = [cols[0] width] / NSWidth(ui.table.enclosingScrollView.contentView.bounds);
    CHECK(wider > 0.27 && wider < 0.29);  // the share is kept
    [ui.table layoutSubtreeIfNeeded];
    NSTableRowView* r0 = [ui.table rowViewAtRow:0 makeIfNecessary:YES];
    NSTableRowView* r1 = [ui.table rowViewAtRow:1 makeIfNecessary:YES];
    CHECK(![[r0 valueForKey:@"wpeShaded"] boolValue]);
    CHECK([[r1 valueForKey:@"wpeShaded"] boolValue]);
}

TEST(tools_menu_works_on_staged_metadata_only) {
    UI ui({tf({{"ARTIST", {"A"}}, {"MOOD", {"calm"}}}), tf({{"ARTIST", {"B"}}, {"MOOD", {"calm"}}})});
    PrivatePasteboard pp;
    wpe_test_set_pasteboard(ui.c, pp.pb);
    // The pull-down's title item, then the commands in title case.
    CHECK_EQ(titles(wpe_test_tools_menu(ui.c)),
             (std::vector<std::string>{"Tools", "Format from Other Fields…", "Auto Track Number", "-", "Copy All Fields",
                                       "Paste Fields", "Remove All Fields", "-", "Selection"}));
    CHECK(wpe_test_tools_menu(ui.c) == ((NSPopUpButton*)wpe_test_buttons(ui.c)[0]).menu);
    ui.action(@selector(copyAllFields:));
    CHECK_EQ(str([pp.pb stringForType:NSPasteboardTypeString]),
             std::string("ARTIST=") + wpe::kMultipleValues + " A; B\nMOOD=calm");

    ui.action(@selector(removeAllFields:));
    CHECK(ui.model().dirty());
    CHECK_EQ(ui.row("MOOD"), wpe::npos);
    CHECK_EQ(ui.shown("ARTIST"), std::string(""));
    CHECK_EQ(ui.backend->writes, 0);
    CHECK(wpe_test_apply_enabled(ui.c));

    [pp.pb clearContents];
    [pp.pb setString:@"MOOD=happy\nGENRE=Rock; Pop" forType:NSPasteboardTypeString];
    ui.send(ui.key(@"V", 9, NSEventModifierFlagCommand | NSEventModifierFlagShift, @"V"));  // Paste fields
    CHECK_EQ(ui.shown("MOOD"), std::string("happy"));
    CHECK_EQ(ui.model().row(ui.row("GENRE")).all, (Values{"Rock", "Pop"}));
    CHECK_EQ(ui.backend->writes, 0);
    ui.action(@selector(applyPressed:));
    CHECK_EQ(ui.backend->writes, 1);
    CHECK_EQ(ui.backend->get(0, "MOOD"), Values{"happy"});
    CHECK(ui.backend->get(1, "ARTIST").empty());

    // Plain text is not pasted by "Paste fields".
    [pp.pb clearContents];
    [pp.pb setString:@"just text" forType:NSPasteboardTypeString];
    ui.action(@selector(pasteAllFields:));
    CHECK(!ui.model().dirty());
}

// The pull-down commits an open edit before its menu opens (its items act on what is on screen), stays
// closed while a ReplayGain value does not parse, and never performs its items' key equivalents itself.
TEST(tools_pull_down_prepares_before_its_menu_opens) {
    UI ui({tf({{"TITLE", {"t"}}})});
    ui.backend->rg = {gains(-6.54f)};
    ui.backend->onChange();
    spin();
    WPEPullDownButton* tools = (WPEPullDownButton*)wpe_test_buttons(ui.c)[0];
    CHECK([tools isKindOfClass:[WPEPullDownButton class]]);
    CHECK(tools.prepare != nil);
    if (!tools.prepare) return;
    ui.click(ui.row("TITLE"), 1);
    ui.type(@"new");
    CHECK(ui.editing());
    CHECK(tools.prepare());
    CHECK(!ui.editing());
    CHECK_EQ(ui.shown("TITLE"), std::string("new"));
    wpe_test_select_tab(ui.c, 2);
    clickCell(ui, wpe_test_rg_table(ui.c), 0, 1);
    ui.type(@"abc");
    CHECK(!tools.prepare());
    spin();
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(0));
    CHECK_EQ(str(wpe_test_rg_editor_text(ui.c)), std::string("abc"));
    ui.esc();
    CHECK(tools.prepare());
    NSEvent* shiftCmdV = ui.key(@"V", 9, NSEventModifierFlagCommand | NSEventModifierFlagShift, @"V");
    CHECK(![tools performKeyEquivalent:shiftCmdV]);
}

TEST(format_from_other_fields_uses_the_staged_values) {
    UI ui({tf({{"ARTIST", {"A"}}, {"TITLE", {"x"}}}), tf({{"ARTIST", {"B"}}, {"TITLE", {"y"}}})});
    ui.select(ui.row("ARTIST"));
    ui.ret();
    ui.type(@"Band");
    ui.ret();
    ui.esc();
    wpe_test_select_tab(ui.c, 3);
    CHECK(wpe_test_format(ui.c, @"title", @"%artist% - %title%"));
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(0));
    CHECK_EQ(ui.shown("TITLE"), std::string(wpe::kMultipleValues) + " Band - x; Band - y");
    CHECK(!wpe_test_format(ui.c, @"TITLE", @"%broken"));
    CHECK([wpe_test_status(ui.c) containsString:@"bad pattern"]);
    CHECK(!wpe_test_format(ui.c, @"A=B", @"%title%"));
    CHECK_EQ(ui.backend->writes, 0);
    ui.action(@selector(okPressed:));
    CHECK_EQ(ui.backend->get(1, "TITLE"), Values{"Band - y"});
}

TEST(artwork_rows_columns_and_labels) {
    NSData* png = makePNG(4, 3, NSColor.redColor);
    UI ui({tf({{"TITLE", {"t"}}})}, {artWith({{art::FrontCover, picOf(png)}})});
    wpe_test_select_tab(ui.c, 3);
    spin(20);
    NSTableView* t = wpe_test_art_table(ui.c);
    CHECK_EQ(t.numberOfRows, NSInteger(5));
    std::vector<std::string> names, headers;
    for (NSInteger r = 0; r < 5; ++r) names.push_back(cellText(t, 0, r));
    for (NSTableColumn* c in t.tableColumns) headers.push_back(c.title.UTF8String);
    CHECK_EQ(names, (std::vector<std::string>{"Front Cover", "Back Cover", "Artist", "Disc", "Icon"}));
    CHECK_EQ(headers, (std::vector<std::string>{"Name", "Picture", "Details", ""}));
    CHECK_EQ(t.rowHeight, CGFloat(106));
    CHECK_EQ([t.tableColumns[1] width], t.rowHeight);  // square picture cell
    CHECK([t.tableColumns[3] width] < [t.tableColumns[2] width] / 4);
    // Details takes the rest of the width and × is pinned to the trailing edge, at any window width
    // (no empty header stub after it).
    for (CGFloat width : {800.0, 1200.0, 560.0}) {
        [ui.w setContentSize:NSMakeSize(width, 600)];
        [ui.w.contentView layoutSubtreeIfNeeded];
        [t.enclosingScrollView layoutSubtreeIfNeeded];
        spin(2);
        const CGFloat clip = NSWidth(t.enclosingScrollView.contentView.bounds);
        CHECK(std::fabs(NSMaxX([t rectOfColumn:3]) - clip) <= 1);
        CHECK_EQ([t.tableColumns[3] width], wpe::ui::kArtRemoveWidth);
        CHECK_EQ([t.tableColumns[0] width], t.rowHeight);
        CHECK(std::fabs(NSMinX([t rectOfColumn:3]) - NSMaxX([t rectOfColumn:2])) < 0.01);
    }
    CHECK_EQ(cellText(t, 2, 0), std::string("1 KB\n4x3\nPNG"));
    CHECK_EQ(cellText(t, 2, 1), std::string("\xC2\xAB" "not present" "\xC2\xBB"));
    // Details lines 30 px apart, untracked; one line or three, the glyphs lifted by the same amount so the
    // block's capitals are centred (the fixed pitch puts its extra leading above the glyphs).
    const CGFloat lift = WPEFixedLineCapLift(WPEListFont(), wpe::ui::kArtDetailsLineHeight, WPEDeviceScale(t, NO));
    CHECK(lift > 0.5 && lift < 2);
    NSDictionary* lines = [cellAt(t, 2, 0).textField.attributedStringValue attributesAtIndex:0 effectiveRange:nullptr];
    CHECK_EQ([lines[NSParagraphStyleAttributeName] minimumLineHeight], wpe::ui::kArtDetailsLineHeight);
    CHECK_EQ([lines[NSParagraphStyleAttributeName] maximumLineHeight], wpe::ui::kArtDetailsLineHeight);
    CHECK(lines[NSTrackingAttributeName] == nil);
    CHECK_EQ([lines[NSBaselineOffsetAttributeName] doubleValue], double(lift));
    NSDictionary* absent = [cellAt(t, 2, 1).textField.attributedStringValue attributesAtIndex:0 effectiveRange:nullptr];
    CHECK(absent[NSTrackingAttributeName] == nil);
    CHECK_EQ([absent[NSBaselineOffsetAttributeName] doubleValue], double(lift));
    // Names in the list font, untracked, in a list text field filling the cell (optically centred).
    NSTextField* front = cellAt(t, 0, 0).textField;
    CHECK([front.cell isKindOfClass:[WPEListTextCell class]]);
    CHECK([front.attributedStringValue attribute:NSTrackingAttributeName atIndex:0 effectiveRange:nullptr] == nil);
    CHECK(NSEqualRects(front.frame, cellAt(t, 0, 0).bounds));
    // "+" (plus.circle) only in empty Picture cells; "×" (xmark.circle.fill) only where there is
    // something to remove, always shown there. SF Symbols, tinted, with a pressed state and spoken labels.
    CHECK(cellButton(t, 1, 0).hidden);
    CHECK(!cellButton(t, 1, 1).hidden);
    CHECK(!cellButton(t, 3, 0).hidden);
    CHECK(cellButton(t, 3, 1).hidden);
    for (NSButton* b in @[ cellButton(t, 1, 1), cellButton(t, 3, 0) ]) {
        CHECK(b.image != nil && b.image.isTemplate);
        CHECK_EQ(str(b.title), std::string(""));
        CHECK([b.contentTintColor isEqual:NSColor.tertiaryLabelColor]);
        [b highlight:YES];
        CHECK([b.contentTintColor isEqual:NSColor.secondaryLabelColor]);
        [b highlight:NO];
        CHECK([b.contentTintColor isEqual:NSColor.tertiaryLabelColor]);
    }
    CHECK_EQ(str(cellButton(t, 1, 1).accessibilityLabel), std::string("Add picture"));
    CHECK_EQ(str(cellButton(t, 3, 0).accessibilityLabel), std::string("Remove picture"));
    {
        // × sits in the trailing column, centred.
        NSButton* x = cellButton(t, 3, 0);
        [cellAt(t, 3, 0) layoutSubtreeIfNeeded];
        const NSRect inTable = [x convertRect:x.bounds toView:t];
        CHECK(std::fabs(NSMidX(inTable) - NSMidX([t rectOfColumn:3])) <= 0.5);
    }
    CHECK(wpe_test_art_thumbnail_ready(ui.c, art::FrontCover));
    CHECK(cellAt(t, 1, 0).imageView.image != nil);
    // The thumbnail is inset by kThumbInset (a 4x3 picture: as wide as the inset box, centred).
    {
        WPEThumbView* thumb = (WPEThumbView*)cellAt(t, 1, 0).imageView;
        CHECK([thumb isKindOfClass:[WPEThumbView class]]);
        [cellAt(t, 1, 0) layoutSubtreeIfNeeded];
        const NSRect r = [thumb wpeImageRect];
        const NSRect box = NSInsetRect(thumb.bounds, wpe::ui::kThumbInset, wpe::ui::kThumbInset);
        CHECK_EQ(NSMinX(r), NSMinX(box));
        CHECK_EQ(NSMaxX(r), NSMaxX(box));
        CHECK(NSHeight(r) < NSHeight(box));
        CHECK(std::fabs(NSMidY(r) - NSMidY(box)) <= 0.5);
    }
    CHECK_EQ(titles(wpe_test_art_menu(ui.c)),
             (std::vector<std::string>{"Import from file…", "Export to file…", "-", "Copy", "Paste here", "-", "Remove"}));
}

TEST(artwork_multiple_values_and_identical_pictures) {
    NSData* a = makePNG(2, 2, NSColor.redColor);
    NSData* b = makePNG(2, 2, NSColor.blueColor);
    // Front: the same bytes in two files. Back: different. Disc: only one file has one.
    UI ui({tf({{"TITLE", {"x"}}}), tf({{"TITLE", {"y"}}})},
          {artWith({{art::FrontCover, picOf(a)}, {art::BackCover, picOf(a)}, {art::Disc, picOf(b)}}),
           artWith({{art::FrontCover, picOf([a copy])}, {art::BackCover, picOf(b)}})});
    wpe_test_select_tab(ui.c, 3);
    spin(20);
    NSTableView* t = wpe_test_art_table(ui.c);
    const std::string mv = "\xC2\xAB" "multiple values" "\xC2\xBB";
    CHECK_EQ(cellText(t, 2, 0), std::string("1 KB\n2x2\nPNG"));
    CHECK_EQ(cellText(t, 2, 1), mv);
    CHECK_EQ(cellText(t, 2, 3), mv);
    CHECK_EQ(cellText(t, 2, 2), std::string("\xC2\xAB" "not present" "\xC2\xBB"));
    NSColor* grey = [cellAt(t, 2, 1).textField.attributedStringValue attribute:NSForegroundColorAttributeName
                                                                       atIndex:0
                                                                effectiveRange:nullptr];
    CHECK([grey isEqual:NSColor.secondaryLabelColor]);
    CHECK(cellButton(t, 1, 1).hidden);   // no "+" over mixed pictures
    CHECK(!cellButton(t, 3, 1).hidden);  // but they can be removed
}

TEST(artwork_edits_are_staged_until_apply) {
    NSData* front = makePNG(3, 3, NSColor.greenColor);
    NSData* back = makePNG(5, 4, NSColor.blueColor);
    // Two subsongs of one file: written once.
    UI ui({tf({{"TITLE", {"x"}}}), tf({{"TITLE", {"y"}}})},
          {artWith({{art::FrontCover, picOf(front)}}), artWith({{art::FrontCover, picOf(front)}})},
          {"file:///cd.flac", "file:///cd.flac"});
    PrivatePasteboard pp;
    wpe_test_set_pasteboard(ui.c, pp.pb);
    [pp.pb clearContents];
    [pp.pb setData:back forType:NSPasteboardTypePNG];
    wpe_test_select_tab(ui.c, 3);
    spin(20);
    NSTableView* t = wpe_test_art_table(ui.c);
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    ui.send(ui.key(@"v", 9, NSEventModifierFlagCommand));  // paste onto Back Cover
    spin(20);
    const auto& m = wpe_test_art_model(ui.c);
    CHECK(m.slot(art::BackCover).isPending());
    CHECK_EQ(cellText(t, 2, 1), std::string("1 KB\n5x4\nPNG"));
    NSFont* f = [cellAt(t, 2, 1).textField.attributedStringValue attribute:NSFontAttributeName atIndex:0 effectiveRange:nullptr];
    CHECK(([[NSFontManager sharedFontManager] traitsOfFont:f] & NSItalicFontMask) != 0);
    CHECK([wpe_test_status(ui.c) containsString:@"Back Cover (pending)"]);
    CHECK(wpe_test_apply_enabled(ui.c));
    CHECK(ui.w.documentEdited);

    // "×" on Front Cover stages a removal.
    [cellButton(t, 3, 0) performClick:nil];
    spin();
    CHECK(m.slot(art::FrontCover).isPending());
    CHECK_EQ(cellText(t, 2, 0), std::string("\xC2\xAB" "not present" "\xC2\xBB"));
    CHECK(!cellButton(t, 1, 0).hidden);
    CHECK(ui.backend->art[0].pictures[art::FrontCover] != nullptr);
    CHECK_EQ(ui.backend->artWrites, 0);

    ui.action(@selector(applyPressed:));
    spin(20);
    CHECK_EQ(ui.backend->artWrites, 1);
    CHECK_EQ(ui.backend->writes, 0);  // no tag changes
    CHECK_EQ(ui.backend->artWritten.size(), size_t(1));
    if (ui.backend->artWritten.size() == 1) {
        CHECK_EQ(ui.backend->artWritten[0].path, std::string("file:///cd.flac"));
        CHECK_EQ(ui.backend->artWritten[0].tracks, (std::vector<size_t>{0, 1}));
        CHECK_EQ(ui.backend->artWritten[0].ops.size(), size_t(2));
    }
    CHECK(ui.backend->art[1].pictures[art::FrontCover] == nullptr);
    CHECK(art::same(ui.backend->art[1].pictures[art::BackCover], picOf(back)));
    CHECK(!wpe_test_art_model(ui.c).dirty());
    CHECK_EQ(ui.backend->artLoads, 2);  // reloaded from the files
    CHECK(wpe_test_art_model(ui.c).slot(art::BackCover).state() == art::State::Present);
    CHECK_EQ(str(wpe_test_status(ui.c)), std::string("Updated 1 file."));  // one physical file
    CHECK(!wpe_test_apply_enabled(ui.c));
}

TEST(artwork_cancel_and_escape_discard_staged_changes) {
    NSData* front = makePNG(3, 3, NSColor.greenColor);
    UI ui({tf({{"TITLE", {"x"}}})}, {artWith({{art::FrontCover, picOf(front)}, {art::Icon, picOf(front)}})});
    const size_t before = wpe_open_window_count();
    wpe_test_select_tab(ui.c, 3);
    spin(20);
    NSTableView* t = wpe_test_art_table(ui.c);
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:4] byExtendingSelection:NO];
    ui.backspace();  // Delete removes the selected row's picture (staged)
    CHECK(wpe_test_art_model(ui.c).slot(art::Icon).isPending());
    [cellButton(t, 3, 0) performClick:nil];
    spin();
    CHECK(wpe_test_art_model(ui.c).dirty());
    ui.esc();
    CHECK_EQ(wpe_open_window_count(), before - 1);
    CHECK_EQ(ui.backend->artWrites, 0);
    CHECK_EQ(ui.backend->writes, 0);
    CHECK(ui.backend->art[0].pictures[art::FrontCover] != nullptr);
    CHECK(ui.backend->art[0].pictures[art::Icon] != nullptr);
    CHECK(ui.backend->cancels >= 1);
}

TEST(artwork_copy_paste_and_drop) {
    NSData* front = makePNG(6, 6, NSColor.orangeColor);
    UI ui({tf({{"TITLE", {"x"}}})}, {artWith({{art::FrontCover, picOf(front)}})});
    PrivatePasteboard pp;
    wpe_test_set_pasteboard(ui.c, pp.pb);
    wpe_test_select_tab(ui.c, 3);
    spin(20);
    NSTableView* t = wpe_test_art_table(ui.c);
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    ui.send(ui.key(@"c", 8, NSEventModifierFlagCommand));
    CHECK([[pp.pb dataForType:NSPasteboardTypePNG] isEqualToData:front]);
    CHECK([pp.pb dataForType:NSPasteboardTypeTIFF] != nil);
    // Paste it as the Disc picture, then drop it on Artist.
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:3] byExtendingSelection:NO];
    ui.send(ui.key(@"v", 9, NSEventModifierFlagCommand));
    CHECK(art::same(wpe_test_art_model(ui.c).slot(art::Disc).picture(), picOf(front)));
    PrivatePasteboard drag;
    [drag.pb clearContents];
    [drag.pb setData:makePNG(2, 2, NSColor.blackColor) forType:NSPasteboardTypePNG];
    BOOL dropped = NO;
    NSInvocation* inv = [NSInvocation invocationWithMethodSignature:[ui.c methodSignatureForSelector:@selector(dropPasteboard:row:)]];
    inv.selector = @selector(dropPasteboard:row:);
    NSPasteboard* dragPb = drag.pb;
    NSInteger row = 2;
    [inv setArgument:&dragPb atIndex:2];
    [inv setArgument:&row atIndex:3];
    [inv invokeWithTarget:ui.c];
    [inv getReturnValue:&dropped];
    CHECK(dropped);
    CHECK(wpe_test_art_model(ui.c).slot(art::Artist).isPending());
    // Text is not a picture.
    [drag.pb clearContents];
    [drag.pb setString:@"hello" forType:NSPasteboardTypeString];
    [inv invokeWithTarget:ui.c];
    [inv getReturnValue:&dropped];
    CHECK(!dropped);
    CHECK_EQ(ui.backend->artWrites, 0);
}

namespace {

// An RGB(A) picture `w`×`h` encoded by ImageIO as `type`, with an EXIF/HEIF orientation (1: upright). nil
// when this Mac has no encoder for the type (HEIC needs a hardware encoder on some Macs).
NSData* encodeImage(UTType* type, size_t w, size_t h, bool alpha, int orientation = 1) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(nullptr, w, h, 8, 0, cs,
                                             alpha ? (CGBitmapInfo)kCGImageAlphaPremultipliedLast : (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextSetRGBFillColor(ctx, 0.9, 0.2, 0.1, alpha ? 0.5 : 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGContextSetRGBFillColor(ctx, 0.1, 0.3, 0.9, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, w / 2, h / 2));
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    NSMutableData* out = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, (__bridge CFStringRef)type.identifier, 1, nullptr);
    bool ok = false;
    if (dest && image) {
        CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef) @{(__bridge NSString*)kCGImagePropertyOrientation : @(orientation)});
        ok = CGImageDestinationFinalize(dest);
    }
    if (dest) CFRelease(dest);
    if (image) CGImageRelease(image);
    return ok && out.length ? out : nil;
}

bool decodesWithAlpha(NSData* data) {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    if (!src) return false;
    CGImageRef image = CGImageSourceCreateImageAtIndex(src, 0, nullptr);
    CFRelease(src);
    if (!image) return false;
    const CGImageAlphaInfo a = CGImageGetAlphaInfo(image);
    CGImageRelease(image);
    return a != kCGImageAlphaNone && a != kCGImageAlphaNoneSkipFirst && a != kCGImageAlphaNoneSkipLast;
}

// "Import from file…" with a file holding `data` (the open panel itself needs a window on screen).
art::Picture importAs(UI& ui, NSData* data, NSString* name, NSInteger row) {
    NSString* dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"wpe-import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL* url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
    [data writeToURL:url atomically:YES];
    NSInvocation* inv = [NSInvocation invocationWithMethodSignature:[ui.c methodSignatureForSelector:@selector(importArtFile:row:)]];
    inv.selector = @selector(importArtFile:row:);
    [inv setArgument:&url atIndex:2];
    [inv setArgument:&row atIndex:3];
    [inv invokeWithTarget:ui.c];
    spin(5);
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    const art::Slot& slot = wpe_test_art_model(ui.c).slot((size_t)row);
    return slot.pending == art::Slot::Pending::Set ? slot.pendingPicture : nullptr;
}

NSData* bytesOf(const art::Picture& p) {
    return p ? [NSData dataWithBytes:p->data() length:p->size()] : nil;
}

}

// What a drop hands the list (only the parts it reads).
@interface WPETestDrag : NSObject
@property(strong) NSPasteboard* draggingPasteboard;
@property(weak) id draggingSource;
@end
@implementation WPETestDrag
@end

// Import, paste and drop keep what foobar2000 attaches byte for byte; HEIF/AVIF photos become JPEG (they
// are lossy already), everything else and anything with transparency lossless PNG, drawn upright.
TEST(artwork_imports_keep_attachable_bytes_and_convert_photos_to_jpeg) {
    UI ui({tf({{"TITLE", {"x"}}})}, {artWith({})});
    wpe_test_select_tab(ui.c, 3);
    spin(20);
    NSArray<UTType*>* types = wpe_test_import_types(ui.c);
    // What foobar2000 attaches, plus HEIF/HEIC, AVIF and TIFF (converted); not RAW, PSD or any other image.
    auto offered = [types](UTType* t) {
        for (UTType* allowed in types)
            if ([t conformsToType:allowed]) return true;
        return false;
    };
    for (UTType* t : {UTTypeJPEG, UTTypePNG, UTTypeGIF, UTTypeWebP, UTTypeBMP, UTTypeHEIC, UTTypeHEIF, UTTypeTIFF})
        CHECK(offered(t));
    if (UTType* avif = [UTType typeWithIdentifier:@"public.avif"]) CHECK(offered(avif));
    CHECK(!offered(UTTypeImage));
    CHECK(!offered(UTTypeRAWImage));
    if (UTType* psd = [UTType typeWithIdentifier:@"com.adobe.photoshop-image"]) CHECK(!offered(psd));
    if (UTType* dng = [UTType typeWithFilenameExtension:@"dng"]) CHECK(!offered(dng));
    if (UTType* cr2 = [UTType typeWithFilenameExtension:@"cr2"]) CHECK(!offered(cr2));
    CHECK(!offered(UTTypePDF));

    NSData* png = makePNG(5, 4, NSColor.redColor);
    CHECK([bytesOf(importAs(ui, png, @"a.png", art::FrontCover)) isEqualToData:png]);
    NSData* bmp = encodeImage(UTTypeBMP, 6, 3, false);
    CHECK(bmp != nil);
    if (bmp) CHECK([bytesOf(importAs(ui, bmp, @"b.bmp", art::BackCover)) isEqualToData:bmp]);
    NSData* jpg = encodeImage(UTTypeJPEG, 7, 5, false);
    if (jpg) CHECK([bytesOf(importAs(ui, jpg, @"c.jpg", art::Artist)) isEqualToData:jpg]);

    // TIFF: lossless PNG, the same size, with or without transparency.
    for (bool alpha : {false, true}) {
        NSData* tiff = encodeImage(UTTypeTIFF, 9, 6, alpha);
        const art::Picture p = importAs(ui, tiff, @"d.tif", art::Disc);
        CHECK(p != nullptr);
        if (!p) continue;
        CHECK(art::sniff(*p) == art::Format::PNG);
        CHECK(art::dimensions(*p) == (art::Dimensions{9, 6}));
        CHECK_EQ(decodesWithAlpha(bytesOf(p)), alpha);
    }
    CHECK_EQ(cellText(wpe_test_art_table(ui.c), 2, 3), std::string("1 KB\n9x6\nPNG"));

    // A HEIF photo: JPEG, upright (orientation 6 is a quarter turn: 8×4 stored, 4×8 seen).
    if (NSData* heic = encodeImage(UTTypeHEIC, 8, 4, false, 6)) {
        CHECK(art::sniff(static_cast<const uint8_t*>(heic.bytes), heic.length) == art::Format::HEIF);
        const art::Picture p = importAs(ui, heic, @"e.heic", art::Icon);
        CHECK(p != nullptr);
        if (p) {
            CHECK(art::sniff(*p) == art::Format::JPEG);
            CHECK(art::dimensions(*p) == (art::Dimensions{4, 8}));
        }
        CHECK(cellText(wpe_test_art_table(ui.c), 2, 4).find("JPEG") != std::string::npos);
        // With transparency it stays lossless.
        NSData* clear = encodeImage(UTTypeHEIC, 8, 4, true);
        if (clear && decodesWithAlpha(clear)) {
            const art::Picture q = importAs(ui, clear, @"f.heic", art::Icon);
            CHECK(q != nullptr && art::sniff(*q) == art::Format::PNG);
        }
    } else {
        std::printf("     (no HEIC encoder on this Mac: the HEIF conversion is not checked)\n");
    }

    // Not a picture: nothing is staged and the status line says so.
    const art::Picture none = importAs(ui, [@"hello" dataUsingEncoding:NSUTF8StringEncoding], @"g.txt", art::Icon);
    CHECK([wpe_test_status(ui.c) containsString:@"is not a picture that can be attached"]);
    (void)none;
    CHECK_EQ(ui.backend->artWrites, 0);
}

// Space shows the selected pictures in Quick Look: files named as Export names them, in the window's own
// temporary folder, removed when it closes. VoiceOver reads each thumbnail's details.
TEST(artwork_space_shows_quick_look_and_thumbnails_are_described) {
    NSData* front = makePNG(6, 4, NSColor.orangeColor);
    NSData* disc = makePNG(3, 3, NSColor.blueColor);
    UI ui({tf({{"TITLE", {"x"}}})}, {artWith({{art::FrontCover, picOf(front)}, {art::Disc, picOf(disc)}})});
    PrivatePasteboard pp;
    wpe_test_set_pasteboard(ui.c, pp.pb);
    wpe_test_select_tab(ui.c, 3);
    spin(20);
    NSTableView* t = wpe_test_art_table(ui.c);
    CHECK(ui.w.firstResponder == t);
    CHECK([t respondsToSelector:@selector(acceptsPreviewPanelControl:)]);
    CHECK([t respondsToSelector:@selector(beginPreviewPanelControl:)] && [t respondsToSelector:@selector(endPreviewPanelControl:)]);
    CHECK_EQ(str(cellAt(t, 1, 0).imageView.accessibilityLabel), std::string("Front Cover, 6\xC3\x97" "4 PNG, 1 KB"));
    CHECK([cellAt(t, 1, 0).imageView.accessibilityHelp containsString:@"Quick Look"]);

    NSMutableIndexSet* rows = [NSMutableIndexSet indexSetWithIndex:art::FrontCover];
    [rows addIndex:art::BackCover];  // no picture: left out
    [rows addIndex:art::Disc];
    [t selectRowIndexes:rows byExtendingSelection:NO];
    ui.send(ui.key(@" ", 49));
    NSArray<NSURL*>* items = wpe_test_quicklook_items(ui.c);
    CHECK_EQ(items.count, NSUInteger(2));
    if (items.count != 2) return;
    CHECK_EQ(str(items[0].lastPathComponent), std::string("Front Cover.png"));
    CHECK_EQ(str(items[1].lastPathComponent), std::string("Disc.png"));
    CHECK([[NSData dataWithContentsOfURL:items[0]] isEqualToData:front]);
    CHECK([[NSData dataWithContentsOfURL:items[1]] isEqualToData:disc]);
    NSString* folder = wpe_test_quicklook_folder(ui.c);
    CHECK([items[0].path hasPrefix:folder]);
    CHECK([folder hasPrefix:NSTemporaryDirectory()]);  // never under ~/Library
    // The panel's data source.
    id<QLPreviewPanelDataSource> source = (id<QLPreviewPanelDataSource>)ui.c;
    CHECK_EQ([source numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel*)nil], NSInteger(2));
    CHECK([(NSURL*)[source previewPanel:(QLPreviewPanel*)nil previewItemAtIndex:1] isEqual:items[1]]);

    // A picture staged since gets a file of its own; the unchanged one keeps its file.
    NSData* staged = makePNG(2, 2, NSColor.greenColor);
    [pp.pb clearContents];
    [pp.pb setData:staged forType:NSPasteboardTypePNG];
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:art::Disc] byExtendingSelection:NO];
    ui.send(ui.key(@"v", 9, NSEventModifierFlagCommand));
    CHECK(wpe_test_art_model(ui.c).slot(art::Disc).isPending());
    [t selectRowIndexes:rows byExtendingSelection:NO];
    ui.send(ui.key(@" ", 49));
    NSArray<NSURL*>* again = wpe_test_quicklook_items(ui.c);
    CHECK_EQ(again.count, NSUInteger(2));
    if (again.count == 2) {
        CHECK([again[0] isEqual:items[0]]);
        CHECK(![again[1] isEqual:items[1]]);
        CHECK_EQ(str(again[1].lastPathComponent), std::string("Disc.png"));
        CHECK([[NSData dataWithContentsOfURL:again[1]] isEqualToData:staged]);
        CHECK(![[NSFileManager defaultManager] fileExistsAtPath:items[1].path]);  // the old one is gone
    }
    CHECK([cellAt(t, 1, art::Disc).imageView.accessibilityLabel hasSuffix:@", pending"]);
    // Nothing to show on a row without a picture.
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:art::Artist] byExtendingSelection:NO];
    ui.send(ui.key(@" ", 49));
    CHECK_EQ(wpe_test_quicklook_items(ui.c).count, NSUInteger(0));
    CHECK([[NSFileManager defaultManager] fileExistsAtPath:folder]);
    // Closing the window removes its folder.
    [ui.w close];
    spin();
    CHECK(![[NSFileManager defaultManager] fileExistsAtPath:folder]);
}

// A picture drags out as a file promise ("Front Cover.png") plus its own bytes; onto another row of the
// list it is a copy, byte for byte; onto its own row nothing happens.
TEST(artwork_pictures_drag_out_as_files_and_onto_other_rows) {
    NSData* front = makePNG(6, 6, NSColor.orangeColor);
    NSData* tiff = encodeImage(UTTypeTIFF, 5, 5, false);
    UI ui({tf({{"TITLE", {"x"}}}), tf({{"TITLE", {"y"}}})},
          {artWith({{art::FrontCover, picOf(front)}, {art::BackCover, picOf(front)}, {art::Icon, picOf(tiff)}}),
           artWith({{art::FrontCover, picOf(front)}, {art::Icon, picOf(tiff)}})});
    wpe_test_select_tab(ui.c, 3);
    spin(20);
    NSTableView* t = wpe_test_art_table(ui.c);
    id<NSPasteboardWriting> writer = wpe_test_art_writer(ui.c, art::FrontCover);
    CHECK([(id)writer isKindOfClass:[NSFilePromiseProvider class]]);
    if (![(id)writer isKindOfClass:[NSFilePromiseProvider class]]) return;
    NSFilePromiseProvider* promise = (NSFilePromiseProvider*)writer;
    CHECK_EQ(str(promise.fileType), std::string("public.png"));
    CHECK_EQ(str([promise.delegate filePromiseProvider:promise fileNameForType:promise.fileType]), std::string("Front Cover.png"));
    PrivatePasteboard pp;
    CHECK([[promise writableTypesForPasteboard:pp.pb] containsObject:@"public.png"]);
    // A private type marks a drag from the list itself (registered, so a row of any format can be dropped).
    NSString* rowType = @"io.github.metal2050.foo_windows_properties.artwork-row";
    CHECK([[promise writableTypesForPasteboard:pp.pb] containsObject:rowType]);
    CHECK([t.registeredDraggedTypes containsObject:rowType]);
    CHECK([[promise pasteboardPropertyListForType:@"public.png"] isEqual:front]);
    // The promise writes the picture's own bytes where it is dropped.
    NSString* dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"wpe-drag-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL* dest = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"Front Cover.png"]];
    __block bool done = false;
    __block NSError* failure = nil;
    [promise.delegate filePromiseProvider:promise
                        writePromiseToURL:dest
                        completionHandler:^(NSError* e) {
                            done = true;
                            failure = e;
                        }];
    CHECK(done && failure == nil);
    CHECK([[NSData dataWithContentsOfURL:dest] isEqualToData:front]);
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    // Only rows with one picture for every track can be dragged.
    CHECK(wpe_test_art_writer(ui.c, art::BackCover) == nil);  // «multiple values»
    CHECK(wpe_test_art_writer(ui.c, art::Disc) == nil);       // «not present»
    CHECK_EQ(str(((NSFilePromiseProvider*)wpe_test_art_writer(ui.c, art::Icon)).fileType), std::string("public.tiff"));

    // Within the list: Icon (a TIFF) dragged onto Disc is staged as the same bytes, not converted.
    WPETestDrag* drag = [WPETestDrag new];
    drag.draggingPasteboard = pp.pb;
    drag.draggingSource = t;
    [pp.pb clearContents];
    [pp.pb setData:tiff forType:NSPasteboardTypeTIFF];
    wpe_test_art_drag_row(ui.c, art::Icon);
    id<NSTableViewDataSource> ds = (id<NSTableViewDataSource>)ui.c;
    CHECK_EQ([ds tableView:t validateDrop:(id<NSDraggingInfo>)drag proposedRow:art::Icon proposedDropOperation:NSTableViewDropOn],
             NSDragOperationNone);
    CHECK_EQ([ds tableView:t validateDrop:(id<NSDraggingInfo>)drag proposedRow:art::Disc proposedDropOperation:NSTableViewDropOn],
             NSDragOperationCopy);
    CHECK([ds tableView:t acceptDrop:(id<NSDraggingInfo>)drag row:art::Disc dropOperation:NSTableViewDropOn]);
    const art::Slot& disc = wpe_test_art_model(ui.c).slot(art::Disc);
    CHECK(disc.isPending() && art::same(disc.picture(), picOf(tiff)));
    CHECK(art::sniff(*disc.picture()) == art::Format::TIFF);
    // Several rows dragged together (no single dragged row) are refused within the list: never converted
    // through the import path, never dropped onto one of the dragged rows.
    wpe_test_art_drag_row(ui.c, -1);
    CHECK_EQ([ds tableView:t validateDrop:(id<NSDraggingInfo>)drag proposedRow:art::Artist proposedDropOperation:NSTableViewDropOn],
             NSDragOperationNone);
    CHECK_EQ([ds tableView:t validateDrop:(id<NSDraggingInfo>)drag proposedRow:art::Icon proposedDropOperation:NSTableViewDropOn],
             NSDragOperationNone);
    CHECK(![ds tableView:t acceptDrop:(id<NSDraggingInfo>)drag row:art::Artist dropOperation:NSTableViewDropOn]);
    CHECK(![ds tableView:t acceptDrop:(id<NSDraggingInfo>)drag row:art::Icon dropOperation:NSTableViewDropOn]);
    CHECK(!wpe_test_art_model(ui.c).slot(art::Artist).isPending());
    CHECK(!wpe_test_art_model(ui.c).slot(art::Icon).isPending());
    // From elsewhere (Finder, another app) a drop is an import as before.
    drag.draggingSource = nil;
    CHECK([ds tableView:t acceptDrop:(id<NSDraggingInfo>)drag row:art::Artist dropOperation:NSTableViewDropOn]);
    const art::Slot& artist = wpe_test_art_model(ui.c).slot(art::Artist);
    CHECK(artist.isPending() && artist.picture() && art::sniff(*artist.picture()) == art::Format::PNG);
    CHECK_EQ(ui.backend->artWrites, 0);
}

TEST(ok_writes_tags_and_pictures_and_failures_keep_the_window) {
    NSData* front = makePNG(3, 3, NSColor.greenColor);
    UI ui({tf({{"TITLE", {"x"}}})}, {artWith({{art::FrontCover, picOf(front)}})});
    const size_t before = wpe_open_window_count();
    ui.select(ui.row("TITLE"));
    ui.type(@"new");
    ui.ret();
    ui.esc();
    wpe_test_select_tab(ui.c, 3);
    spin(20);
    [cellButton(wpe_test_art_table(ui.c), 3, 0) performClick:nil];
    ui.backend->failNextArt = true;
    ui.action(@selector(okPressed:));
    spin(20);
    CHECK_EQ(ui.backend->writes, 1);
    CHECK_EQ(ui.backend->artWrites, 1);
    CHECK_EQ(wpe_open_window_count(), before);  // stays open
    CHECK([wpe_test_status(ui.c) containsString:@"could not be updated"]);
    CHECK([wpe_test_status(ui.c) containsString:@"Attached picture editing failure"]);
    CHECK(wpe_test_art_model(ui.c).dirty());  // the pictures are kept for a retry
    CHECK(!ui.model().dirty());               // the tags were written and reloaded
    CHECK_EQ(ui.backend->get(0, "TITLE"), Values{"new"});
    ui.action(@selector(okPressed:));
    spin(20);
    CHECK_EQ(ui.backend->artWrites, 2);
    CHECK_EQ(ui.backend->writes, 1);
    CHECK(ui.backend->art[0].pictures[art::FrontCover] == nullptr);
    CHECK_EQ(wpe_open_window_count(), before - 1);
}

TEST(ok_while_tags_reload_still_writes_staged_pictures) {
    NSData* a = makePNG(2, 2, NSColor.redColor);
    UI ui({tf({{"TITLE", {"x"}}})}, {artWith({{art::FrontCover, picOf(a)}})});
    const size_t before = wpe_open_window_count();
    wpe_test_select_tab(ui.c, 3);
    spin(10);
    [cellButton(wpe_test_art_table(ui.c), 3, 0) performClick:nil];
    ui.backend->deferLoad = true;
    ui.backend->onChange();  // the clean tag list reloads; the staged picture is kept
    CHECK(ui.backend->finishLoad != nullptr);
    CHECK(wpe_test_art_model(ui.c).dirty());
    ui.action(@selector(okPressed:));
    spin(20);
    CHECK_EQ(ui.backend->artWrites, 1);
    CHECK_EQ(ui.backend->writes, 0);
    CHECK(ui.backend->art[0].pictures[art::FrontCover] == nullptr);
    CHECK_EQ(wpe_open_window_count(), before - 1);
    auto finish = ui.backend->finishLoad;
    ui.backend->deferLoad = false;
    if (finish) finish();  // arrives after closing: ignored
    spin();
}

TEST(artwork_loads_asynchronously_and_closing_drops_the_result) {
    UI ui({tf({{"TITLE", {"x"}}})}, {artWith({})});
    ui.backend->deferArt = true;
    wpe_test_select_tab(ui.c, 3);
    CHECK_EQ(str(wpe_test_status(ui.c)), std::string("Loading album art…"));
    CHECK(wpe_test_status_busy(ui.c));  // with a spinner
    wpe_test_select_tab(ui.c, 0);       // only while the Artwork page shows
    CHECK_EQ(str(wpe_test_status(ui.c)), std::string(""));
    CHECK(!wpe_test_status_busy(ui.c));
    wpe_test_select_tab(ui.c, 3);
    CHECK(wpe_test_status_busy(ui.c));
    CHECK(!wpe_test_art_model(ui.c).loaded());
    auto finish = ui.backend->finishArt;
    CHECK(finish != nullptr);
    [ui.w close];
    spin();
    CHECK(ui.backend->cancels >= 1);
    if (finish) finish();  // a late result after closing is ignored
    spin();
    CHECK(!wpe_test_art_model(ui.c).loaded());
}

TEST(outside_changes_reload_clean_artwork_only) {
    NSData* a = makePNG(2, 2, NSColor.redColor);
    UI ui({tf({{"TITLE", {"x"}}})}, {artWith({})});
    wpe_test_select_tab(ui.c, 3);
    spin(10);
    CHECK(wpe_test_art_model(ui.c).slot(art::FrontCover).state() == art::State::Absent);
    ui.backend->art[0].pictures[art::FrontCover] = picOf(a);
    ui.backend->onChange();
    spin(10);
    CHECK(wpe_test_art_model(ui.c).slot(art::FrontCover).state() == art::State::Present);
    NSTableView* t = wpe_test_art_table(ui.c);
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    ui.backspace();
    ui.backend->art[0].pictures[art::BackCover] = picOf(a);
    ui.backend->onChange();
    spin(10);
    CHECK(wpe_test_art_model(ui.c).slot(art::FrontCover).isPending());  // staged edits are kept
    CHECK(wpe_test_art_model(ui.c).slot(art::BackCover).state() == art::State::Absent);
}


namespace {
// Stages a TITLE edit and a pasted Front Cover (from `pp`) in a fresh window showing the Artwork page.
void stageTagAndCover(UI& ui, PrivatePasteboard& pp, NSData* cover) {
    wpe_test_set_pasteboard(ui.c, pp.pb);
    [pp.pb clearContents];
    [pp.pb setData:cover forType:NSPasteboardTypePNG];
    ui.select(ui.row("TITLE"));
    ui.type(@"new");
    ui.ret();
    ui.esc();
    wpe_test_select_tab(ui.c, 3);
    spin(10);
    NSTableView* t = wpe_test_art_table(ui.c);
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    ui.send(ui.key(@"v", 9, NSEventModifierFlagCommand));
}

}

TEST(artwork_edits_wait_for_a_running_reload) {
    NSData* front = makePNG(2, 2, NSColor.redColor);
    NSData* back = makePNG(3, 3, NSColor.blueColor);
    UI ui({tf({{"TITLE", {"x"}}})}, {artWith({})});
    PrivatePasteboard pp;
    wpe_test_set_pasteboard(ui.c, pp.pb);
    [pp.pb clearContents];
    [pp.pb setData:front forType:NSPasteboardTypePNG];
    wpe_test_select_tab(ui.c, 3);
    spin(10);
    NSTableView* t = wpe_test_art_table(ui.c);
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    ui.send(ui.key(@"v", 9, NSEventModifierFlagCommand));
    CHECK(wpe_test_art_model(ui.c).slot(art::FrontCover).isPending());

    // Apply writes the cover; the pictures are then read back from the files (held back here).
    ui.backend->deferArt = true;
    ui.action(@selector(applyPressed:));
    spin(20);
    CHECK_EQ(ui.backend->artWrites, 1);
    auto finish = ui.backend->finishArt;
    CHECK(finish != nullptr);
    CHECK(!wpe_test_art_model(ui.c).dirty());  // written: no longer pending
    CHECK(wpe_test_art_model(ui.c).slot(art::FrontCover).state() == art::State::Present);
    CHECK(!wpe_test_apply_enabled(ui.c));

    // While that read runs, nothing can be staged (it would be dropped when the read lands).
    [pp.pb clearContents];
    [pp.pb setData:back forType:NSPasteboardTypePNG];
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    ui.send(ui.key(@"v", 9, NSEventModifierFlagCommand));
    CHECK(!wpe_test_art_model(ui.c).dirty());
    CHECK([wpe_test_status(ui.c) containsString:@"reloaded"]);
    CHECK(!cellButton(t, 1, 1).enabled);  // "+" of the empty Back Cover
    CHECK(!cellButton(t, 3, 0).enabled);  // "×" of the Front Cover
    ui.backspace();
    CHECK(!wpe_test_art_model(ui.c).dirty());

    ui.backend->deferArt = false;
    if (finish) finish();
    spin(10);
    CHECK(wpe_test_art_model(ui.c).slot(art::FrontCover).state() == art::State::Present);
    CHECK(cellButton(t, 1, 1).enabled);
    ui.send(ui.key(@"v", 9, NSEventModifierFlagCommand));
    CHECK(wpe_test_art_model(ui.c).slot(art::BackCover).isPending());
    CHECK(wpe_test_apply_enabled(ui.c));
}

TEST(cancel_and_close_wait_for_a_running_write) {
    UI ui({tf({{"TITLE", {"x"}}})}, {artWith({})});
    PrivatePasteboard pp;
    stageTagAndCover(ui, pp, makePNG(2, 2, NSColor.redColor));
    CHECK(wpe_test_art_model(ui.c).dirty());
    const size_t before = wpe_open_window_count();
    ui.backend->deferWrite = true;
    ui.action(@selector(applyPressed:));
    CHECK(wpe_test_writing(ui.c));
    CHECK(![wpe_test_buttons(ui.c)[2] isEnabled]);  // Cancel
    ui.esc();
    ui.action(@selector(cancelPressed:));
    ui.send(ui.key(@"w", 13, NSEventModifierFlagCommand));
    spin();
    CHECK_EQ(wpe_open_window_count(), before);  // still open: the tags are being written
    CHECK_EQ(ui.backend->artWrites, 0);
    auto finish = ui.backend->finishWrite;
    CHECK(finish != nullptr);
    ui.backend->deferWrite = false;
    if (finish) finish();
    spin(20);
    CHECK_EQ(ui.backend->artWrites, 1);  // the picture follows the tags, as Apply promised
    CHECK(ui.backend->art[0].pictures[art::FrontCover] != nullptr);
    CHECK(!wpe_test_writing(ui.c));
    CHECK([wpe_test_buttons(ui.c)[2] isEnabled]);
    ui.esc();
    CHECK_EQ(wpe_open_window_count(), before - 1);
}

TEST(aborting_the_tag_write_does_not_write_pictures) {
    UI ui({tf({{"TITLE", {"x"}}})}, {artWith({})});
    PrivatePasteboard pp;
    stageTagAndCover(ui, pp, makePNG(2, 2, NSColor.redColor));
    ui.backend->abortNext = true;
    ui.action(@selector(applyPressed:));
    spin(20);
    CHECK_EQ(ui.backend->writes, 1);
    CHECK_EQ(ui.backend->artWrites, 0);  // no second rewrite of the files the user just stopped
    CHECK(wpe_test_art_model(ui.c).dirty());
    CHECK(ui.model().dirty());
    CHECK([wpe_test_status(ui.c) containsString:@"cancelled"]);
    CHECK([wpe_test_status(ui.c) containsString:@"pictures were not written"]);
    CHECK(wpe_test_apply_enabled(ui.c));
    ui.action(@selector(applyPressed:));  // retry: both parts
    spin(20);
    CHECK_EQ(ui.backend->writes, 2);
    CHECK_EQ(ui.backend->artWrites, 1);
    CHECK(!wpe_test_art_model(ui.c).dirty());
    CHECK_EQ(ui.backend->get(0, "TITLE"), Values{"new"});
}

TEST(a_file_whose_tags_and_picture_both_fail_counts_once) {
    UI ui({tf({{"TITLE", {"x"}}})}, {artWith({})});
    PrivatePasteboard pp;
    stageTagAndCover(ui, pp, makePNG(2, 2, NSColor.redColor));
    ui.backend->failNext = true;
    ui.backend->failNextArt = true;
    ui.action(@selector(applyPressed:));
    spin(20);
    CHECK_EQ(ui.backend->writes, 1);
    CHECK_EQ(ui.backend->artWrites, 1);
    CHECK([wpe_test_status(ui.c) hasPrefix:@"1 file could not be updated"]);
    CHECK(wpe_test_art_model(ui.c).dirty());
    CHECK(ui.model().dirty());
}

namespace {

std::string rgShown(const UI& ui, size_t field) { return wpe_test_rg_model(ui.c).display(field).text; }

std::vector<wpe::details::Entry> sampleDetails() {
    return {
        {"General", 1, "Items selected", "1"},
        {"Location", 0, "File name", "track.flac"},
        {"General", 2, "Duration", "3:25.000 (9 040 500 samples)"},
        {"Location", 1, "Folder name", "/music"},
        {"Playback statistics", 0, "Play count", "3"},
        {"General", 3, "Sample rate", "44100 Hz"},
    };
}

}

TEST(details_page_shows_the_providers_sections) {
    UI ui({tf({{"TITLE", {"t"}}})});
    ui.backend->details = sampleDetails();
    PrivatePasteboard pp;
    wpe_test_set_pasteboard(ui.c, pp.pb);
    CHECK_EQ(ui.backend->detailsLoads, 0);  // read only when the tab is first shown
    ui.send(ui.key(@"2", 19, NSEventModifierFlagCommand));
    NSTableView* t = wpe_test_details_table(ui.c);
    CHECK_EQ(ui.backend->detailsLoads, 1);
    CHECK(ui.w.firstResponder == t);
    CHECK(!t.enclosingScrollView.hidden);
    CHECK([[t.tableColumns[0] title] isEqualToString:@"Name"]);
    CHECK([[t.tableColumns[1] title] isEqualToString:@"Value"]);
    CHECK_EQ(t.rowHeight, CGFloat(21));
    const auto& lines = wpe_test_details(ui.c);
    CHECK_EQ(lines.size(), size_t(9));
    CHECK_EQ((NSInteger)t.numberOfRows, NSInteger(9));
    // Location, General, then the other sections by name; each header is a full-width band in the Mac
    // group-row style (11 pt semibold, secondary label colour) that floats while its lines scroll.
    CHECK(lines[0].header && lines[0].name == "Location");
    CHECK(lines[3].header && lines[3].name == "General");
    CHECK(lines[7].header && lines[7].name == "Playback statistics");
    CHECK([t.delegate tableView:t isGroupRow:0]);
    CHECK(![t.delegate tableView:t isGroupRow:1]);
    [t layoutSubtreeIfNeeded];
    NSTableCellView* header = [t viewAtColumn:0 row:0 makeIfNecessary:YES];
    CHECK_EQ(str(header.textField.stringValue), std::string("Location"));
    CHECK_EQ(header.textField.font.pointSize, wpe::ui::kGroupFontSize);
    CHECK([header.textField.font isEqual:WPEGroupFont()]);
    CHECK([header.textField.textColor isEqual:NSColor.secondaryLabelColor]);
    CHECK(t.floatsGroupRows);
    CHECK([[[t rowViewAtRow:0 makeIfNecessary:YES] valueForKey:@"wpeBand"] boolValue]);
    CHECK(![[[t rowViewAtRow:1 makeIfNecessary:YES] valueForKey:@"wpeBand"] boolValue]);
    CHECK_EQ(cellText(t, 0, 1), std::string("File name"));
    CHECK_EQ(cellText(t, 1, 1), std::string("track.flac"));
    CHECK_EQ(cellText(t, 1, 5), std::string("3:25.000 (9 040 500 samples)"));
    // Headers cannot be selected; Command-A selects every line, Command-C copies "Name: Value".
    ui.send(ui.key(@"a", 0, NSEventModifierFlagCommand));
    CHECK_EQ(t.numberOfSelectedRows, NSInteger(6));
    CHECK(![t isRowSelected:0]);
    ui.send(ui.key(@"c", 8, NSEventModifierFlagCommand));
    CHECK_EQ(str([pp.pb stringForType:NSPasteboardTypeString]),
             std::string("File name: track.flac\nFolder name: /music\nItems selected: 1\nDuration: 3:25.000 (9 040 500 "
                         "samples)\nSample rate: 44100 Hz\nPlay count: 3\n"));
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:8] byExtendingSelection:NO];
    ui.send(ui.key(@"c", 8, NSEventModifierFlagCommand));
    CHECK_EQ(str([pp.pb stringForType:NSPasteboardTypeString]), std::string("Play count: 3\n"));
    CHECK_EQ(titles(wpe_test_details_menu(ui.c)), (std::vector<std::string>{"Copy", "Select All"}));
    // Typing does nothing here (read-only), Escape closes the window like everywhere else.
    ui.type(@"x");
    CHECK(!ui.model().dirty());
    const size_t before = wpe_open_window_count();
    ui.esc();
    CHECK_EQ(wpe_open_window_count(), before - 1);
}

TEST(details_page_refreshes_when_the_tracks_change) {
    UI ui({tf({{"TITLE", {"t"}}})});
    ui.backend->details = sampleDetails();
    wpe_test_select_tab(ui.c, 1);
    spin();
    NSTableView* t = wpe_test_details_table(ui.c);
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:8] byExtendingSelection:NO];
    // Playback statistics change without a tag change (a metadb display hook).
    ui.backend->details[4].value = "4";  // Play count
    ui.backend->onDisplayChange();
    ui.backend->onDisplayChange();  // coalesced
    spin();
    CHECK_EQ(ui.backend->detailsLoads, 2);
    CHECK_EQ(wpe_test_details(ui.c).back().value, std::string("4"));
    CHECK_EQ(t.selectedRow, NSInteger(8));  // the selection is kept
    // A tag change refreshes it too; while another tab is showing, it is read when shown again.
    wpe_test_select_tab(ui.c, 0);
    ui.backend->details[0].value = "2";
    ui.backend->onChange();
    spin();
    CHECK_EQ(ui.backend->detailsLoads, 2);
    wpe_test_select_tab(ui.c, 1);
    spin();
    CHECK_EQ(ui.backend->detailsLoads, 3);
    CHECK_EQ(cellText(t, 1, 4), std::string("2"));
    // A refresh requested while one is still loading runs after it.
    ui.backend->deferDetails = true;
    ui.backend->onDisplayChange();
    spin();
    CHECK_EQ(str(wpe_test_status(ui.c)), std::string("Reading details…"));
    CHECK(wpe_test_status_busy(ui.c));
    ui.backend->onDisplayChange();
    spin();
    CHECK_EQ(ui.backend->detailsLoads, 4);
    ui.backend->deferDetails = false;
    ui.backend->finishDetails();
    spin();
    CHECK_EQ(ui.backend->detailsLoads, 5);
    CHECK_EQ(str(wpe_test_status(ui.c)), std::string(""));
    CHECK(!wpe_test_status_busy(ui.c));
}

TEST(replaygain_page_rows_and_values) {
    UI ui({tf({{"TITLE", {"a"}}}), tf({{"TITLE", {"b"}}})});
    ui.backend->rg = {gains(-6.54f, 0.987654f, -7.0f), gains(-6.54f, 0.5f, -7.0f)};
    ui.backend->onChange();  // reload with the ReplayGain values
    spin();
    ui.send(ui.key(@"3", 20, NSEventModifierFlagCommand));
    NSTableView* t = wpe_test_rg_table(ui.c);
    CHECK(ui.w.firstResponder == t);
    CHECK_EQ((NSInteger)t.numberOfRows, NSInteger(4));
    CHECK([[t.tableColumns[0] title] isEqualToString:@"Name"]);
    CHECK([[t.tableColumns[1] title] isEqualToString:@"Value"]);
    std::vector<std::string> names;
    for (NSInteger r = 0; r < 4; ++r) names.push_back(cellText(t, 0, r));
    CHECK_EQ(names, (std::vector<std::string>{"Track Gain", "Track Peak", "Album Gain", "Album Peak"}));
    CHECK_EQ(cellText(t, 1, 0), std::string("-6.54 dB"));
    CHECK_EQ(cellText(t, 1, 1), std::string("\xC2\xAB" "multiple values" "\xC2\xBB 0.987654; 0.500000"));
    CHECK([cellAt(t, 1, 1).textField.textColor isEqual:NSColor.secondaryLabelColor]);
    CHECK_EQ(cellText(t, 1, 2), std::string("-7.00 dB"));
    CHECK_EQ(cellText(t, 1, 3), std::string(""));
    CHECK(![[[t rowViewAtRow:0 makeIfNecessary:YES] valueForKey:@"wpeShaded"] boolValue]);
    CHECK([[[t rowViewAtRow:1 makeIfNecessary:YES] valueForKey:@"wpeShaded"] boolValue]);
    CHECK_EQ(titles(wpe_test_rg_menu(ui.c)), (std::vector<std::string>{"Edit", "Clear", "-", "Copy"}));
}

TEST(replaygain_inline_editing_return_tab_and_apply) {
    UI ui({tf({{"TITLE", {"a"}}}), tf({{"TITLE", {"b"}}})});
    ui.backend->rg = {gains(-6.54f, 0.98f), gains(-6.54f, 0.5f)};
    ui.backend->onChange();
    spin();
    wpe_test_select_tab(ui.c, 2);
    NSTableView* t = wpe_test_rg_table(ui.c);
    clickCell(ui, t, 0, 1);  // a single click edits the value at once
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(0));
    CHECK_EQ(str(wpe_test_rg_editor_text(ui.c)), std::string("-6.54 dB"));
    ui.type(@"+1,2");
    ui.ret();
    CHECK_EQ(rgShown(ui, rg::TrackGain), std::string("+1.20 dB"));
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(1));  // Return moves on
    CHECK_EQ(str(wpe_test_rg_editor_text(ui.c)), std::string("0.980000; 0.500000"));
    ui.tab();  // «multiple values» left alone: each track keeps its own peak
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(2));
    ui.backtab();
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(1));
    ui.up();
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(0));
    ui.up();  // arrows do not wrap
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(0));
    ui.ret(NSEventModifierFlagShift);  // Shift+Return goes back, wrapping
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(3));
    ui.type(@"0.75");
    ui.esc();  // cancels this edit only
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(-1));
    CHECK_EQ(rgShown(ui, rg::AlbumPeak), std::string(""));
    CHECK(wpe_test_apply_enabled(ui.c));
    CHECK(ui.w.firstResponder == t);
    // Typing on the list replaces the selected value.
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
    ui.type(@"-8");
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(2));
    CHECK_EQ(str(wpe_test_rg_editor_text(ui.c)), std::string("-8"));
    [NSApp sendAction:@selector(applyPressed:) to:ui.c from:nil];  // Apply commits the open edit
    spin(10);
    CHECK_EQ(ui.backend->writes, 1);
    CHECK_EQ(ui.backend->written, (std::vector<size_t>{0, 1}));
    CHECK(ui.backend->lastPlan.ops.empty());  // ReplayGain only: no tag changes
    CHECK(ui.backend->rg[0] == gains(1.2f, 0.98f, -8.0f));
    CHECK(ui.backend->rg[1] == gains(1.2f, 0.5f, -8.0f));
    CHECK(!wpe_test_rg_model(ui.c).dirty());
    CHECK(!wpe_test_apply_enabled(ui.c));
    CHECK_EQ(str(wpe_test_status(ui.c)), std::string("Updated 2 files."));
}

TEST(replaygain_invalid_text_keeps_the_editor_and_nothing_changes) {
    UI ui({tf({{"TITLE", {"a"}}})});
    ui.backend->rg = {gains(-6.54f, 0.98f)};
    ui.backend->onChange();
    spin();
    wpe_test_select_tab(ui.c, 2);
    NSTableView* t = wpe_test_rg_table(ui.c);
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    ui.ret();
    ui.type(@"-0.5");
    ui.ret();
    CHECK(str(wpe_test_status(ui.c)).find("not a valid peak") != std::string::npos);
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(1));  // still on the same row, with the typed text
    CHECK_EQ(str(wpe_test_rg_editor_text(ui.c)), std::string("-0.5"));
    CHECK(!wpe_test_rg_model(ui.c).dirty());
    // OK with an invalid value open stays open and writes nothing.
    ui.send(ui.key(@"\r", 36, NSEventModifierFlagCommand));
    CHECK_EQ(ui.backend->writes, 0);
    CHECK_EQ(wpe_open_window_count() > 0, true);
    CHECK(str(wpe_test_status(ui.c)).find("not a valid peak") != std::string::npos);
    ui.ret();
    ui.esc();
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(-1));
    CHECK_EQ(rgShown(ui, rg::TrackPeak), std::string("0.980000"));
    CHECK(!wpe_test_rg_model(ui.c).dirty());
}

TEST(replaygain_delete_clears_and_ok_writes_with_tags) {
    UI ui({tf({{"TITLE", {"a"}}}), tf({{"TITLE", {"b"}}}), tf({{"TITLE", {"c"}}})});
    ui.backend->rg = {gains(-6.0f, 0.9f), gains(-5.0f, 0.8f), gains(std::nullopt)};
    ui.backend->onChange();
    spin();
    // A tag edit on track titles...
    ui.select(ui.row("TITLE"));
    ui.type(@"same");
    ui.ret();
    ui.esc();
    // ...and clearing Track Peak (Delete on the list) are written in one update.
    ui.send(ui.key(@"3", 20, NSEventModifierFlagCommand));
    NSTableView* t = wpe_test_rg_table(ui.c);
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    ui.backspace();
    CHECK_EQ(rgShown(ui, rg::TrackPeak), std::string(""));
    CHECK(wpe_test_rg_model(ui.c).dirty());
    ui.send(ui.key(@"\r", 36, NSEventModifierFlagCommand));
    spin(10);
    CHECK_EQ(ui.backend->writes, 1);
    CHECK_EQ(ui.backend->written, (std::vector<size_t>{0, 1, 2}));
    CHECK(!ui.backend->lastPlan.ops.empty());
    CHECK(ui.backend->lastPlan.rg.ops[rg::TrackPeak].touched);
    CHECK(!ui.backend->lastPlan.rg.ops[rg::TrackGain].touched);
    CHECK(ui.backend->rg[0] == gains(-6.0f));
    CHECK(ui.backend->rg[1] == gains(-5.0f));  // per-track gains kept
    CHECK(ui.backend->get(2, "TITLE") == Values{"same"});
}

TEST(replaygain_edits_survive_tab_switches_and_cancel_discards_them) {
    UI ui({tf({{"TITLE", {"a"}}})});
    ui.backend->rg = {gains(-6.0f)};
    ui.backend->onChange();
    spin();
    wpe_test_select_tab(ui.c, 2);
    NSTableView* t = wpe_test_rg_table(ui.c);
    clickCell(ui, t, 2, 1);
    ui.type(@"-9.5 dB");
    ui.send(ui.key(@"1", 18, NSEventModifierFlagCommand));  // switching tabs commits the edit
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(0));
    CHECK_EQ(rgShown(ui, rg::AlbumGain), std::string("-9.50 dB"));
    // A clean-window reload does not run while ReplayGain changes are staged.
    const int loads = ui.backend->loads;
    ui.backend->onChange();
    spin();
    CHECK_EQ(ui.backend->loads, loads);
    CHECK_EQ(rgShown(ui, rg::AlbumGain), std::string("-9.50 dB"));
    const size_t before = wpe_open_window_count();
    ui.esc();
    CHECK_EQ(wpe_open_window_count(), before - 1);
    CHECK_EQ(ui.backend->writes, 0);
    CHECK(ui.backend->rg[0] == gains(-6.0f));
}

TEST(replaygain_invalid_text_survives_tab_switches_clicks_and_ok) {
    UI ui({tf({{"TITLE", {"a"}}})});
    ui.backend->rg = {gains(-6.54f)};
    ui.backend->onChange();
    spin();
    wpe_test_select_tab(ui.c, 2);
    NSTableView* t = wpe_test_rg_table(ui.c);
    clickCell(ui, t, 0, 1);
    ui.type(@"abc");
    auto stillThere = [&](const char* what) {
        CHECK_EQ(wpe_test_tab(ui.c), NSInteger(2));
        CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(0));
        CHECK_EQ(str(wpe_test_rg_editor_text(ui.c)), std::string("abc"));
        CHECK(!wpe_test_rg_model(ui.c).dirty());
        if (wpe_test_rg_edit_row(ui.c) != 0) std::printf("  after %s\n", what);
    };
    ui.send(ui.key(@"2", 19, NSEventModifierFlagCommand));  // Command-2: Details
    stillThere("Command-2");
    ui.send(ui.key(@"\t", 48, NSEventModifierFlagControl));  // Control-Tab
    stillThere("Control-Tab");
    wpe_test_select_tab(ui.c, 0);
    spin();
    stillThere("selecting another tab");
    clickCell(ui, t, 2, 1);  // a click on another row
    stillThere("a click on another row");
    ui.action(@selector(pasteAllFields:));
    stillThere("Paste fields");
    ui.send(ui.key(@"\r", 36, NSEventModifierFlagCommand));  // OK
    spin();
    stillThere("OK");
    CHECK_EQ(ui.backend->writes, 0);
    CHECK(str(wpe_test_status(ui.c)).find("not a valid") != std::string::npos);
    ui.esc();  // cancels this edit only
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(-1));
    CHECK_EQ(rgShown(ui, rg::TrackGain), std::string("-6.54 dB"));
    ui.send(ui.key(@"2", 19, NSEventModifierFlagCommand));
    CHECK_EQ(wpe_test_tab(ui.c), NSInteger(1));
}

TEST(shift_command_v_is_paste_fields_only_on_the_metadata_list) {
    UI ui({tf({{"TITLE", {"a"}}})});
    PrivatePasteboard pp;
    wpe_test_set_pasteboard(ui.c, pp.pb);
    [pp.pb clearContents];
    [pp.pb setString:@"MOOD=happy" forType:NSPasteboardTypeString];
    NSEvent* shiftCmdV = ui.key(@"V", 9, NSEventModifierFlagCommand | NSEventModifierFlagShift, @"V");
    for (NSInteger tab : {1, 2, 3}) {
        wpe_test_select_tab(ui.c, tab);
        spin();
        ui.send(shiftCmdV);
        CHECK_EQ(wpe_test_tab(ui.c), tab);  // no jump to Metadata
        CHECK_EQ(ui.row("MOOD"), wpe::npos);
    }
    wpe_test_select_tab(ui.c, 0);
    spin();
    ui.send(shiftCmdV);
    CHECK(ui.row("MOOD") != wpe::npos);
}


// ---- Edit Value: several tracks, one row's value per track ----

namespace {

// The open Edit Value sheet of a window, driven like the window itself.
struct Sheet {
    id s = nil;
    NSWindow* w = nil;
    NSTableView* table = nil;

    explicit Sheet(const UI& ui) : s(wpe_test_value_sheet(ui.c)) {
        if (!s) return;
        w = wpe_test_sheet_window(s);
        table = wpe_test_sheet_table(s);
    }
    bool open() const { return s != nil; }
    const wpe::PerTrackEdit& model() const { return wpe_test_sheet_model(s); }
    NSInteger editRow() const { return wpe_test_sheet_edit_row(s); }
    bool editing() const { return editRow() >= 0; }
    std::string editor() const {
        NSString* t = wpe_test_sheet_editor_text(s);
        return t ? std::string(t.UTF8String) : std::string("<not editing>");
    }
    std::string value(NSInteger row) const { return cellText(table, 1, row); }
    std::string item(NSInteger row) const { return cellText(table, 0, row); }
    void select(size_t r) {
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:r] byExtendingSelection:NO];
        [w makeFirstResponder:table];
    }
    NSEvent* key(NSString* chars, unsigned short code, NSEventModifierFlags mods = 0) const {
        return [NSEvent keyEventWithType:NSEventTypeKeyDown
                                location:NSZeroPoint
                           modifierFlags:mods
                               timestamp:NSProcessInfo.processInfo.systemUptime
                            windowNumber:w.windowNumber
                                 context:nil
                              characters:chars
             charactersIgnoringModifiers:chars
                               isARepeat:NO
                                 keyCode:code];
    }
    void send(NSEvent* e, bool settle = true) {
        if (![w performKeyEquivalent:e]) [w sendEvent:e];
        if (settle) spin();
    }
    void ret(NSEventModifierFlags m = 0) { send(key(@"\r", 36, m)); }
    void tab() { send(key(@"\t", 48)); }
    void backtab() { send(key(@"\x19", 48, NSEventModifierFlagShift)); }
    void esc() { send(key(@"\x1b", 53)); }
    void backspace() { send(key(@"\x7f", 51)); }
    void up() { send(key(UI::fn(NSUpArrowFunctionKey), 126, NSEventModifierFlagFunction | NSEventModifierFlagNumericPad)); }
    void down() { send(key(UI::fn(NSDownArrowFunctionKey), 125, NSEventModifierFlagFunction | NSEventModifierFlagNumericPad)); }
    void f2() { send(key(UI::fn(NSF2FunctionKey), 120, NSEventModifierFlagFunction)); }
    void type(NSString* text) {
        for (NSUInteger i = 0; i < text.length; ++i) send(key([text substringWithRange:NSMakeRange(i, 1)], 0), false);
        spin();
    }
    void click(size_t r, NSInteger col, NSInteger count = 1) {
        [table layoutSubtreeIfNeeded];
        const NSRect cell = [table frameOfCellAtColumn:col row:(NSInteger)r];
        const NSPoint p = [table convertPoint:NSMakePoint(NSMidX(cell), NSMidY(cell)) toView:nil];
        auto mouse = [&](NSEventType type) {
            return [NSEvent mouseEventWithType:type
                                      location:p
                                 modifierFlags:0
                                     timestamp:NSProcessInfo.processInfo.systemUptime
                                  windowNumber:w.windowNumber
                                       context:nil
                                   eventNumber:0
                                    clickCount:count
                                      pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
        };
        [NSApp postEvent:mouse(NSEventTypeLeftMouseUp) atStart:NO];
        [table mouseDown:mouse(NSEventTypeLeftMouseDown)];
        spin();
        while (NSEvent* e = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES])
            (void)e;
    }
    void ok() {
        [wpe_test_sheet_buttons(s)[0] performClick:nil];
        spin();
    }
    void cancel() {
        [wpe_test_sheet_buttons(s)[1] performClick:nil];
        spin();
    }
};

// Right-clicks a Metadata row and returns the context menu (validated as AppKit would before showing it).
NSMenu* rightClickRow(UI& ui, size_t row) {
    const NSRect cell = [ui.table frameOfCellAtColumn:0 row:(NSInteger)row];
    const NSPoint p = [ui.table convertPoint:NSMakePoint(NSMidX(cell), NSMidY(cell)) toView:nil];
    NSMenu* m = [ui.table menuForEvent:ui.mouse(NSEventTypeRightMouseDown, p, 1)];
    [m update];
    spin();
    return m;
}

NSMenuItem* itemTitled(NSMenu* m, NSString* title) {
    for (NSMenuItem* i in m.itemArray)
        if ([i.title isEqualToString:title]) return i;
    return nil;
}

std::vector<TrackFields> fiveArtists() {
    std::vector<TrackFields> out;
    const char* artists[] = {"Alpha", "Bravo", "Charlie", "Delta", "Echo"};
    for (int i = 0; i < 5; ++i)
        out.push_back(tf({{"ARTIST", {artists[i]}}, {"TITLE", {"Song " + std::to_string(i + 1)}}, {"ALBUM", {"Same"}}}));
    return out;
}

}

TEST(double_click_on_a_name_with_several_tracks_opens_edit_value) {
    UI ui({tf({{"ARTIST", {"A"}}, {"MOOD", {"calm"}}}), tf({{"ARTIST", {"B", "C"}}}), tf({{"TITLE", {"t"}}})});
    const size_t artist = ui.row("ARTIST");
    ui.click(artist, 0, 2);
    CHECK(!ui.editing());  // no rename with several tracks
    Sheet sh(ui);
    CHECK(sh.open());
    if (!sh.open()) return;
    CHECK_EQ(str(wpe_test_sheet_heading(sh.s)), std::string("Edit Value : Artist Name"));
    CHECK_EQ(str(sh.w.title), std::string("Edit Value : Artist Name"));
    CHECK(!sh.w.visible);  // the window is off screen, so the sheet is too
    CHECK_EQ(wpe_test_sheet_page(sh.s), NSInteger(1));  // Per-track
    CHECK(sh.w.firstResponder == sh.table);
    CHECK_EQ(sh.table.numberOfRows, NSInteger(3));
    CHECK_EQ(str(sh.table.tableColumns[0].title), std::string("Item"));
    CHECK_EQ(str(sh.table.tableColumns[1].title), std::string("Value"));
    // Track names fall back to the file name; values are joined like the list joins them.
    CHECK_EQ(sh.item(0), std::string("track0.flac"));
    CHECK_EQ(sh.item(2), std::string("track2.flac"));
    CHECK_EQ(sh.value(0), std::string("A"));
    CHECK_EQ(sh.value(1), std::string("B; C"));
    CHECK_EQ(sh.value(2), std::string(""));
    CHECK_EQ(str(wpe_test_sheet_hint(sh.s)), std::string("Delimit multiple values with ;"));
    CHECK_EQ(ui.table.selectedRow, NSInteger(artist));
    sh.esc();  // nothing being edited: Escape is Cancel
    CHECK(wpe_test_value_sheet(ui.c) == nil);
    CHECK(!ui.model().dirty());
    CHECK_EQ(ui.model().row(artist).field, std::string("ARTIST"));
    CHECK(ui.w.firstResponder == ui.table);

    // A custom field: its bracketed name, and no multi-value hint.
    ui.backend->titles = {"First", "Second", "Third"};
    ui.click(ui.row("MOOD"), 0, 2);
    Sheet mood(ui);
    CHECK(mood.open());
    if (!mood.open()) return;
    CHECK_EQ(str(wpe_test_sheet_heading(mood.s)), std::string("Edit Value : <MOOD>"));
    CHECK(wpe_test_sheet_hint(mood.s) == nil);
    CHECK_EQ(mood.item(1), std::string("Second"));
    CHECK_EQ(mood.value(0), std::string("calm"));
    mood.cancel();
    CHECK(wpe_test_value_sheet(ui.c) == nil);
}

TEST(double_click_on_a_name_with_one_track_still_renames) {
    UI ui({tf({{"MOOD", {"calm"}}})});
    ui.click(ui.row("MOOD"), 0, 2);
    CHECK(wpe_test_value_sheet(ui.c) == nil);
    CHECK_EQ(ui.editCol(), NSInteger(0));
    ui.esc();
}

TEST(edit_value_edits_like_the_metadata_list) {
    UI ui({tf({{"MOOD", {"a"}}}), tf({{"MOOD", {"b"}}}), tf({{"MOOD", {"c"}}})});
    ui.click(ui.row("MOOD"), 0, 2);
    Sheet sh(ui);
    CHECK(sh.open());
    if (!sh.open()) return;
    sh.click(1, 1);  // a single click on a value edits it, text selected
    CHECK_EQ(sh.editRow(), NSInteger(1));
    CHECK_EQ(sh.editor(), std::string("b"));
    sh.type(@"x");
    CHECK_EQ(sh.editor(), std::string("x"));
    sh.ret();  // commit, next track
    CHECK_EQ(sh.editRow(), NSInteger(2));
    CHECK_EQ(sh.editor(), std::string("c"));
    CHECK_EQ(sh.value(1), std::string("x"));
    sh.tab();  // wraps to the first track
    CHECK_EQ(sh.editRow(), NSInteger(0));
    sh.backtab();  // Shift-Tab goes back, wrapping
    CHECK_EQ(sh.editRow(), NSInteger(2));
    sh.ret(NSEventModifierFlagShift);
    CHECK_EQ(sh.editRow(), NSInteger(1));
    CHECK_EQ(sh.editor(), std::string("x"));
    sh.up();  // arrows commit and move without wrapping
    CHECK_EQ(sh.editRow(), NSInteger(0));
    sh.up();
    CHECK_EQ(sh.editRow(), NSInteger(0));
    sh.type(@"zzz");
    sh.esc();  // Escape cancels this edit only
    CHECK(!sh.editing());
    CHECK(wpe_test_value_sheet(ui.c) != nil);
    CHECK_EQ(sh.model().text(0), std::string("a"));
    CHECK(sh.w.firstResponder == sh.table);

    sh.click(2, 0);  // a click on a track's name does not edit (AppKit's own tracking selects it)
    CHECK(!sh.editing());
    sh.select(2);
    sh.type(@"q");  // typing on the list replaces the selected track's value
    CHECK_EQ(sh.editRow(), NSInteger(2));
    CHECK_EQ(sh.editor(), std::string("q"));
    sh.ret();
    sh.esc();
    CHECK_EQ(sh.model().text(2), std::string("q"));
    sh.select(0);
    sh.f2();
    CHECK_EQ(sh.editRow(), NSInteger(0));
    sh.esc();
    sh.ret();  // Return on the list edits too
    CHECK_EQ(sh.editRow(), NSInteger(0));
    sh.esc();
    CHECK_EQ(sh.model().changedTracks(), (std::vector<size_t>{1, 2}));
    CHECK(!ui.model().dirty());  // nothing reaches the window before OK
    sh.ok();
    CHECK(wpe_test_value_sheet(ui.c) == nil);
    CHECK_EQ(ui.shown("MOOD"), std::string(wpe::kMultipleValues) + " a; x; q");
}

TEST(edit_value_keys_typed_before_the_next_editor_opens_are_not_lost) {
    UI ui({tf({{"MOOD", {"a"}}}), tf({{"MOOD", {"b"}}})});
    ui.click(ui.row("MOOD"), 0, 2);
    Sheet sh(ui);
    if (!sh.open()) {
        CHECK(sh.open());
        return;
    }
    sh.click(0, 1);
    sh.send(sh.key(@"\t", 48), false);
    sh.send(sh.key(@"q", 12), false);
    spin();
    CHECK_EQ(sh.editRow(), NSInteger(1));
    CHECK_EQ(sh.editor(), std::string("q"));
    sh.esc();
    sh.cancel();
}

TEST(edit_value_ok_stages_and_only_changed_tracks_are_written) {
    UI ui(fiveArtists());
    const size_t artist = ui.row("ARTIST");
    ui.click(artist, 0, 2);
    Sheet sh(ui);
    CHECK(sh.open());
    if (!sh.open()) return;
    sh.click(1, 1);
    sh.type(@"X; Y");  // a multi-value field: split per track
    sh.ret();
    CHECK_EQ(sh.editRow(), NSInteger(2));
    sh.backspace();  // the selected text goes: cleared
    sh.ret();
    sh.esc();
    sh.ok();
    CHECK(wpe_test_value_sheet(ui.c) == nil);
    CHECK(ui.model().dirty());
    CHECK(wpe_test_apply_enabled(ui.c));
    CHECK(ui.model().display(artist).mixed);
    CHECK_EQ(ui.shown("ARTIST"), std::string(wpe::kMultipleValues) + " Alpha; X; Y; Delta; Echo");
    CHECK_EQ(ui.backend->writes, 0);  // staged only
    CHECK_EQ(ui.table.selectedRow, NSInteger(artist));

    ui.action(@selector(applyPressed:));
    CHECK_EQ(ui.backend->writes, 1);
    CHECK_EQ(ui.backend->written, (std::vector<size_t>{1, 2}));  // untouched tracks are not rewritten
    CHECK_EQ(ui.backend->lastPlan.ops.size(), size_t(1));
    CHECK_EQ(ui.backend->lastPlan.ops[0].to, std::string("ARTIST"));
    CHECK(ui.backend->lastPlan.ops[0].perTrack);
    CHECK_EQ(ui.backend->get(0, "ARTIST"), Values{"Alpha"});
    CHECK_EQ(ui.backend->get(1, "ARTIST"), (Values{"X", "Y"}));
    CHECK_EQ(ui.backend->get(2, "ARTIST"), Values{});  // removed on that track only
    CHECK_EQ(ui.backend->get(2, "TITLE"), Values{"Song 3"});
    CHECK_EQ(ui.backend->get(3, "ARTIST"), Values{"Delta"});
    CHECK(!ui.model().dirty());
}

TEST(edit_value_does_not_revert_outside_changes_on_untouched_tracks) {
    // Every track is written because of TITLE; ARTIST changed elsewhere on track 4 while the window was
    // dirty (that reload is dropped). Editing only track 2's ARTIST must not put "Delta" back on track 4.
    UI ui(fiveArtists());
    CHECK(ui.backend->tracks.size() == 5);
    ui.click(ui.row("TITLE"), 1);
    CHECK(ui.editing());
    ui.type(@"Same title");
    ui.ret();
    ui.esc();
    spin();
    CHECK(ui.model().dirty());
    CHECK_EQ(ui.shown("TITLE"), std::string("Same title"));
    ui.backend->tracks[3] = tf({{"ARTIST", {"Delta Band"}}, {"TITLE", {"Song 4"}}, {"ALBUM", {"Same"}}});
    ui.backend->onChange();
    spin();
    CHECK_EQ(ui.shown("TITLE"), std::string("Same title"));  // the staged edit survives the change

    const size_t artist = ui.row("ARTIST");
    ui.click(artist, 0, 2);
    Sheet sh(ui);
    CHECK(sh.open());
    if (!sh.open()) return;
    CHECK_EQ(sh.value(3), std::string("Delta"));  // the window's snapshot
    sh.click(1, 1);
    sh.type(@"Bravo 2");
    sh.ret();
    sh.esc();
    sh.ok();
    ui.action(@selector(applyPressed:));
    CHECK_EQ(ui.backend->writes, 1);
    CHECK_EQ(ui.backend->written, (std::vector<size_t>{0, 1, 2, 3, 4}));
    CHECK_EQ(ui.backend->get(1, "ARTIST"), Values{"Bravo 2"});
    CHECK_EQ(ui.backend->get(3, "ARTIST"), Values{"Delta Band"});  // not reverted
    CHECK_EQ(ui.backend->get(3, "TITLE"), Values{"Same title"});
    CHECK_EQ(ui.backend->get(0, "ARTIST"), Values{"Alpha"});
    CHECK_EQ(ui.backend->get(4, "TITLE"), Values{"Same title"});
}

TEST(edit_value_cancel_and_escape_discard) {
    UI ui({tf({{"MOOD", {"a"}}}), tf({{"MOOD", {"b"}}})});
    ui.click(ui.row("MOOD"), 0, 2);
    Sheet sh(ui);
    CHECK(sh.open());
    if (!sh.open()) return;
    sh.click(0, 1);
    sh.type(@"changed");
    sh.ret();
    sh.cancel();
    CHECK(wpe_test_value_sheet(ui.c) == nil);
    CHECK(!ui.model().dirty());
    CHECK(!wpe_test_apply_enabled(ui.c));

    ui.click(ui.row("MOOD"), 0, 2);
    Sheet again(ui);
    CHECK(again.open());
    if (!again.open()) return;
    CHECK_EQ(again.value(0), std::string("a"));  // the cancelled text is gone
    again.click(1, 1);
    again.type(@"zz");
    again.esc();  // the edit
    again.esc();  // the sheet
    CHECK(wpe_test_value_sheet(ui.c) == nil);
    CHECK(!ui.model().dirty());
    const size_t windows = wpe_open_window_count();
    CHECK(windows > 0);
    ui.click(ui.row("MOOD"), 0, 2);
    Sheet third(ui);
    if (!third.open()) return;
    third.send(third.key(@".", 47, NSEventModifierFlagCommand));  // Command-period is Cancel too
    CHECK(wpe_test_value_sheet(ui.c) == nil);
    CHECK_EQ(wpe_open_window_count(), windows);  // the window stays
    CHECK_EQ(ui.backend->writes, 0);
}

TEST(edit_value_command_return_commits_the_open_edit_and_is_ok) {
    UI ui({tf({{"MOOD", {"a"}}}), tf({{"MOOD", {"b"}}})});
    const size_t before = wpe_open_window_count();
    ui.click(ui.row("MOOD"), 0, 2);
    Sheet sh(ui);
    if (!sh.open()) {
        CHECK(sh.open());
        return;
    }
    sh.click(1, 1);
    sh.type(@"new");
    sh.ret(NSEventModifierFlagCommand);
    CHECK(wpe_test_value_sheet(ui.c) == nil);
    CHECK_EQ(ui.shown("MOOD"), std::string(wpe::kMultipleValues) + " a; new");
    CHECK_EQ(wpe_open_window_count(), before);  // the Properties window stays: OK/Apply there writes
    ui.ret(NSEventModifierFlagCommand);
    CHECK_EQ(ui.backend->written, std::vector<size_t>{1});
    CHECK_EQ(ui.backend->get(1, "MOOD"), Values{"new"});
    CHECK_EQ(ui.backend->get(0, "MOOD"), Values{"a"});
}

TEST(edit_value_common_value_page) {
    UI ui({tf({{"DATE", {"1999"}}}), tf({{"DATE", {"2001"}}}), tf({})});
    ui.click(ui.row("DATE"), 0, 2);
    Sheet sh(ui);
    if (!sh.open()) {
        CHECK(sh.open());
        return;
    }
    sh.send(sh.key(@"\t", 48, NSEventModifierFlagControl));  // Control-Tab: Common value
    CHECK_EQ(wpe_test_sheet_page(sh.s), NSInteger(0));
    NSTextView* common = wpe_test_sheet_common_editor(sh.s);
    CHECK_EQ(str(common.string), std::string(wpe::kDifferentValues));
    CHECK(sh.w.firstResponder == common);
    sh.send(sh.key(@"2", 19, NSEventModifierFlagCommand));  // Command-2: Per-track, nothing changed
    CHECK_EQ(wpe_test_sheet_page(sh.s), NSInteger(1));
    CHECK(!sh.model().dirty());
    sh.send(sh.key(@"1", 18, NSEventModifierFlagCommand));
    [common selectAll:nil];
    sh.type(@"2024");
    CHECK_EQ(str(common.string), std::string("2024"));
    sh.send(sh.key(@"\t", 48, NSEventModifierFlagControl));  // back to Per-track: every track gets it
    CHECK_EQ(sh.value(0), std::string("2024"));
    CHECK_EQ(sh.value(2), std::string("2024"));
    wpe_test_sheet_select_page(sh.s, 0);
    CHECK_EQ(str(common.string), std::string("2024"));
    sh.ret();  // Return on the Common value page is OK
    CHECK(wpe_test_value_sheet(ui.c) == nil);
    CHECK_EQ(ui.shown("DATE"), std::string("2024"));
    CHECK(!ui.model().display(ui.row("DATE")).mixed);
}

TEST(edit_value_multiline_values_and_delete_clears) {
    UI ui({tf({{"COMMENT", {"one"}}}), tf({{"COMMENT", {"two"}}}), tf({{"COMMENT", {"three"}}})});
    ui.click(ui.row("COMMENT"), 0, 2);
    Sheet sh(ui);
    if (!sh.open()) {
        CHECK(sh.open());
        return;
    }
    sh.click(0, 1);
    CHECK(wpe_test_sheet_multiline(sh.s));
    sh.type(@"l1");
    sh.ret(NSEventModifierFlagOption);
    sh.type(@"l2");
    CHECK_EQ(sh.editor(), std::string("l1\nl2"));
    sh.ret();
    CHECK_EQ(sh.editRow(), NSInteger(1));
    sh.esc();
    CHECK(!wpe_test_sheet_multiline(sh.s));
    CHECK_EQ(sh.model().text(0), std::string("l1\nl2"));
    CHECK_EQ(sh.value(0), std::string("l1 \xE2\x86\xB5 l2"));
    [sh.table selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)] byExtendingSelection:NO];
    [sh.w makeFirstResponder:sh.table];
    sh.backspace();  // Delete clears the selected tracks' values
    CHECK_EQ(sh.value(1), std::string(""));
    CHECK_EQ(sh.model().text(2), std::string(""));
    sh.ok();
    CHECK_EQ(ui.model().editText(ui.row("COMMENT")), std::string("l1\nl2"));
    ui.action(@selector(applyPressed:));
    CHECK_EQ(ui.backend->get(0, "COMMENT"), Values{"l1\nl2"});
    CHECK_EQ(ui.backend->get(1, "COMMENT"), Values{});
    CHECK_EQ(ui.backend->get(2, "COMMENT"), Values{});
}

TEST(edit_value_and_rename_in_the_context_menu_with_several_tracks) {
    UI ui({tf({{"ARTIST", {"A"}}, {"MOOD", {"a"}}}), tf({{"ARTIST", {"B"}}, {"MOOD", {"b"}}})});
    CHECK_EQ(titles(wpe_test_menu(ui.c)),
             (std::vector<std::string>{"Edit", "Edit values per track\xE2\x80\xA6", "Rename", "Add New Field", "Remove", "-",
                                       "Copy", "Paste", "-", "Capitalize", "Auto Track Number"}));
    NSMenu* m = rightClickRow(ui, ui.row("ARTIST"));
    NSMenuItem* perTrack = itemTitled(m, @"Edit values per track\xE2\x80\xA6");
    NSMenuItem* rename = itemTitled(m, @"Rename");
    CHECK(perTrack && rename);
    if (!perTrack || !rename) return;
    CHECK([ui.c validateMenuItem:perTrack]);
    CHECK(![ui.c validateMenuItem:rename]);  // standard fields are labels
    // The right-clicked row is the one edited, even with another row selected as well.
    [ui.table selectRowIndexes:[NSIndexSet indexSetWithIndex:ui.row("MOOD")] byExtendingSelection:YES];
    m = rightClickRow(ui, ui.row("MOOD"));
    CHECK([ui.c validateMenuItem:rename]);
    [NSApp sendAction:perTrack.action to:perTrack.target from:perTrack];
    spin();
    Sheet sh(ui);
    CHECK(sh.open());
    if (!sh.open()) return;
    CHECK_EQ(str(wpe_test_sheet_heading(sh.s)), std::string("Edit Value : <MOOD>"));
    sh.cancel();
    rightClickRow(ui, ui.row("MOOD"));
    [NSApp sendAction:rename.action to:rename.target from:rename];
    spin();
    CHECK_EQ(ui.editRow(), NSInteger(ui.row("MOOD")));
    CHECK_EQ(ui.editCol(), NSInteger(0));
    ui.type(@"feel");
    ui.ret();
    CHECK(ui.row("FEEL") != wpe::npos);
    ui.esc();
}

TEST(edit_value_defers_outside_reloads_and_closing_discards_it) {
    UI ui({tf({{"MOOD", {"a"}}}), tf({{"MOOD", {"b"}}})});
    ui.click(ui.row("MOOD"), 0, 2);
    CHECK(wpe_test_value_sheet(ui.c) != nil);
    const int loads = ui.backend->loads;
    ui.backend->tracks[0] = tf({{"MOOD", {"outside"}}});
    ui.backend->onChange();
    spin();
    CHECK_EQ(ui.backend->loads, loads);  // not under an open sheet
    ui.action(@selector(applyPressed:));  // the sheet is modal: nothing is written meanwhile
    CHECK_EQ(ui.backend->writes, 0);
    Sheet sh(ui);
    if (!sh.open()) return;
    sh.cancel();
    spin();
    CHECK_EQ(ui.backend->loads, loads + 1);  // picked up once the sheet is gone (the window is clean)
    CHECK_EQ(ui.shown("MOOD"), std::string(wpe::kMultipleValues) + " outside; b");

    ui.click(ui.row("MOOD"), 0, 2);
    CHECK(wpe_test_value_sheet(ui.c) != nil);
    const size_t before = wpe_open_window_count();
    [ui.w close];  // closing the window drops the sheet with it
    spin();
    CHECK(wpe_test_value_sheet(ui.c) == nil);
    CHECK_EQ(wpe_open_window_count(), before - 1);
    CHECK_EQ(ui.backend->writes, 0);
}

#pragma mark - Asking before unapplied changes are lost

namespace {

// Stages TITLE = `text` on the Metadata list (the editor closed again).
void stageTitle(UI& ui, NSString* text) {
    ui.select(ui.row("TITLE"));
    ui.type(text);
    ui.ret();
    ui.esc();
}

void commandW(UI& ui) {
    ui.send(ui.key(@"w", 13, NSEventModifierFlagCommand));
}

std::vector<std::string> buttonTitles(NSAlert* a) {
    std::vector<std::string> out;
    for (NSButton* b in a.buttons) out.push_back(str(b.title));
    return out;
}

constexpr NSModalResponse kApply = NSAlertFirstButtonReturn;
constexpr NSModalResponse kKeepEditing = NSAlertSecondButtonReturn;
constexpr NSModalResponse kDontApply = NSAlertThirdButtonReturn;

// Runs this test binary again as a quit probe (WPE_QUIT_PROBE=mode, see runQuitProbe) and returns what it
// printed. It inherits the environment (CFFIXED_USER_HOME included) and is stopped after 20 s.
std::string runSelf(const char* mode, int* status) {
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:NSBundle.mainBundle.executablePath];
    NSMutableDictionary<NSString*, NSString*>* env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"WPE_QUIT_PROBE"] = @(mode);
    [env removeObjectForKey:@"WPE_SNAPSHOT_DIR"];
    [env removeObjectForKey:@"WPE_TEST_ONLY"];
    task.environment = env;
    NSPipe* pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) {
        *status = -2;
        return "launch failed";
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        if (task.running) [task terminate];
    });
    NSData* data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    *status = task.terminationStatus;
    return std::string(static_cast<const char*>(data.bytes), data.length);
}

// The child side: a window with a staged edit, the quit guard registered, and -[NSApplication terminate:].
// The prompt (never shown: the window is off screen) is answered from a timer, which also fires while
// terminate: waits in its modal run loop. A quit that goes on ends the process inside terminate:.
int runQuitProbe(const char* mode) {
    const NSModalResponse answer =
        !std::strcmp(mode, "apply") ? kApply : !std::strcmp(mode, "discard") ? kDontApply : kKeepEditing;
    UI* ui = new UI({tf({{"TITLE", {"x"}}})});  // never destroyed: the process may end in terminate:
    stageTitle(*ui, @"new");
    NSDocument* guard = wpe_test_install_quit_guard();
    std::printf("guard edited=%d\n", (int)guard.documentEdited);
    std::fflush(stdout);
    std::shared_ptr<MemoryBackend> backend = ui->backend;
    id c = ui->c;
    NSTimer* timer = [NSTimer timerWithTimeInterval:0.02
                                            repeats:YES
                                              block:^(NSTimer* t) {
                                                  NSAlert* prompt = wpe_test_close_prompt(c);
                                                  if (!prompt) return;
                                                  [t invalidate];
                                                  std::printf("asked: %s\n", prompt.informativeText.UTF8String);
                                                  std::fflush(stdout);
                                                  wpe_test_answer_close_prompt(c, answer);
                                              }];
    [NSRunLoop.currentRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationWillTerminateNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification*) {
                                                      const Values title = backend->get(0, "TITLE");
                                                      std::printf("terminated writes=%d title=%s\n", backend->writes,
                                                                  title.empty() ? "" : title[0].c_str());
                                                      std::fflush(stdout);
                                                  }];
    [NSApp terminate:nil];
    std::printf("terminate returned writes=%d open=%zu\n", backend->writes, wpe_open_window_count());
    std::fflush(stdout);
    for (int i = 0; i < 100; ++i) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);  // Apply: write, close, quit again
    std::printf("still running writes=%d\n", backend->writes);
    std::fflush(stdout);
    return 0;
}

}

// AppKit's document review answers through this (document:shouldClose:contextInfo:).
@interface WPETestCloseDelegate : NSObject
@property(copy) void (^done)(BOOL ok);
@end
@implementation WPETestCloseDelegate
- (void)document:(NSDocument*)document shouldClose:(BOOL)shouldClose contextInfo:(void*)contextInfo {
    (void)document;
    (void)contextInfo;
    if (self.done) self.done(shouldClose);
}
@end

TEST(close_button_and_command_w_ask_before_discarding_staged_edits) {
    UI ui({tf({{"TITLE", {"x"}}}), tf({{"TITLE", {"y"}}})});
    const size_t before = wpe_open_window_count();
    stageTitle(ui, @"new");
    CHECK(ui.model().dirty());
    CHECK(ui.w.documentEdited);  // the dot in the close button
    commandW(ui);
    NSAlert* a = wpe_test_close_prompt(ui.c);
    CHECK(a != nil);
    if (!a) return;
    CHECK_EQ(wpe_open_window_count(), before);
    CHECK_EQ(str(a.messageText), std::string("Do you want to apply the changes you made to 2 files?"));
    CHECK_EQ(str(a.informativeText), std::string("Your changes will be lost if you don\xE2\x80\x99t apply them."));
    CHECK_EQ(buttonTitles(a), (std::vector<std::string>{"Apply", "Cancel", "Don\xE2\x80\x99t Apply"}));
    if (a.buttons.count == 3) {
        CHECK_EQ(str(a.buttons[0].keyEquivalent), std::string("\r"));  // the default button
        CHECK_EQ(str(a.buttons[1].keyEquivalent), std::string("\033"));
        CHECK_EQ(str(a.buttons[2].keyEquivalent), std::string("d"));
        CHECK_EQ(a.buttons[2].keyEquivalentModifierMask, NSEventModifierFlagCommand);
    }
    // Asked once: closing again while asking does nothing.
    [ui.w performClose:nil];
    CHECK(wpe_test_close_prompt(ui.c) == a);
    // Cancel: back to the window, the edit still staged.
    wpe_test_answer_close_prompt(ui.c, kKeepEditing);
    spin();
    CHECK(wpe_test_close_prompt(ui.c) == nil);
    CHECK_EQ(wpe_open_window_count(), before);
    CHECK(ui.model().dirty());
    CHECK_EQ(ui.shown("TITLE"), std::string("new"));
    // The close button asks the same; Don't Apply closes without writing.
    [ui.w performClose:nil];
    CHECK(wpe_test_close_prompt(ui.c) != nil);
    wpe_test_answer_close_prompt(ui.c, kDontApply);
    spin();
    CHECK_EQ(wpe_open_window_count(), before - 1);
    CHECK_EQ(ui.backend->writes, 0);
    CHECK_EQ(ui.backend->get(0, "TITLE"), Values{"x"});

    // A clean window closes at once.
    UI clean({tf({{"TITLE", {"x"}}})});
    const size_t open = wpe_open_window_count();
    commandW(clean);
    CHECK(wpe_test_close_prompt(clean.c) == nil);
    CHECK_EQ(wpe_open_window_count(), open - 1);
}

TEST(apply_in_the_close_prompt_writes_and_a_failure_keeps_the_window) {
    {
        UI ui({tf({{"TITLE", {"x"}}})});
        const size_t before = wpe_open_window_count();
        stageTitle(ui, @"new");
        commandW(ui);
        CHECK(wpe_test_close_prompt(ui.c) != nil);
        CHECK_EQ(str(wpe_test_close_prompt(ui.c).messageText), std::string("Do you want to apply the changes you made to 1 file?"));
        wpe_test_answer_close_prompt(ui.c, kApply);
        spin(20);
        CHECK_EQ(ui.backend->writes, 1);
        CHECK_EQ(ui.backend->get(0, "TITLE"), Values{"new"});
        CHECK_EQ(wpe_open_window_count(), before - 1);
    }
    {
        // Pictures count too, and a failed write keeps the window and the edits, as OK does.
        NSData* front = makePNG(3, 3, NSColor.greenColor);
        UI ui({tf({{"TITLE", {"x"}}})}, {artWith({{art::FrontCover, picOf(front)}})});
        const size_t before = wpe_open_window_count();
        wpe_test_select_tab(ui.c, 3);
        spin(20);
        [cellButton(wpe_test_art_table(ui.c), 3, 0) performClick:nil];  // stage removing the Front Cover
        spin();
        CHECK(wpe_test_art_model(ui.c).dirty());
        commandW(ui);
        CHECK(wpe_test_close_prompt(ui.c) != nil);
        ui.backend->failNextArt = true;
        wpe_test_answer_close_prompt(ui.c, kApply);
        spin(20);
        CHECK_EQ(ui.backend->artWrites, 1);
        CHECK_EQ(wpe_open_window_count(), before);
        CHECK(wpe_test_art_model(ui.c).dirty());
        CHECK([wpe_test_status(ui.c) containsString:@"could not be updated"]);
    }
}

TEST(an_open_edit_is_committed_before_asking) {
    {
        // An editor whose text did not change: nothing to lose, the window closes.
        UI ui({tf({{"TITLE", {"x"}}})});
        const size_t before = wpe_open_window_count();
        ui.select(ui.row("TITLE"));
        ui.ret();
        CHECK(ui.editing());
        commandW(ui);
        CHECK(wpe_test_close_prompt(ui.c) == nil);
        CHECK_EQ(wpe_open_window_count(), before - 1);
    }
    {
        // Typed text is committed (as a click elsewhere commits it) and asked about.
        UI ui({tf({{"TITLE", {"x"}}})});
        const size_t before = wpe_open_window_count();
        ui.select(ui.row("TITLE"));
        ui.type(@"typed");
        CHECK(ui.editing());
        commandW(ui);
        CHECK(wpe_test_close_prompt(ui.c) != nil);
        CHECK(!ui.editing());
        CHECK_EQ(ui.shown("TITLE"), std::string("typed"));
        wpe_test_answer_close_prompt(ui.c, kDontApply);
        spin();
        CHECK_EQ(wpe_open_window_count(), before - 1);
        CHECK_EQ(ui.backend->writes, 0);
    }
    {
        // A ReplayGain value that does not parse is not lost silently either.
        UI ui({tf({{"TITLE", {"x"}}})});
        wpe_test_select_tab(ui.c, 2);
        spin();
        NSTableView* rgt = wpe_test_rg_table(ui.c);
        [rgt selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [ui.w makeFirstResponder:rgt];
        ui.type(@"loud");
        commandW(ui);
        CHECK(wpe_test_close_prompt(ui.c) != nil);
        wpe_test_answer_close_prompt(ui.c, kKeepEditing);
        spin();
        CHECK_EQ(str(wpe_test_rg_editor_text(ui.c)), std::string("loud"));  // back in its editor
    }
}

TEST(cancel_escape_and_command_period_still_discard_without_asking) {
    for (int how = 0; how < 3; ++how) {
        UI ui({tf({{"TITLE", {"x"}}})});
        const size_t before = wpe_open_window_count();
        stageTitle(ui, @"new");
        CHECK(ui.model().dirty());
        if (how == 0) ui.action(@selector(cancelPressed:));
        else if (how == 1) ui.esc();
        else ui.send(ui.key(@".", 47, NSEventModifierFlagCommand));
        CHECK(wpe_test_close_prompt(ui.c) == nil);
        CHECK_EQ(wpe_open_window_count(), before - 1);
        CHECK_EQ(ui.backend->writes, 0);
    }
}

// Quitting asks each window that has unapplied changes, in turn, with the window's own prompt. Cancel keeps
// foobar2000 running; Don't Apply closes that window and goes on; Apply writes, then asks to quit again.
TEST(quitting_asks_each_window_with_unapplied_changes) {
    __block int quits = 0;
    wpe_test_set_quit_again(^{
        ++quits;
    });
    UI a({tf({{"TITLE", {"a"}}})});
    UI b({tf({{"TITLE", {"b"}}})});
    UI c({tf({{"TITLE", {"c"}}})});
    stageTitle(a, @"a2");
    stageTitle(c, @"c2");
    const size_t before = wpe_open_window_count();
    __block int answer = -1;
    wpe_test_review_for_quit(^(bool ok) {
        answer = ok;
    });
    CHECK_EQ(answer, -1);  // waiting for the first window's answer
    CHECK(wpe_test_close_prompt(a.c) != nil);
    CHECK(wpe_test_close_prompt(b.c) == nil);
    CHECK(wpe_test_close_prompt(c.c) == nil);  // one at a time
    if (NSAlert* p = wpe_test_close_prompt(a.c))
        CHECK_EQ(str(p.informativeText), std::string("foobar2000 is quitting. Your changes will be lost if you don\xE2\x80\x99t apply them."));
    wpe_test_answer_close_prompt(a.c, kDontApply);
    spin();
    CHECK_EQ(wpe_open_window_count(), before - 1);
    CHECK_EQ(answer, -1);
    CHECK(wpe_test_close_prompt(c.c) != nil);  // then the next one
    wpe_test_answer_close_prompt(c.c, kKeepEditing);
    spin();
    CHECK_EQ(answer, 0);  // the quit is called off
    CHECK(c.model().dirty());
    CHECK_EQ(a.backend->writes + c.backend->writes, 0);

    // Again, with Apply: the quit is called off at once, the window writes and closes, and foobar2000 is
    // asked to quit again (the next review has nothing left to ask).
    answer = -1;
    wpe_test_review_for_quit(^(bool ok) {
        answer = ok;
    });
    CHECK(wpe_test_close_prompt(c.c) != nil);
    wpe_test_answer_close_prompt(c.c, kApply);
    CHECK_EQ(answer, 0);
    spin(20);
    CHECK_EQ(c.backend->writes, 1);
    CHECK_EQ(c.backend->get(0, "TITLE"), Values{"c2"});
    CHECK_EQ(wpe_open_window_count(), before - 2);
    CHECK_EQ(quits, 1);
    answer = -1;
    wpe_test_review_for_quit(^(bool ok) {
        answer = ok;
    });
    CHECK_EQ(answer, 1);
    CHECK_EQ(wpe_open_window_count(), before - 2);  // the clean window closes with the others (initquit)

    // A failed write keeps foobar2000 running.
    stageTitle(b, @"b2");
    b.backend->failNext = true;
    answer = -1;
    wpe_test_review_for_quit(^(bool ok) {
        answer = ok;
    });
    wpe_test_answer_close_prompt(b.c, kApply);
    spin(20);
    CHECK_EQ(answer, 0);
    CHECK_EQ(quits, 1);
    CHECK(b.model().dirty());
    CHECK_EQ(wpe_open_window_count(), before - 2);
    wpe_test_set_quit_again(nil);
}

// A shown window asks at quit unless it is ordered out on its own. While foobar2000 is hidden (Cmd-H) every
// window is ordered out (isVisible NO, not miniaturized): the review unhides it and asks, never skipping it.
TEST(the_quit_review_asks_while_foobar2000_is_hidden) {
    CHECK(wpe_test_quit_can_ask(true, false, false));
    CHECK(wpe_test_quit_can_ask(false, true, false));
    CHECK(wpe_test_quit_can_ask(false, false, true));
    CHECK(wpe_test_quit_can_ask(false, true, true));
    CHECK(!wpe_test_quit_can_ask(false, false, false));
}

TEST(quitting_while_asking_or_with_edit_value_open) {
    __block int quits = 0;
    wpe_test_set_quit_again(^{
        ++quits;
    });
    {
        // The close button's prompt is up: its answer decides the quit too.
        UI ui({tf({{"TITLE", {"x"}}})});
        stageTitle(ui, @"new");
        commandW(ui);
        NSAlert* p = wpe_test_close_prompt(ui.c);
        CHECK(p != nil);
        __block int answer = -1;
        wpe_test_review_for_quit(^(bool ok) {
            answer = ok;
        });
        CHECK(wpe_test_close_prompt(ui.c) == p);
        CHECK_EQ(answer, -1);
        wpe_test_answer_close_prompt(ui.c, kKeepEditing);
        CHECK_EQ(answer, 0);
    }
    {
        // Edit Value is ended as OK: its values are staged, then asked about with the rest.
        UI ui({tf({{"MOOD", {"a"}}}), tf({{"MOOD", {"b"}}})});
        const size_t before = wpe_open_window_count();
        ui.click(ui.row("MOOD"), 0, 2);
        Sheet sh(ui);
        CHECK(sh.open());
        if (!sh.open()) return;
        sh.click(1, 1);
        sh.type(@"z");
        __block int answer = -1;
        wpe_test_review_for_quit(^(bool ok) {
            answer = ok;
        });
        CHECK(wpe_test_value_sheet(ui.c) == nil);
        CHECK(ui.model().dirty());
        NSAlert* p = wpe_test_close_prompt(ui.c);
        CHECK(p != nil);
        if (p) CHECK_EQ(str(p.messageText), std::string("Do you want to apply the changes you made to 1 file?"));
        wpe_test_answer_close_prompt(ui.c, kDontApply);
        spin();
        CHECK_EQ(answer, 1);
        CHECK_EQ(wpe_open_window_count(), before - 1);
        CHECK_EQ(ui.backend->writes, 0);
    }
    CHECK_EQ(quits, 0);
    wpe_test_set_quit_again(nil);
}

// The quit guard is the document AppKit's terminate: review asks; it stands for every window.
TEST(the_quit_guard_document_follows_the_windows) {
    NSDocument* guard = wpe_test_install_quit_guard();
    CHECK(guard != nil);
    if (!guard) return;
    CHECK(wpe_test_install_quit_guard() == guard);
    CHECK([[NSDocumentController sharedDocumentController].documents containsObject:guard]);
    CHECK(guard.fileURL == nil);
    CHECK(!guard.documentEdited);
    UI ui({tf({{"TITLE", {"x"}}})});
    CHECK(!guard.documentEdited);
    stageTitle(ui, @"new");
    CHECK(guard.documentEdited);
    __block int answer = -1;
    WPETestCloseDelegate* d = [WPETestCloseDelegate new];
    d.done = ^(BOOL ok) {
        answer = ok;
    };
    [guard canCloseDocumentWithDelegate:d shouldCloseSelector:@selector(document:shouldClose:contextInfo:) contextInfo:nullptr];
    CHECK_EQ(answer, -1);
    wpe_test_answer_close_prompt(ui.c, kKeepEditing);
    CHECK_EQ(answer, 0);
    CHECK(guard.documentEdited);
    [ui.w close];  // as initquit closes them: nothing left to review
    spin();
    CHECK(!guard.documentEdited);
}

// When foobar2000 quits without having asked (initquit), each window is closed without writing and the
// console is told what was dropped.
TEST(closing_all_windows_at_quit_writes_nothing_and_reports_unapplied_changes) {
    UI dirty({tf({{"TITLE", {"x"}}})});
    UI clean({tf({{"TITLE", {"y"}}})});
    stageTitle(dirty, @"new");
    const std::vector<std::string> notes = wpe_close_all_windows();
    spin();
    CHECK_EQ(notes.size(), size_t(1));
    if (!notes.empty())
        CHECK_EQ(notes[0], std::string("Properties \xE2\x80\x94 single was closed with changes that were not applied (1 file); "
                                       "nothing was written."));
    CHECK_EQ(wpe_open_window_count(), size_t(0));
    CHECK_EQ(dirty.backend->writes + clean.backend->writes, 0);
}

// The real thing, in a child process (a quit ends the process): -[NSApplication terminate:] asks through
// the document review, and the answer decides whether the app quits, as it would in foobar2000.
TEST(terminate_asks_through_the_document_review) {
    struct Want {
        const char* mode;
        int status;
        std::vector<std::string> lines;
    };
    const std::vector<Want> wants = {
        {"cancel", 0, {"guard edited=1", "asked: foobar2000 is quitting.", "terminate returned writes=0 open=1", "still running writes=0"}},
        {"discard", 0, {"guard edited=1", "asked: foobar2000 is quitting.", "terminated writes=0 title=x"}},
        {"apply", 0, {"guard edited=1", "asked: foobar2000 is quitting.", "terminate returned writes=1 open=1", "terminated writes=1 title=new"}},
    };
    for (const Want& want : wants) {
        int status = -1;
        const std::string out = runSelf(want.mode, &status);
        CHECK_EQ(status, want.status);
        std::vector<std::string> lines;
        size_t at = 0;
        while (at < out.size()) {
            const size_t end = out.find('\n', at);
            lines.push_back(out.substr(at, end == std::string::npos ? std::string::npos : end - at));
            if (end == std::string::npos) break;
            at = end + 1;
        }
        std::vector<std::string> got;
        for (size_t i = 0; i < lines.size(); ++i) {
            std::string l = lines[i];
            if (l.rfind("asked: ", 0) == 0) l = l.substr(0, std::string("asked: foobar2000 is quitting.").size());
            if (!l.empty()) got.push_back(l);
        }
        CHECK_EQ(got, want.lines);
    }
}

#pragma mark - Button bars, measured on the live window

namespace {

// Renders `view` as the window draws it (cacheDisplayInRect:toBitmapImageRep:, the view and its
// subviews) into an sRGB bitmap of `scale` pixels per point, whatever the screen is.
NSBitmapImageRep* renderLive(NSView* view, NSRect rect, CGFloat scale) {
    [view.window.contentView layoutSubtreeIfNeeded];
    NSBitmapImageRep* blank = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
                                                                    pixelsWide:std::lround(NSWidth(rect) * scale)
                                                                    pixelsHigh:std::lround(NSHeight(rect) * scale)
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSCalibratedRGBColorSpace
                                                                   bytesPerRow:0
                                                                   bitsPerPixel:0];
    NSBitmapImageRep* rep = [blank bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace];
    rep.size = rect.size;
    [view cacheDisplayInRect:rect toBitmapImageRep:rep];
    return rep;
}

double luma(NSBitmapImageRep* rep, NSInteger x, NSInteger y) {
    NSUInteger p[4] = {};
    [rep getPixel:p atX:x y:y];  // row 0 is the top
    return 0.2126 * double(p[0]) + 0.7152 * double(p[1]) + 0.0722 * double(p[2]);
}

// sRGB components 0...255.
struct RGB {
    double r = 0, g = 0, b = 0;
};

RGB pixel(NSBitmapImageRep* rep, NSInteger x, NSInteger y) {
    NSUInteger p[4] = {};
    [rep getPixel:p atX:x y:y];
    return {double(p[0]), double(p[1]), double(p[2])};
}

// `color` as `view` draws it (in its effective appearance), composited over `under` when translucent.
RGB resolved(NSColor* color, NSView* view, RGB under = {255, 255, 255}) {
    __block NSColor* c = nil;
    NSAppearance* look = view.effectiveAppearance ?: NSAppearance.currentDrawingAppearance;
    [look performAsCurrentDrawingAppearance:^{
        c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    if (!c) return under;
    const double a = c.alphaComponent;
    return {c.redComponent * 255 * a + under.r * (1 - a), c.greenComponent * 255 * a + under.g * (1 - a),
            c.blueComponent * 255 * a + under.b * (1 - a)};
}

// What `view` is drawn over: its window's background colour as the view's appearance resolves it.
// cacheDisplayInRect leaves transparent what the rendered views do not paint themselves (an alert's
// buttons sit on its window's background, which no view draws).
RGB backdrop(NSView* view) { return resolved(view.window.backgroundColor ?: NSColor.windowBackgroundColor, view); }

// The pixel at (x, y) as it shows over `under`. A render can carry its ink in alpha alone (AppKit may draw
// a label as a black alpha mask), which its luminance never shows: composited over what is behind it, the
// ink is the contrast it has on screen. An opaque pixel is unchanged.
RGB over(NSBitmapImageRep* rep, NSInteger x, NSInteger y, RGB under) {
    NSUInteger p[4] = {};
    [rep getPixel:p atX:x y:y];
    if (!rep.hasAlpha || rep.samplesPerPixel != 4) return {double(p[0]), double(p[1]), double(p[2])};
    const bool first = rep.bitmapFormat & NSBitmapFormatAlphaFirst;
    const double a = double(first ? p[0] : p[3]) / 255;
    const double r = double(first ? p[1] : p[0]), g = double(first ? p[2] : p[1]), b = double(first ? p[3] : p[2]);
    const double k = (rep.bitmapFormat & NSBitmapFormatAlphaNonpremultiplied) ? a : 1;  // premultiplied unless flagged
    return {r * k + under.r * (1 - a), g * k + under.g * (1 - a), b * k + under.b * (1 - a)};
}

double lumaOver(NSBitmapImageRep* rep, NSInteger x, NSInteger y, RGB under) {
    const RGB c = over(rep, x, y, under);
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

double distance(RGB a, RGB b) { return std::max({std::fabs(a.r - b.r), std::fabs(a.g - b.g), std::fabs(a.b - b.b)}); }

std::string hex(RGB c) {
    char buf[16];
    std::snprintf(buf, sizeof buf, "%02X%02X%02X", int(std::lround(c.r)), int(std::lround(c.g)), int(std::lround(c.b)));
    return buf;
}

// The alignment rect (the bezel) of a control, in its superview's coordinates.
NSRect box(NSView* v) { return [v alignmentRectForFrame:v.frame]; }

// Distance of a rect's top edge from the top of `container` (flipped or not), and of its bottom edge
// from the bottom.
double topGap(NSView* container, NSRect r) { return container.flipped ? NSMinY(r) : NSHeight(container.bounds) - NSMaxY(r); }
double bottomGap(NSView* container, NSRect r) { return container.flipped ? NSHeight(container.bounds) - NSMaxY(r) : NSMinY(r); }

// What is drawn down the pixel column at x (points, in `view`): the first and last rows (points from the
// top) whose colour differs from the background at the column's top pixel.
bool drawnSpan(NSBitmapImageRep* rep, CGFloat scale, CGFloat x, double& top, double& bottom) {
    const NSInteger px = std::lround(x * scale);
    if (px < 0 || px >= rep.pixelsWide) return false;
    auto alpha = [&](NSInteger y) {
        NSUInteger p[4] = {};
        [rep getPixel:p atX:px y:y];
        return double(p[3]);
    };
    const double ground = luma(rep, px, 0), groundAlpha = alpha(0);
    NSInteger first = -1, last = -1;
    for (NSInteger y = 0; y < rep.pixelsHigh; ++y)
        if (std::fabs(luma(rep, px, y) - ground) > 4 || std::fabs(alpha(y) - groundAlpha) > 8) {
            if (first < 0) first = y;
            last = y;
        }
    if (first < 0) return false;
    top = first / scale;
    bottom = (last + 1) / scale;
    return true;
}

// A button's label as rendered inside its bezel: the ink that differs from the bezel's face, every pixel
// composited over `under` (what the render is drawn over, see backdrop), so a label drawn as an alpha mask
// counts as ink and a blank one still has none. Points from the bezel's top; the edges are sub-pixel (an
// edge row's coverage is its share of the pixel).
struct LabelInk {
    bool found = false;
    double capTop = 0, capBottom = 0;  // the first letter (a capital in every label here): the cap height box
    double left = 0;                   // where the first letter's ink starts
};

// `insetX` / `insetY` (points) keep out what surrounds the text: a bezel's rounded corners and edges (the
// defaults), a cell's neighbours.
LabelInk labelInk(NSBitmapImageRep* rep, CGFloat scale, CGFloat capHeight, CGFloat insetX = 6, CGFloat insetY = 2,
                  RGB under = {255, 255, 255}) {
    LabelInk out;
    const NSInteger w = rep.pixelsWide, h = rep.pixelsHigh;
    const NSInteger x0 = std::lround(insetX * scale), x1 = w - x0;
    const NSInteger y0 = std::lround(insetY * scale), y1 = h - y0;
    if (x1 <= x0 || y1 <= y0) return out;
    std::vector<double> lum((size_t)(w * h), 0), face;
    for (NSInteger y = y0; y < y1; ++y)
        for (NSInteger x = x0; x < x1; ++x) face.push_back(lum[(size_t)(y * w + x)] = lumaOver(rep, x, y, under));
    std::nth_element(face.begin(), face.begin() + face.size() / 2, face.end());
    const double faceLum = face[face.size() / 2];
    double maxInk = 0;
    for (NSInteger y = y0; y < y1; ++y)
        for (NSInteger x = x0; x < x1; ++x) maxInk = std::max(maxInk, std::fabs(lum[(size_t)(y * w + x)] - faceLum));
    if (maxInk < 20) return out;
    auto cover = [&](NSInteger x, NSInteger y) { return std::min(1.0, std::fabs(lum[(size_t)(y * w + x)] - faceLum) / maxInk); };
    NSInteger left = -1;
    for (NSInteger x = x0; x < x1 && left < 0; ++x)
        for (NSInteger y = y0; y < y1; ++y)
            if (cover(x, y) >= 0.25) {
                left = x;
                break;
            }
    if (left < 0) return out;
    // The first letter's columns: up to 0.45 of the cap height covers the left half of O, C and A (their
    // top and bottom) and the stem of T, but not the next letter.
    const NSInteger c1 = std::min(x1, left + std::lround(0.45 * capHeight * scale) + 1);
    std::vector<double> row((size_t)h, 0);
    for (NSInteger y = y0; y < y1; ++y)
        for (NSInteger x = left; x < c1; ++x) row[(size_t)y] = std::max(row[(size_t)y], cover(x, y));
    NSInteger first = -1, last = -1;
    for (NSInteger y = y0; y < y1; ++y)
        if (row[(size_t)y] >= 0.1) {
            if (first < 0) first = y;
            last = y;
        }
    if (first < 0) return out;
    out.capTop = (double(first) + 1 - row[(size_t)first]) / scale;
    out.capBottom = (double(last) + row[(size_t)last]) / scale;
    double edge = 0;
    for (NSInteger y = y0; y < y1; ++y) edge = std::max(edge, cover(left, y));
    out.left = (double(left) + 1 - edge) / scale;
    out.found = true;
    return out;
}

double g_worstLabelOffset = 0;  // largest |cap box centre - bezel centre| measured, for WPE_MEASURE

// The label of `b`, rendered at `scale` as its bar draws it (the bezel's rect only): AppKit centres its
// capitals on the bezel to about a point in both designs, and they are the system font's cap height.
void checkLabelCentred(NSButton* b, CGFloat scale, const char* what) {
    const NSRect bezel = box(b);
    NSBitmapImageRep* rep = renderLive(b.superview, bezel, scale);
    const CGFloat capHeight = b.font.capHeight;
    const LabelInk ink = labelInk(rep, scale, capHeight, 6, 2, backdrop(b));
    CHECK(ink.found);
    if (!ink.found) {
        std::fprintf(stderr, "  no label ink: %s %s @%gx\n", b.title.UTF8String, what, scale);
        return;
    }
    const double cap = (ink.capTop + ink.capBottom) / 2 - NSHeight(bezel) / 2;
    g_worstLabelOffset = std::max(g_worstLabelOffset, std::fabs(cap));
    // AppKit's own placement: within 0.4 pt in the macOS 26 design, 0.6-1 pt above the alignment rect's
    // centre in the classic one (whose drawn bezel reaches a point further down, its shadow).
    CHECK(std::fabs(cap) <= 1.25);
    CHECK(std::fabs((ink.capBottom - ink.capTop) - capHeight) <= 1 / scale + 0.5);
    if (std::getenv("WPE_MEASURE") || std::fabs(cap) > 1.25)
        std::printf("  %-6s %-8s @%gx: cap box %.2f..%.2f (centre %+.2f pt), bezel %g pt\n", b.title.UTF8String, what, scale, ink.capTop,
                    ink.capBottom, cap, NSHeight(bezel));
}

// Renders each button enabled and disabled at 1x and 2x.
void checkLabelsCentred(NSArray<NSButton*>* buttons) {
    for (NSButton* b in buttons) {
        const BOOL enabled = b.enabled;
        for (CGFloat scale : {1.0, 2.0}) {
            b.enabled = YES;
            checkLabelCentred(b, scale, "enabled");
            b.enabled = NO;
            checkLabelCentred(b, scale, "disabled");
        }
        b.enabled = enabled;
    }
}

NSString* frameText(NSRect r) { return NSStringFromRect(r); }

// A button bar: at the bottom of its window, full width; `trailing` (left to right, the default button
// last) share one width (at least kButtonMinWidth), kBarSpacing apart, kBarMargin from the trailing
// edge; `leading` (Tools, or the sheet's hint) kBarMargin from the leading edge on the same centre line;
// every bezel kBarInset from the bar's top and bottom. As drawn (the bar rendered at 2x): each push
// button's bezel spans its alignment rect to within a point, centred in the bar.
void checkBar(NSView* bar, NSArray<NSButton*>* trailing, NSView* leading, NSString* where) {
    using namespace wpe::ui;
    const size_t before = (size_t)wpetest::failures();
    CHECK([bar isKindOfClass:[WPEBarView class]]);
    CHECK_EQ(NSMinY(bar.frame), CGFloat(0));
    CHECK_EQ(NSWidth(bar.frame), NSWidth(bar.superview.bounds));
    const NSRect last = box(trailing.lastObject);
    CHECK(std::fabs(NSWidth(bar.bounds) - NSMaxX(last) - kBarMargin) < 0.01);
    for (NSUInteger i = 0; i < trailing.count; ++i) {
        NSButton* b = trailing[i];
        const NSRect r = box(b);
        CHECK(b.superview == bar);
        CHECK(NSContainsRect(bar.bounds, b.frame));
        CHECK(std::fabs(NSWidth(r) - NSWidth(last)) < 0.01);
        CHECK(NSWidth(r) >= kButtonMinWidth - 0.01);
        CHECK(std::fabs(topGap(bar, r) - kBarInset) < 0.01);
        CHECK(std::fabs(bottomGap(bar, r) - kBarInset) < 0.01);
        CHECK(NSWidth(r) >= b.intrinsicContentSize.width - 0.01);  // the label is never squeezed
        if (i > 0) CHECK(std::fabs(NSMinX(r) - NSMaxX(box(trailing[i - 1])) - kBarSpacing) < 0.01);
    }
    if (leading) {
        CHECK(std::fabs(NSMinX(box(leading)) - kBarMargin) < 0.01);
        if ([leading isKindOfClass:[NSButton class]]) {
            CHECK(std::fabs(NSMidY(box(leading)) - NSMidY(last)) <= 0.5);
            CHECK(NSMaxX(box(leading)) + kBarSpacing <= NSMinX(box(trailing.firstObject)) + 0.01);
        } else {
            CHECK(NSMaxX(leading.frame) <= NSMinX(box(trailing.firstObject)) - kBarSpacing + 0.5);
        }
    }
    // The bar's top separator line (WPEBarView is flipped) is left out of the measured rows.
    const CGFloat scale = 2, line = 1;
    CHECK(bar.flipped);
    CHECK([[bar valueForKey:@"wpeTopLine"] boolValue]);
    NSBitmapImageRep* rep = renderLive(bar, NSMakeRect(0, line, NSWidth(bar.bounds), NSHeight(bar.bounds) - line), scale);
    for (NSButton* b in trailing) {
        const NSRect r = box(b);
        double top = 0, bottom = 0;
        const bool drawn = drawnSpan(rep, scale, NSMinX(r) + 8, top, bottom);
        CHECK(drawn);
        if (!drawn) continue;
        top += line;
        bottom += line;
        const double alignTop = topGap(bar, r), alignBottom = NSHeight(bar.bounds) - bottomGap(bar, r);
        CHECK(std::fabs(top - alignTop) <= 1);
        CHECK(std::fabs(bottom - alignBottom) <= 1.5);
        CHECK(std::fabs(top - (NSHeight(bar.bounds) - bottom)) <= 1.5);
        if (std::getenv("WPE_MEASURE"))
            std::printf("  %-6s drawn %.1f..%.1f, bezel %.1f..%.1f, bar %g\n", b.title.UTF8String, top, bottom, alignTop, alignBottom,
                        NSHeight(bar.bounds));
    }
    if ((size_t)wpetest::failures() != before) {
        std::fprintf(stderr, "  bar %s at %s:", frameText(bar.frame).UTF8String, where.UTF8String);
        for (NSButton* b in trailing) std::fprintf(stderr, " %s %s", b.title.UTF8String, frameText(box(b)).UTF8String);
        std::fprintf(stderr, "\n");
    }
}

// Where the first column's header title starts drawing (points from the content view's leading edge), or
// -1 when the page has no titled header.
double headerTitleInk(NSView* page) {
    NSTableView* t = [page isKindOfClass:[NSScrollView class]] ? (NSTableView*)((NSScrollView*)page).documentView : nil;
    if (![t isKindOfClass:[NSTableView class]] || !t.headerView || !t.tableColumns.count || !t.tableColumns[0].title.length) return -1;
    NSTableHeaderView* header = t.headerView;
    const NSRect col = [header headerRectOfColumn:0];
    NSFont* font = WPEHeaderAttributes(NSColor.headerTextColor, [NSParagraphStyle defaultParagraphStyle])[NSFontAttributeName];
    const LabelInk ink = labelInk(renderLive(header, col, 2), 2, font.capHeight, 0, 1);
    if (!ink.found) return -1;
    NSView* content = header.window.contentView;
    return NSMinX([content convertRect:col fromView:header]) + ink.left;
}

// Where the control's bezel starts drawing (points from the content view's leading edge): the first column
// of the page band, rendered at 2x, that differs from the band down the bezel's middle half.
double drawnBezelLeft(NSSegmentedControl* c) {
    NSView* band = c.superview;
    NSBitmapImageRep* rep = renderLive(band, band.bounds, 2);
    const NSRect r = box(c);
    const NSInteger y0 = std::lround((topGap(band, r) + NSHeight(r) / 4) * 2), y1 = std::lround((topGap(band, r) + NSHeight(r) * 3 / 4) * 2);
    for (NSInteger x = 0; x < rep.pixelsWide; ++x)
        for (NSInteger y = y0; y < y1; ++y)
            if (std::fabs(luma(rep, x, y) - luma(rep, 0, y)) > 4)
                return NSMinX([c.window.contentView convertRect:NSMakeRect(x / 2.0, 0, 0.5, 1) fromView:band]);
    return -1;
}

// The page control: at the leading edge, kPageControlInset in (its bezel where the list's text and its
// first header title start), `top` below the content's top edge and kPageBandInset above `page` (the list);
// drawn (the control rendered alone at 2x) over its alignment rect.
void checkPageControl(NSSegmentedControl* c, CGFloat top, NSView* page, NSString* where) {
    using namespace wpe::ui;
    const size_t before = (size_t)wpetest::failures();
    NSView* content = c.window.contentView;
    const NSRect r = [content convertRect:box(c) fromView:c.superview];
    const NSRect p = [content convertRect:page.bounds fromView:page];
    CHECK(std::fabs(NSMinX(r) - kPageControlInset) < 0.01);
    CHECK(NSMaxX(r) <= NSWidth(content.bounds) - kPageControlInset + 0.01);
    CHECK(std::fabs(topGap(content, r) - top) < 0.01);
    CHECK(std::fabs(topGap(content, p) - (topGap(content, r) + NSHeight(r)) - kPageBandInset) < 0.01);
    // As drawn: the bezel's left edge at its alignment rect's, and in line with the list header's first title.
    const double bezel = drawnBezelLeft(c);
    CHECK(std::fabs(bezel - NSMinX(r)) <= 0.5);
    const double title = headerTitleInk(page);
    if (title >= 0) CHECK(std::fabs(bezel - title) <= 0.5);
    if (std::getenv("WPE_MEASURE"))
        std::printf("  page control at %s: alignment x %.2f..%.2f of %g, bezel drawn from x %.2f, header title ink x %.2f\n",
                    where.UTF8String, NSMinX(r), NSMaxX(r), NSWidth(content.bounds), bezel, title);
    NSBitmapImageRep* rep = renderLive(c, c.bounds, 2);
    const NSRect inside = [c convertRect:box(c) fromView:c.superview];
    double t = 0, b = 0;
    // A column 4 pt into the first segment: its edge, clear of the label.
    const bool drawn = drawnSpan(rep, 2, NSMinX(inside) + 4, t, b);
    CHECK(drawn);
    if (drawn) {
        CHECK(std::fabs(t - topGap(c, inside)) <= 1.5);
        CHECK(std::fabs(b - (NSHeight(c.bounds) - bottomGap(c, inside))) <= 1.5);
        if (std::getenv("WPE_MEASURE"))
            std::printf("  page control drawn %.1f..%.1f, bezel %.1f..%.1f of %g\n", t, b, topGap(c, inside),
                        NSHeight(c.bounds) - bottomGap(c, inside), NSHeight(c.bounds));
    }
    if ((size_t)wpetest::failures() != before) std::fprintf(stderr, "  page control %s at %s\n", frameText(r).UTF8String, where.UTF8String);
}

NSString* designName() {
    return [[NSBundle.mainBundle objectForInfoDictionaryKey:@"UIDesignRequiresCompatibility"] boolValue] ? @"classic design (UIDesignRequiresCompatibility, as in foobar2000)"
                                                                                                          : @"macOS 26 design";
}

}

// The tests run in the design the host gives AppKit: wpe_ui_tests embeds foobar2000's
// UIDesignRequiresCompatibility, wpe_ui_tests_macos26 does not. In the classic design a bordered
// NSButton has alignment insets (its frame includes shadow margins around the bezel), so a stock one
// tells which design AppKit is really running. The window lays everything out by alignment rects, so
// both designs give the same margins.
TEST(ui_tests_run_in_the_design_their_info_plist_asks_for) {
    const BOOL classic = [[NSBundle.mainBundle objectForInfoDictionaryKey:@"UIDesignRequiresCompatibility"] boolValue];
    NSButton* stock = [NSButton buttonWithTitle:@"OK" target:nil action:nil];
    stock.bezelStyle = NSBezelStyleRegularSquare;
    stock.bordered = YES;
    const NSEdgeInsets in = stock.alignmentRectInsets;
    const bool inset = in.top > 0 || in.bottom > 0 || in.left > 0 || in.right > 0;
    CHECK_EQ(inset, bool(classic));
    if (std::getenv("WPE_MEASURE"))
        std::printf("  %s: stock square-bezel button insets %g %g %g %g\n", designName().UTF8String, in.top, in.left, in.bottom, in.right);
}

// The window's chrome measured on the live window: the page band at the top and the button bar at the
// bottom, on every page, at several sizes and while resizing down to the minimum.
namespace {

// A list's columns add up to its clip view's width: nothing to scroll sideways, the header without a stub,
// long values ellipsized at the visible edge. A sideways scroll-wheel event leaves the list where it is.
void checkColumnsFill(NSScrollView* scroll, NSString* where) {
    NSTableView* table = scroll.documentView;
    CGFloat sum = 0;
    for (NSTableColumn* c in table.tableColumns) sum += c.width + table.intercellSpacing.width;
    const CGFloat clip = NSWidth(scroll.contentView.bounds);
    if (std::fabs(sum - clip) > 0.5 || NSWidth(table.frame) > clip + 0.5)
        std::printf("    %s: columns %g, table %g, clip %g\n", where.UTF8String, sum, NSWidth(table.frame), clip);
    CHECK(std::fabs(sum - clip) <= 0.5);
    CHECK(NSWidth(table.frame) <= clip + 0.5);
    CGEventRef cg = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, 0, -40);
    NSEvent* wheel = cg ? [NSEvent eventWithCGEvent:cg] : nil;
    if (cg) CFRelease(cg);
    if (wheel) {
        [scroll scrollWheel:wheel];
        CHECK(std::fabs(scroll.contentView.bounds.origin.x) < 0.5);
        [scroll.contentView scrollToPoint:NSMakePoint(0, scroll.contentView.bounds.origin.y)];
    }
}

}

TEST(page_band_and_button_bar_in_the_live_window_at_any_size) {
    using namespace wpe::ui;
    NSData* cover = makePNG(600, 600, NSColor.systemTealColor);
    UI ui({tf({{"TITLE", {"t"}}})}, {artWith({{art::FrontCover, picOf(cover)}})});
    NSArray<NSButton*>* buttons = wpe_test_buttons(ui.c);  // Tools, OK, Cancel, Apply
    NSArray<NSButton*>* trailing = @[ buttons[3], buttons[2], buttons[1] ];
    NSView* bar = buttons[1].superview;
    NSView* content = ui.w.contentView;
    NSSegmentedControl* pages = wpe_test_tab_control(ui.c);
    const NSSize minimum = [ui.w contentRectForFrameRect:NSMakeRect(0, 0, ui.w.minSize.width, ui.w.minSize.height)].size;
    const NSSize sizes[] = {{916, 600}, {1000, 638}, minimum, {1225, 615}, {1600, 1000}, {916, 600}};
    NSView* pageViews[] = {ui.table.enclosingScrollView, wpe_test_details_table(ui.c).enclosingScrollView,
                           wpe_test_rg_table(ui.c).enclosingScrollView, wpe_test_art_table(ui.c).enclosingScrollView};
    for (NSInteger tab : {3, 0, 1, 2}) {
        wpe_test_select_tab(ui.c, tab);
        spin(4);
        for (const NSSize& size : sizes) {
            [ui.w setContentSize:size];
            spin(2);
            [content layoutSubtreeIfNeeded];
            NSString* where = [NSString stringWithFormat:@"tab %ld, content %@", (long)tab, NSStringFromSize(size)];
            checkBar(bar, trailing, buttons[0], where);
            checkPageControl(pages, kPageBandInset, pageViews[tab], where);
            // The page band's grey runs from the title bar to the list; the list ends at the bar.
            const NSRect band = pages.superview.frame;
            CHECK([pages.superview isKindOfClass:[WPEBarView class]]);
            CHECK(std::fabs(topGap(content, band)) < 0.01);
            CHECK_EQ(NSWidth(band), size.width);
            const NSRect list = [content convertRect:pageViews[tab].bounds fromView:pageViews[tab]];
            CHECK(std::fabs(NSMinY(list) - NSMaxY(bar.frame)) < 0.01);
            checkColumnsFill((NSScrollView*)pageViews[tab], where);
        }
    }
    // Every Name | Value list after each step, whichever page is showing (the hidden ones are resized too),
    // and after the Name divider is dragged to another share.
    for (NSInteger tab : {0, 1, 2}) {
        wpe_test_select_tab(ui.c, tab);
        spin(2);
        for (CGFloat w : {500.0, 700.0, 916.0, 1091.0, 1400.0, 1013.0, 642.0}) {
            [ui.w setContentSize:NSMakeSize(std::max(minimum.width, w), 600)];
            spin(2);
            [content layoutSubtreeIfNeeded];
            checkColumnsFill((NSScrollView*)pageViews[tab],
                             [NSString stringWithFormat:@"tab %ld, width %g", (long)tab, std::max(minimum.width, w)]);
        }
    }
    // Resizing the window frame step by step (as a live resize does), down to its minimum and back.
    wpe_test_select_tab(ui.c, 3);
    NSRect frame = ui.w.frame;
    for (CGFloat h = 760; h >= ui.w.minSize.height; h -= 37) {
        frame.size = NSMakeSize(std::max(ui.w.minSize.width, h * 1.3), h);
        [ui.w setFrame:frame display:NO];
        [content layoutSubtreeIfNeeded];
        NSString* where = [NSString stringWithFormat:@"frame %@", NSStringFromSize(frame.size)];
        checkBar(bar, trailing, buttons[0], where);
        checkPageControl(pages, kPageBandInset, pageViews[3], where);
    }
    if (std::getenv("WPE_MEASURE"))
        std::printf("  %s: page band %g pt, button bar %g pt, buttons %s / %s\n", designName().UTF8String, NSHeight(pages.superview.frame),
                    NSHeight(bar.frame), NSStringFromRect(box(buttons[1])).UTF8String, NSStringFromRect(buttons[1].frame).UTF8String);
}

TEST(button_labels_are_centred_in_the_live_buttons) {
    NSData* cover = makePNG(600, 600, NSColor.systemTealColor);
    UI ui({tf({{"TITLE", {"t"}}})}, {artWith({{art::FrontCover, picOf(cover)}})});
    [ui.w setContentSize:NSMakeSize(916, 600)];
    wpe_test_select_tab(ui.c, 3);
    spin(10);
    g_worstLabelOffset = 0;
    for (NSAppearanceName look in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        ui.w.appearance = [NSAppearance appearanceNamed:look];
        if (std::getenv("WPE_MEASURE")) std::printf("  %s, %s\n", designName().UTF8String, look.UTF8String);
        checkLabelsCentred(wpe_test_buttons(ui.c));
    }
    // Apply as the window enables it, after an edit.
    ui.w.appearance = nil;
    wpe_test_select_tab(ui.c, 0);
    ui.select(ui.row("TITLE"));
    ui.type(@"x");
    ui.ret();
    NSButton* apply = wpe_test_buttons(ui.c)[3];
    CHECK(apply.enabled);
    checkLabelCentred(apply, 2, "staged");
    if (std::getenv("WPE_MEASURE")) std::printf("  worst cap box offset %.2f pt\n", g_worstLabelOffset);
}

TEST(edit_value_sheet_bar_follows_the_window_bar) {
    using namespace wpe::ui;
    UI ui({tf({{"ARTIST", {"A"}}}), tf({{"ARTIST", {"B"}}})});
    ui.click(ui.row("ARTIST"), 0, 2);
    Sheet sh(ui);
    CHECK(sh.open());
    if (!sh.open()) return;
    NSArray<NSButton*>* buttons = wpe_test_sheet_buttons(sh.s);  // OK, Cancel
    CHECK_EQ(buttons.count, NSUInteger(2));
    CHECK_EQ(str(buttons[0].title), std::string("OK"));
    CHECK_EQ(str(buttons[1].title), std::string("Cancel"));
    // Cancel then OK, OK the sheet's default button on Command-Return.
    CHECK(sh.w.defaultButtonCell == buttons[0].cell);
    CHECK_EQ(str(buttons[0].keyEquivalent), std::string("\r"));
    CHECK_EQ(buttons[0].keyEquivalentModifierMask & NSEventModifierFlagDeviceIndependentFlagsMask, NSEventModifierFlagCommand);
    for (NSButton* b in buttons) {
        CHECK([b isMemberOfClass:[NSButton class]]);
        CHECK_EQ(b.bezelStyle, NSBezelStylePush);
    }
    NSSegmentedControl* pages = wpe_test_sheet_tab_control(sh.s);
    CHECK([pages isKindOfClass:[NSSegmentedControl class]]);
    CHECK_EQ(pages.segmentCount, NSInteger(2));
    CHECK_EQ(str([pages labelForSegment:0]), std::string("Common value"));
    CHECK_EQ(str([pages labelForSegment:1]), std::string("Per-track"));
    CHECK_EQ(pages.selectedSegment, NSInteger(1));
    NSView* bar = buttons[0].superview;
    NSTextField* hint = nil;
    for (NSView* v in bar.subviews)
        if ([v isKindOfClass:[NSTextField class]]) hint = (NSTextField*)v;
    CHECK(hint != nil && !hint.hidden);
    // Down to the sheet's minimum size and the widths just above it, where the hint no longer fits whole:
    // its frame stays out of the gap before Cancel, its text is shortened in the middle (keeping the ";")
    // and the full text is its tooltip; with room for all of it, it has no tooltip.
    const NSSize least = sh.w.contentMinSize;
    const NSSize sizes[] = {sh.w.contentView.frame.size, {700, 420}, {480, 300}, least,
                            {least.width + 1, least.height}, {least.width + 2, least.height + 1},
                            {least.width + 3, least.height + 7}, {least.width + 4, least.height},
                            {least.width + 6, least.height + 20}, {least.width + 10, least.height},
                            {least.width + 24, least.height + 40}, {1100, 640}};
    bool sawShortened = false;
    for (const NSSize& size : sizes) {
        [sh.w setContentSize:size];
        [sh.w.contentView layoutSubtreeIfNeeded];
        CHECK(NSEqualSizes(sh.w.contentView.frame.size, size));
        NSString* where = [NSString stringWithFormat:@"sheet %@", NSStringFromSize(size)];
        checkBar(bar, @[ buttons[1], buttons[0] ], hint, where);
        checkPageControl(pages, 30, sh.table.enclosingScrollView, where);
        CHECK(!hint.hidden);
        CHECK_EQ(hint.lineBreakMode, NSLineBreakByTruncatingMiddle);
        const bool shortened = NSWidth(box(hint)) + 0.01 < hint.intrinsicContentSize.width;
        sawShortened = sawShortened || shortened;
        CHECK_EQ(str(hint.toolTip), std::string(shortened ? "Delimit multiple values with ;" : "<nil>"));
        if (!shortened) CHECK(NSWidth(box(hint)) >= hint.intrinsicContentSize.width - 0.01);
        CHECK(NSWidth(box(hint)) > 0);
    }
    // (At the minimum size the hint does not fit whole, so the shortened case is always covered.)
    CHECK(sawShortened);
    // At the sheet's minimum size the page control keeps its place at the leading edge.
    [sh.w setContentSize:sh.w.contentMinSize];
    [sh.w.contentView layoutSubtreeIfNeeded];
    checkPageControl(pages, 30, sh.table.enclosingScrollView, @"sheet at its minimum size");
    [sh.w setContentSize:sizes[0]];
    [sh.w.contentView layoutSubtreeIfNeeded];
    // Clicking a segment switches the page, as the shortcuts do.
    clickSegment(sh.w, pages, 0);
    CHECK_EQ(wpe_test_sheet_page(sh.s), NSInteger(0));
    clickSegment(sh.w, pages, 1);
    CHECK_EQ(wpe_test_sheet_page(sh.s), NSInteger(1));
    CHECK(sh.w.firstResponder == sh.table);
    // Picked from the keyboard on the control itself, the focus stays there (as AppKit's controls do).
    CHECK([sh.w makeFirstResponder:pages]);
    clickSegment(sh.w, pages, 0);
    CHECK_EQ(wpe_test_sheet_page(sh.s), NSInteger(0));
    CHECK(sh.w.firstResponder == pages);
    clickSegment(sh.w, pages, 1);
    CHECK_EQ(wpe_test_sheet_page(sh.s), NSInteger(1));
    CHECK(sh.w.firstResponder == pages);
    wpe_test_sheet_select_page(sh.s, 0);  // a shortcut still moves the focus to the page
    CHECK(sh.w.firstResponder == wpe_test_sheet_common_editor(sh.s));
    wpe_test_sheet_select_page(sh.s, 1);
    CHECK(sh.w.firstResponder == sh.table);
    for (NSAppearanceName look in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        ui.w.appearance = [NSAppearance appearanceNamed:look];
        sh.w.appearance = ui.w.appearance;
        checkLabelsCentred(buttons);
    }
    // Plain Return on the list edits (never OK); Command-Return is OK.
    sh.select(0);
    sh.ret();
    CHECK(sh.editing());
    sh.esc();
    CHECK(wpe_test_value_sheet(ui.c) != nil);
    sh.esc();
}

// The close prompt as AppKit lays it out and draws it (offscreen): the Mac's save-changes alert with
// Apply first and the default button, every label centred on its bezel.
TEST(close_prompt_is_the_macs_save_changes_alert) {
    UI ui({tf({{"TITLE", {"x"}}})});
    stageTitle(ui, @"new");
    commandW(ui);
    NSAlert* a = wpe_test_close_prompt(ui.c);
    CHECK(a != nil);
    if (!a || a.buttons.count != 3) return;
    [a layout];
    NSView* content = a.window.contentView;
    [content layoutSubtreeIfNeeded];
    NSButton* apply = a.buttons[0];
    NSButton* cancel = a.buttons[1];
    NSButton* discard = a.buttons[2];
    for (NSButton* b in a.buttons) {
        CHECK([b isDescendantOf:content]);
        CHECK(!b.hidden);
        const NSRect r = [b convertRect:b.bounds toView:content];
        CHECK(NSContainsRect(content.bounds, r));
    }
    CHECK(!NSIntersectsRect(box(apply), box(cancel)));
    CHECK(!NSIntersectsRect(box(cancel), box(discard)));
    CHECK(!NSIntersectsRect(box(apply), box(discard)));
    // Apply comes first: rightmost in a row (a sheet), on top of the stack AppKit uses for an alert of
    // three buttons on its own; where the other two go is AppKit's (Cancel at the bottom of a stack).
    const NSRect ra = [apply convertRect:apply.bounds toView:nil], rc = [cancel convertRect:cancel.bounds toView:nil],
                 rd = [discard convertRect:discard.bounds toView:nil];
    const bool row = std::fabs(NSMidY(ra) - NSMidY(rc)) < 1;
    if (row) {
        CHECK(NSMinX(ra) > NSMinX(rc) && NSMinX(ra) > NSMinX(rd));
    } else {
        CHECK(NSMidY(ra) > NSMidY(rc) && NSMidY(ra) > NSMidY(rd));
    }
    CHECK(a.window.defaultButtonCell == apply.cell || [apply.keyEquivalent isEqualToString:@"\r"]);
    // The labels as AppKit draws them, centred on their bezels.
    for (NSButton* b in a.buttons) checkLabelCentred(b, 2, "alert");
    if (std::getenv("WPE_MEASURE"))
        std::printf("  close prompt: %s, Apply %s, Cancel %s, Don't Apply %s\n", row ? "one row" : "stacked", NSStringFromRect(ra).UTF8String,
                    NSStringFromRect(rc).UTF8String, NSStringFromRect(rd).UTF8String);
    // Drawn: the message is there (the render is not blank).
    double lo = 255, hi = 0;
    NSBitmapImageRep* rep = renderLive(content, content.bounds, 2);
    const RGB under = backdrop(content);
    for (NSInteger y = 0; y < rep.pixelsHigh; y += 3)
        for (NSInteger x = 0; x < rep.pixelsWide; x += 3) {
            const double l = lumaOver(rep, x, y, under);
            lo = std::min(lo, l);
            hi = std::max(hi, l);
        }
    CHECK(hi - lo > 100);
    wpe_test_answer_close_prompt(ui.c, kKeepEditing);
}

namespace {

// A list cell as its row draws it (the row's background and selection under the cell's text), at `scale`.
NSBitmapImageRep* renderCell(NSTableView* t, NSInteger col, NSInteger row, CGFloat scale) {
    [t layoutSubtreeIfNeeded];
    NSTableRowView* rv = [t rowViewAtRow:row makeIfNecessary:YES];
    [rv layoutSubtreeIfNeeded];
    const NSRect cell = col < 0 ? rv.bounds : [rv convertRect:[t frameOfCellAtColumn:col row:row] fromView:t];
    return renderLive(rv, cell, scale);
}

// The lightest and darkest luminance in `rep` (row 0 at the top) inside an inset of `inset` points.
void lumaRange(NSBitmapImageRep* rep, CGFloat scale, CGFloat inset, double& lo, double& hi) {
    lo = 255;
    hi = 0;
    const NSInteger m = std::lround(inset * scale);
    for (NSInteger y = m; y < rep.pixelsHigh - m; ++y)
        for (NSInteger x = m; x < rep.pixelsWide - m; ++x) {
            const double l = luma(rep, x, y);
            lo = std::min(lo, l);
            hi = std::max(hi, l);
        }
}

// The ink rows of a block of text (everything that differs from the background by at least half the
// strongest difference), in points from the top: its first and last rows, sub-pixel by coverage.
bool blockInk(NSBitmapImageRep* rep, CGFloat scale, CGFloat inset, double& top, double& bottom) {
    const NSInteger m = std::lround(inset * scale), w = rep.pixelsWide, h = rep.pixelsHigh;
    std::vector<double> face;
    for (NSInteger y = m; y < h - m; ++y)
        for (NSInteger x = m; x < w - m; ++x) face.push_back(luma(rep, x, y));
    if (face.empty()) return false;
    std::nth_element(face.begin(), face.begin() + face.size() / 2, face.end());
    const double ground = face[face.size() / 2];
    double strongest = 0;
    std::vector<double> row((size_t)h, 0);
    for (NSInteger y = m; y < h - m; ++y)
        for (NSInteger x = m; x < w - m; ++x) {
            const double d = std::fabs(luma(rep, x, y) - ground);
            strongest = std::max(strongest, d);
            row[(size_t)y] = std::max(row[(size_t)y], d);
        }
    if (strongest < 40) return false;
    NSInteger first = -1, last = -1;
    for (NSInteger y = m; y < h - m; ++y)
        if (row[(size_t)y] / strongest >= 0.1) {
            if (first < 0) first = y;
            last = y;
        }
    top = (double(first) + 1 - std::min(1.0, row[(size_t)first] / strongest)) / scale;
    bottom = (double(last) + std::min(1.0, row[(size_t)last] / strongest)) / scale;
    return true;
}

double g_worstCentring = 0;  // largest |cap box centre - centre line| measured, for WPE_MEASURE

// The capitals of a cell's text (its first letter is a flat capital) on the centre line of `height`
// points (the rendered rect's height unless given), as FooquX centres text.
void checkCapsCentred(NSBitmapImageRep* rep, CGFloat scale, NSFont* font, const char* what, CGFloat height = 0) {
    const LabelInk ink = labelInk(rep, scale, font.capHeight, 1, 1);
    CHECK(ink.found);
    if (!ink.found) {
        std::fprintf(stderr, "  no text ink: %s @%gx\n", what, scale);
        return;
    }
    if (height <= 0) height = rep.pixelsHigh / scale;
    // The baseline (the capital's flat bottom, sharp on the pixel grid) is the rule's: the cap box's centre on
    // the centre line, rounded to the nearest device pixel.
    const double baseline = WPECentredBaseline(font, 0, height, scale);
    const double offset = (ink.capTop + ink.capBottom) / 2 - height / 2;
    g_worstCentring = std::max(g_worstCentring, std::fabs(offset));
    const bool ok = std::fabs(ink.capBottom - baseline) <= 0.2 + 0.1 / scale && std::fabs(offset) <= 0.6;
    CHECK(std::fabs(ink.capBottom - baseline) <= 0.2 + 0.1 / scale);
    // As seen (anti-aliased edges included): the capitals within a few tenths of a point of the centre line
    // at 2x and 1x (the Windows placement this replaces sat 1.1 pt low in rows, 0.9 pt high in the header).
    CHECK(std::fabs(offset) <= 0.6);
    CHECK(std::fabs((ink.capBottom - ink.capTop) - font.capHeight) <= 0.5 + 0.5 / scale);
    if (std::getenv("WPE_MEASURE") || !ok)
        std::printf("  %-34s @%gx: cap box %.2f..%.2f of %.1f (centre %+.2f pt), baseline %.2f\n", what, scale, ink.capTop, ink.capBottom,
                    height, offset, baseline);
}

}

// List text is the system font at standard sizes without tracking, and optically centred: the
// capitals' box on the row's centre line (FooquX's rule), in the rows, the header, the Details section
// bands, ReplayGain, Artwork (names and the block of Details lines) and Edit Value, at 1x and 2x, light and
// dark, selected or not.
TEST(list_text_is_optically_centred_in_the_live_window) {
    using namespace wpe::ui;
    NSData* cover = makePNG(600, 600, NSColor.systemTealColor);
    UI ui({tf({{"ARTIST", {"ACME"}}, {"TITLE", {"TEN TO ONE"}}})}, {artWith({{art::FrontCover, picOf(cover)}})});
    ui.backend->details = sampleDetails();
    ui.backend->rg = {gains(-6.54f, 0.987654f)};
    ui.backend->onChange();
    spin(5);
    NSFont* list = WPEListFont();
    g_worstCentring = 0;
    for (NSAppearanceName look in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        ui.w.appearance = [NSAppearance appearanceNamed:look];
        for (CGFloat scale : {1.0, 2.0}) {
            wpe_test_select_tab(ui.c, 0);
            spin(2);
            const NSInteger artist = (NSInteger)ui.row("ARTIST"), title = (NSInteger)ui.row("TITLE");
            checkCapsCentred(renderCell(ui.table, 0, artist, scale), scale, list, "Metadata name (Artist Name)");
            checkCapsCentred(renderCell(ui.table, 1, title, scale), scale, list, "Metadata value (TEN TO ONE)");
            // Selected (the unemphasized grey here, off screen) and emphasized (white on the accent colour).
            ui.select((size_t)title);
            spin(2);
            NSTableRowView* rv = [ui.table rowViewAtRow:title makeIfNecessary:YES];
            checkCapsCentred(renderCell(ui.table, 1, title, scale), scale, list, "selected value");
            rv.emphasized = YES;
            checkCapsCentred(renderCell(ui.table, 1, title, scale), scale, list, "emphasized value");
            rv.emphasized = NO;
            [ui.table deselectAll:nil];
            // The header's titles, on the centre of the header above its bottom line.
            NSTableHeaderView* header = ui.table.headerView;
            const NSRect nameHeader = [header headerRectOfColumn:0];
            checkCapsCentred(renderLive(header, nameHeader, scale), scale, WPEChromeFont(), "header (Name)",
                             NSHeight(nameHeader) - 1 / scale);
            wpe_test_select_tab(ui.c, 1);
            spin(3);
            NSTableView* details = wpe_test_details_table(ui.c);
            checkCapsCentred(renderCell(details, -1, 0, scale), scale, WPEGroupFont(), "Details section (Location)");
            checkCapsCentred(renderCell(details, 0, 1, scale), scale, list, "Details name (File name)");
            wpe_test_select_tab(ui.c, 2);
            spin(3);
            NSTableView* rgTable = wpe_test_rg_table(ui.c);
            checkCapsCentred(renderCell(rgTable, 0, 0, scale), scale, list, "ReplayGain name (Track Gain)");
            checkCapsCentred(renderCell(rgTable, 1, 1, scale), scale, list, "ReplayGain value (0.987654)");
            wpe_test_select_tab(ui.c, 3);
            spin(20);
            NSTableView* artTable = wpe_test_art_table(ui.c);
            checkCapsCentred(renderCell(artTable, 0, 0, scale), scale, list, "Artwork name (Front Cover)");
            // The Details block ("8 KB", "600x600", "PNG"): from the first line's figures to the last line's
            // baseline, centred in the 106 pt row.
            double top = 0, bottom = 0;
            const bool found = blockInk(renderCell(artTable, 2, 0, scale), scale, 1, top, bottom);
            CHECK(found);
            const double offset = (top + bottom) / 2 - kArtRowHeight / 2;
            CHECK(std::fabs(offset) <= 0.6);
            CHECK(bottom - top > 2 * kArtDetailsLineHeight);  // three lines
            if (std::getenv("WPE_MEASURE") || std::fabs(offset) > 0.6)
                std::printf("  %-34s @%gx: ink %.2f..%.2f of %.0f (centre %+.2f pt)\n", "Artwork Details block", scale, top, bottom,
                            kArtRowHeight, offset);
        }
    }
    if (std::getenv("WPE_MEASURE")) std::printf("  worst cap box offset (as seen) %.2f pt\n", g_worstCentring);
}

// The window's colours are the system's semantic colours, and a selected row is the accent fill with
// white text while emphasized, the unemphasized grey with the normal text colours otherwise (FooquX's
// macOS colours), in light and dark mode.
TEST(colours_are_the_systems_and_the_selection_is_the_accent_colour) {
    CHECK([WPEColors.dialog isEqual:NSColor.windowBackgroundColor]);
    CHECK([WPEColors.list isEqual:NSColor.controlBackgroundColor]);
    CHECK([WPEColors.alternateRow isEqual:NSColor.alternatingContentBackgroundColors[1]]);
    CHECK([WPEColors.columnLine isEqual:NSColor.separatorColor]);
    CHECK([WPEColors.headerLine isEqual:NSColor.separatorColor]);
    CHECK([WPEColors.barLine isEqual:NSColor.separatorColor]);
    CHECK([WPEColors.selection isEqual:NSColor.selectedContentBackgroundColor]);
    CHECK([WPEColors.selectionInactive isEqual:NSColor.unemphasizedSelectedContentBackgroundColor]);
    CHECK([WPEColors.sectionBand isEqual:NSColor.windowBackgroundColor]);
    NSData* cover = makePNG(600, 600, NSColor.systemTealColor);
    for (NSAppearanceName look in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        const bool dark = look == NSAppearanceNameDarkAqua;
        UI ui({tf({{"ARTIST", {"ACME"}}, {"TITLE", {"TEN"}}, {"ALBUM", {"ONE"}}}), tf({{"ARTIST", {"BOREAL M"}}, {"TITLE", {"TEN"}}})},
              {artWith({{art::FrontCover, picOf(cover)}}), artWith({{art::FrontCover, picOf(cover)}})});
        ui.w.appearance = [NSAppearance appearanceNamed:look];
        spin(3);
        CHECK([ui.w.backgroundColor isEqual:NSColor.windowBackgroundColor]);
        NSTableView* t = ui.table;
        const CGFloat scale = 2;
        const RGB list = resolved(NSColor.controlBackgroundColor, t);
        // Rows: the list colour, every other row the alternate colour over it, the Name | Value line in the
        // separator colour (one device pixel, left of the Value column).
        NSTableRowView* r0 = [t rowViewAtRow:0 makeIfNecessary:YES];
        NSTableRowView* r1 = [t rowViewAtRow:1 makeIfNecessary:YES];
        NSBitmapImageRep* rep0 = renderLive(r0, r0.bounds, scale);
        NSBitmapImageRep* rep1 = renderLive(r1, r1.bounds, scale);
        const NSInteger farX = rep0.pixelsWide - 20, midY = rep0.pixelsHigh / 2;
        CHECK(distance(pixel(rep0, farX, midY), list) <= 2);
        CHECK(distance(pixel(rep1, farX, midY), resolved(NSColor.alternatingContentBackgroundColors[1], t, list)) <= 2);
        const CGFloat lineX = NSMaxX([t rectOfColumn:0]);
        CHECK(distance(pixel(rep0, std::lround(lineX * scale) - 1, midY), resolved(NSColor.separatorColor, t, list)) <= 3);
        // Header, page band, button bar and its separator.
        NSTableHeaderView* header = t.headerView;
        NSBitmapImageRep* head = renderLive(header, header.bounds, scale);
        CHECK(distance(pixel(head, head.pixelsWide - 20, 4), list) <= 2);
        CHECK(distance(pixel(head, head.pixelsWide - 20, head.pixelsHigh - 1), resolved(NSColor.separatorColor, t, list)) <= 3);
        const RGB window = resolved(NSColor.windowBackgroundColor, t);
        NSView* band = wpe_test_tab_control(ui.c).superview;
        NSBitmapImageRep* bandRep = renderLive(band, band.bounds, scale);
        CHECK(distance(pixel(bandRep, 6, 6), window) <= 2);
        NSView* bar = wpe_test_buttons(ui.c)[1].superview;
        NSBitmapImageRep* barRep = renderLive(bar, bar.bounds, scale);
        CHECK(distance(pixel(barRep, 6, 8), window) <= 2);
        CHECK(distance(pixel(barRep, 6, 0), resolved(NSColor.separatorColor, t, window)) <= 3);
        if (std::getenv("WPE_MEASURE"))
            std::printf("  %s: list %s, alternate %s, window %s\n", look.UTF8String, hex(pixel(rep0, farX, midY)).c_str(),
                        hex(pixel(rep1, farX, midY)).c_str(), hex(pixel(bandRep, 6, 6)).c_str());

        // The selection. Emphasized: the accent fill, every cell's text white (labelColor and the
        // secondary «multiple values» alike). Unemphasized: the grey, the text as it was.
        const NSInteger artist = (NSInteger)ui.row("ARTIST");  // «multiple values» ACME; BOREAL M (secondary)
        ui.select((size_t)artist);
        spin(2);
        NSTableRowView* rv = [t rowViewAtRow:artist makeIfNecessary:YES];
        NSTableCellView* name = cellAt(t, 0, artist);
        NSTableCellView* value = cellAt(t, 1, artist);
        CHECK(rv.selected);
        rv.emphasized = YES;
        CHECK_EQ(rv.interiorBackgroundStyle, NSBackgroundStyleEmphasized);
        CHECK_EQ(name.backgroundStyle, NSBackgroundStyleEmphasized);
        CHECK_EQ(name.textField.cell.backgroundStyle, NSBackgroundStyleEmphasized);
        double lo = 0, hi = 0;
        for (NSInteger col : {0, 1}) {
            NSBitmapImageRep* rep = renderCell(t, col, artist, scale);
            CHECK(distance(pixel(rep, rep.pixelsWide - 4, rep.pixelsHigh / 2), resolved(NSColor.selectedContentBackgroundColor, t)) <= 2);
            lumaRange(rep, scale, 1, lo, hi);
            // White text on the accent colour: labelColor fully, the secondary «multiple values» a little translucent.
            const double white = col == 0 ? 225 : 190;
            CHECK(hi >= white);
            if (std::getenv("WPE_MEASURE") || hi < white) std::printf("  emphasized column %ld: luma %.0f..%.0f\n", (long)col, lo, hi);
        }
        rv.emphasized = NO;
        CHECK_EQ(rv.interiorBackgroundStyle, NSBackgroundStyleNormal);
        CHECK_EQ(value.textField.cell.backgroundStyle, NSBackgroundStyleNormal);
        {
            NSBitmapImageRep* rep = renderCell(t, 0, artist, scale);
            CHECK(distance(pixel(rep, rep.pixelsWide - 4, rep.pixelsHigh / 2), resolved(NSColor.unemphasizedSelectedContentBackgroundColor, t)) <=
                  2);
            lumaRange(rep, scale, 1, lo, hi);
            if (dark) CHECK(hi >= 200);  // the label colour: light text on the dark grey
            else CHECK(lo <= 90);        // dark text on the light grey
        }
        // The add row's glyph turns white with the text.
        const NSInteger add = t.numberOfRows - 1;
        ui.select((size_t)add);
        spin(2);
        NSTableRowView* addRow = [t rowViewAtRow:add makeIfNecessary:YES];
        NSTableCellView* addCell = cellAt(t, 0, add);
        addRow.emphasized = YES;
        CHECK([addCell.imageView.contentTintColor isEqual:NSColor.alternateSelectedControlTextColor]);
        addRow.emphasized = NO;
        CHECK([addCell.imageView.contentTintColor isEqual:NSColor.secondaryLabelColor]);
        [t deselectAll:nil];

        // Artwork: on the accent fill the ⊕ and ⊗ glyphs are white (a little translucent, opaque while pressed).
        wpe_test_select_tab(ui.c, 3);
        spin(20);
        NSTableView* artTable = wpe_test_art_table(ui.c);
        for (NSInteger row : {0, 1}) {
            [artTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
            spin(2);
            NSButton* glyph = row == 0 ? cellButton(artTable, 3, 0) : cellButton(artTable, 1, 1);
            NSTableRowView* artRow = [artTable rowViewAtRow:row makeIfNecessary:YES];
            artRow.emphasized = YES;
            CHECK_EQ(glyph.cell.backgroundStyle, NSBackgroundStyleEmphasized);
            CHECK(distance(resolved(glyph.contentTintColor, glyph, {0, 0, 0}), {191, 191, 191}) <= 2);
            [glyph highlight:YES];
            CHECK([glyph.contentTintColor isEqual:NSColor.alternateSelectedControlTextColor]);
            [glyph highlight:NO];
            artRow.emphasized = NO;
            CHECK([glyph.contentTintColor isEqual:NSColor.tertiaryLabelColor]);
        }
    }
}

namespace {

// AppKit's focus ring around `field`'s mask, drawn (NSSetFocusRingStyle) into a bitmap `margin` points larger
// than the field on every side: where its ink is, in the field's coordinates (top-left origin).
bool focusRingInk(NSTextField* field, CGFloat scale, NSRect& ink) {
    const CGFloat margin = 10;
    const NSSize size = NSMakeSize(NSWidth(field.bounds) + 2 * margin, NSHeight(field.bounds) + 2 * margin);
    NSBitmapImageRep* blank = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
                                                                      pixelsWide:std::lround(size.width * scale)
                                                                      pixelsHigh:std::lround(size.height * scale)
                                                                   bitsPerSample:8
                                                                 samplesPerPixel:4
                                                                        hasAlpha:YES
                                                                        isPlanar:NO
                                                                  colorSpaceName:NSCalibratedRGBColorSpace
                                                                     bytesPerRow:0
                                                                    bitsPerPixel:0];
    NSBitmapImageRep* rep = [blank bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace];
    rep.size = size;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    NSAffineTransform* move = [NSAffineTransform transform];
    // The field is flipped: draw its mask in its own coordinates.
    [move translateXBy:margin yBy:margin + NSHeight(field.bounds)];
    [move scaleXBy:1 yBy:-1];
    [move concat];
    [field.effectiveAppearance performAsCurrentDrawingAppearance:^{
        NSSetFocusRingStyle(NSFocusRingOnly);
        [field drawFocusRingMask];
    }];
    [NSGraphicsContext restoreGraphicsState];
    NSInteger x0 = -1, x1 = -1, y0 = -1, y1 = -1;
    for (NSInteger y = 0; y < rep.pixelsHigh; ++y)
        for (NSInteger x = 0; x < rep.pixelsWide; ++x) {
            NSUInteger p[4] = {};
            [rep getPixel:p atX:x y:y];
            if (p[3] < 24) continue;
            if (x0 < 0 || x < x0) x0 = x;
            if (x > x1) x1 = x;
            if (y0 < 0) y0 = y;
            y1 = y;
        }
    if (x0 < 0) return false;
    ink = NSMakeRect(x0 / scale - margin, y0 / scale - margin, (x1 + 1 - x0) / scale, (y1 + 1 - y0) / scale);
    return true;
}

// An inline editor in a list cell: it is the cell's text field, filling the cell, drawn in the text background
// colour over the whole cell (no selection colour above or below it, also in an emphasized row, where its
// text stays the text colour), the field editor exactly on the label's text rect, and a focus ring that ends
// at the cell's edges.
void checkInlineEditor(NSTableView* t, NSInteger col, NSInteger row, const char* what) {
    using namespace wpe::ui;
    const size_t before = (size_t)wpetest::failures();
    NSTableCellView* cell = cellAt(t, col, row);
    NSTextField* field = cell.textField;
    NSText* fe = field.currentEditor;
    CHECK(fe != nil);
    if (!fe) return;
    [cell layoutSubtreeIfNeeded];
    CHECK(NSEqualRects(field.frame, cell.bounds));
    CHECK(field.editable && field.drawsBackground);
    CHECK([field.backgroundColor isEqual:NSColor.textBackgroundColor]);
    const NSRect textRect = [field.cell titleRectForBounds:field.bounds];
    const NSRect editorRect = [field convertRect:fe.bounds fromView:fe];
    CHECK(std::fabs(NSMinX(editorRect) - NSMinX(textRect)) < 0.01);
    CHECK(std::fabs(NSMinY(editorRect) - NSMinY(textRect)) < 0.01);
    CHECK(std::fabs(NSHeight(editorRect) - NSHeight(textRect)) < 0.01);
    if ([fe isKindOfClass:[NSTextView class]]) CHECK_EQ(((NSTextView*)fe).textContainer.lineFragmentPadding, kTextPadding);
    // Drawn: the text background from the cell's top to its bottom, in a selected and in an emphasized row.
    NSTableRowView* rv = [t rowViewAtRow:row makeIfNecessary:YES];
    CHECK(rv.selected);
    const RGB paper = resolved(NSColor.textBackgroundColor, t);
    for (BOOL emphasized : {NO, YES}) {
        rv.emphasized = emphasized;
        CHECK_EQ(field.cell.backgroundStyle, NSBackgroundStyleNormal);
        NSBitmapImageRep* rep = renderCell(t, col, row, 2);
        const NSInteger x = rep.pixelsWide - 6;
        CHECK(distance(pixel(rep, x, 0), paper) <= 2);
        CHECK(distance(pixel(rep, x, rep.pixelsHigh - 1), paper) <= 2);
        CHECK(distance(pixel(rep, x, rep.pixelsHigh / 2), paper) <= 2);
    }
    rv.emphasized = NO;
    // The focus ring: its mask is the cell inset by kEditorRingInset, and AppKit's ring around it reaches the
    // cell's edges but not past them (in this design, at 1x and 2x).
    CHECK(field.focusRingType != NSFocusRingTypeNone);
    CHECK(NSEqualRects(field.focusRingMaskBounds, NSInsetRect(field.bounds, kEditorRingInset, kEditorRingInset)));
    for (CGFloat scale : {1.0, 2.0}) {
        NSRect ring = NSZeroRect;
        const bool drawn = focusRingInk(field, scale, ring);
        CHECK(drawn);
        if (!drawn) continue;
        CHECK(NSMinX(ring) >= -0.01 && NSMinY(ring) >= -0.01);
        CHECK(NSMaxX(ring) <= NSWidth(field.bounds) + 0.01 && NSMaxY(ring) <= NSHeight(field.bounds) + 0.01);
        CHECK(NSMinX(ring) <= kEditorRingInset - 1.5 && NSMinY(ring) <= kEditorRingInset - 1.5);  // a visible ring
        if (std::getenv("WPE_MEASURE"))
            std::printf("  %-22s focus ring @%gx: %s in a cell of %s\n", what, scale, NSStringFromRect(ring).UTF8String,
                        NSStringFromSize(field.bounds.size).UTF8String);
    }
    if ((size_t)wpetest::failures() != before) std::fprintf(stderr, "  inline editor: %s\n", what);
}

// After an edit: a label again (no background, no focus ring, the row's background style).
void checkLabelAgain(NSTableView* t, NSInteger col, NSInteger row) {
    NSTextField* field = cellAt(t, col, row).textField;
    CHECK(!field.editable && !field.selectable && !field.drawsBackground);
    CHECK_EQ(field.focusRingType, NSFocusRingTypeNone);
    CHECK(NSIsEmptyRect(field.focusRingMaskBounds));
}

// The first letter's ink (left edge and cap box) of a cell, rendered at 2x as its row draws it.
LabelInk cellInk(NSTableView* t, NSInteger col, NSInteger row) {
    return labelInk(renderCell(t, col, row, 2), 2, WPEListFont().capHeight, 1, 1);
}

void checkSameInk(const LabelInk& a, const LabelInk& b, const char* what) {
    CHECK(a.found && b.found);
    if (!a.found || !b.found) return;
    // To the device pixel: the editor draws the text where the label did.
    CHECK(std::fabs(a.left - b.left) <= 0.26);
    CHECK(std::fabs(a.capTop - b.capTop) <= 0.26);
    CHECK(std::fabs(a.capBottom - b.capBottom) <= 0.26);
    if (std::getenv("WPE_MEASURE") || std::fabs(a.left - b.left) > 0.26 || std::fabs(a.capTop - b.capTop) > 0.26)
        std::printf("  %-22s label x %.2f caps %.2f..%.2f, editor x %.2f caps %.2f..%.2f\n", what, a.left, a.capTop, a.capBottom, b.left,
                    b.capTop, b.capBottom);
}

void collapseSelection(NSText* editor) {
    if (editor) editor.selectedRange = NSMakeRange(editor.string.length, 0);
}

WPEEditorScrollView* overlayIn(NSWindow* w) {
    for (NSView* v in w.contentView.subviews)
        if ([v isKindOfClass:[WPEEditorScrollView class]]) return (WPEEditorScrollView*)v;
    return nil;
}

}

// Starting an edit moves nothing. The single-line editor is the cell's own text field filling the
// cell, its text exactly where the label's was, with a focus ring inside the cell; on the Metadata list
// (values and names), ReplayGain and Edit Value alike. After the edit it is a label again.
TEST(inline_editors_fill_their_cell_and_keep_the_text_in_place) {
    UI ui({tf({{"TITLE", {"TEN TO ONE"}}, {"MOOD", {"CALM"}}})});
    ui.w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    spin(2);
    // A Metadata value: clicked, it edits at once.
    const NSInteger title = (NSInteger)ui.row("TITLE");
    const LabelInk label = cellInk(ui.table, 1, title);
    ui.click((size_t)title, 1);
    CHECK_EQ(ui.editRow(), title);
    NSTextField* field = cellAt(ui.table, 1, title).textField;
    collapseSelection(field.currentEditor);
    checkSameInk(label, cellInk(ui.table, 1, title), "Metadata value");
    checkInlineEditor(ui.table, 1, title, "Metadata value");
    ui.ret();  // commits and opens the next row's value: the same editor, filling its cell
    CHECK_EQ(ui.editRow(), title + 1);
    checkInlineEditor(ui.table, 1, title + 1, "next value");
    ui.esc();
    spin(2);
    checkLabelAgain(ui.table, 1, title);
    checkLabelAgain(ui.table, 1, title + 1);
    CHECK_EQ(cellText(ui.table, 1, title), std::string("TEN TO ONE"));
    // A name (renaming a field of one track): the same editor in the Name column.
    const NSInteger mood = (NSInteger)ui.row("MOOD");
    ui.click((size_t)mood, 0, 2);
    CHECK_EQ(ui.editCol(), NSInteger(0));
    checkInlineEditor(ui.table, 0, mood, "Metadata name");
    ui.esc();
    spin(2);
    checkLabelAgain(ui.table, 0, mood);

    // ReplayGain: a peak value (its editor text is the shown text).
    ui.backend->rg = {gains(-6.54f, 0.987654f)};
    ui.backend->onChange();
    spin(5);
    wpe_test_select_tab(ui.c, 2);
    spin(3);
    NSTableView* rgTable = wpe_test_rg_table(ui.c);
    const LabelInk peak = cellInk(rgTable, 1, 1);
    clickCell(ui, rgTable, 1, 1);
    CHECK_EQ(wpe_test_rg_edit_row(ui.c), NSInteger(1));
    collapseSelection(cellAt(rgTable, 1, 1).textField.currentEditor);
    checkSameInk(peak, cellInk(rgTable, 1, 1), "ReplayGain value");
    checkInlineEditor(rgTable, 1, 1, "ReplayGain value");
    ui.esc();
    spin(2);
    checkLabelAgain(rgTable, 1, 1);
}

TEST(edit_value_inline_editor_fills_its_cell) {
    UI ui({tf({{"ARTIST", {"ACME"}}}), tf({{"ARTIST", {"BOREAL M"}}})});
    ui.w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    ui.click(ui.row("ARTIST"), 0, 2);
    Sheet sh(ui);
    CHECK(sh.open());
    if (!sh.open()) return;
    sh.w.appearance = ui.w.appearance;
    spin(3);
    const LabelInk label = cellInk(sh.table, 1, 0);
    sh.click(0, 1);
    CHECK(sh.editing());
    collapseSelection(cellAt(sh.table, 1, 0).textField.currentEditor);
    checkSameInk(label, cellInk(sh.table, 1, 0), "Edit Value value");
    checkInlineEditor(sh.table, 1, 0, "Edit Value value");
    sh.esc();
    spin(2);
    checkLabelAgain(sh.table, 1, 0);
    sh.esc();
}

// A multi-line value is edited in a text view floating over its cell (the Value column's width, from
// the row's top): no legacy bezel, a hairline frame, a soft shadow and the focus ring, its first line where
// the cell showed the text. The Edit Value sheet's overlay is the same.
TEST(multiline_editors_float_over_the_cell_without_moving_the_text) {
    using namespace wpe::ui;
    UI ui({tf({{"COMMENT", {"LINE ONE\nLINE TWO"}}, {"TITLE", {"T"}}})});
    ui.w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    spin(2);
    const NSInteger row = (NSInteger)ui.row("COMMENT");
    NSTableView* t = ui.table;
    [ui.w.contentView layoutSubtreeIfNeeded];
    const NSRect cellInWindow = [t convertRect:[t frameOfCellAtColumn:1 row:row] toView:nil];
    const LabelInk label = cellInk(t, 1, row);
    ui.select((size_t)row);
    ui.ret();
    CHECK(wpe_test_multiline(ui.c));
    WPEEditorScrollView* overlay = overlayIn(ui.w);
    CHECK(overlay != nil);
    if (!overlay) return;
    NSView* content = ui.w.contentView;
    const NSRect cell = [content convertRect:cellInWindow fromView:nil];
    const NSRect frame = overlay.frame;
    CHECK(std::fabs(NSMinX(frame) - NSMinX(cell)) < 0.01);
    CHECK(std::fabs(NSWidth(frame) - NSWidth(cell)) < 0.01);
    CHECK(std::fabs(NSMaxY(frame) - NSMaxY(cell)) < 0.01);  // from the row's top down (the content view is not flipped)
    CHECK(NSHeight(frame) >= 96);
    CHECK_EQ(overlay.borderType, NSNoBorder);
    CHECK(overlay.wpeFloating && overlay.shadow != nil);
    CHECK(overlay.wpeFrameLine.superview == overlay && overlay.subviews.lastObject == overlay.wpeFrameLine);
    CHECK([overlay.wpeFrameLine hitTest:NSMakePoint(5, 5)] == nil);
    CHECK_EQ(overlay.focusRingType, NSFocusRingTypeExterior);
    CHECK(NSEqualRects(overlay.focusRingMaskBounds, overlay.bounds));
    NSTextView* tv = overlay.documentView;
    CHECK(ui.w.firstResponder == tv);
    CHECK_EQ(tv.focusRingType, NSFocusRingTypeExterior);
    CHECK_EQ(tv.textContainer.lineFragmentPadding, kTextPadding);
    CHECK(!tv.automaticQuoteSubstitutionEnabled && !tv.automaticSpellingCorrectionEnabled && !tv.richText);
    // Its first line where the cell's text was: the same window rect rendered from the overlay.
    tv.selectedRange = NSMakeRange(0, 0);
    [overlay layoutSubtreeIfNeeded];
    NSBitmapImageRep* rep = renderLive(overlay, [overlay convertRect:cellInWindow fromView:nil], 2);
    checkSameInk(label, labelInk(rep, 2, WPEListFont().capHeight, 1, 1), "multi-line overlay");
    // Its hairline frame and the text background, drawn.
    NSBitmapImageRep* whole = renderLive(overlay, overlay.bounds, 2);
    const RGB paper = resolved(NSColor.textBackgroundColor, overlay);
    CHECK(distance(pixel(whole, whole.pixelsWide / 2, whole.pixelsHigh - 6), paper) <= 2);
    CHECK(distance(pixel(whole, whole.pixelsWide / 2, whole.pixelsHigh - 1), resolved(NSColor.separatorColor, overlay, paper)) <= 3);
    CHECK(distance(pixel(whole, 0, whole.pixelsHigh / 2), resolved(NSColor.separatorColor, overlay, paper)) <= 3);
    ui.esc();
    spin(2);
    CHECK(overlayIn(ui.w) == nil);
    CHECK(!ui.editing());

    // The Edit Value sheet: the same overlay over its Value column.
    UI two({tf({{"COMMENT", {"A\nB"}}}), tf({{"COMMENT", {"C"}}})});
    two.click(two.row("COMMENT"), 0, 2);
    Sheet sh(two);
    CHECK(sh.open());
    if (!sh.open()) return;
    sh.select(0);
    sh.ret();
    CHECK(wpe_test_sheet_multiline(sh.s));
    WPEEditorScrollView* sheetOverlay = overlayIn(sh.w);
    CHECK(sheetOverlay != nil && sheetOverlay.wpeFloating && sheetOverlay.borderType == NSNoBorder);
    if (sheetOverlay) {
        const NSRect c = [sh.w.contentView convertRect:[sh.table frameOfCellAtColumn:1 row:0] fromView:sh.table];
        CHECK(std::fabs(NSMinX(sheetOverlay.frame) - NSMinX(c)) < 0.01);
        CHECK(std::fabs(NSWidth(sheetOverlay.frame) - NSWidth(c)) < 0.01);
    }
    sh.esc();
    sh.esc();
}

// Edit Value's Common value is a text area inset from the page's edges (so its frame and focus ring
// sit on the window's background), with its text kTextAreaTextInset from its frame.
TEST(edit_value_common_value_is_an_inset_text_area) {
    using namespace wpe::ui;
    UI ui({tf({{"ARTIST", {"ACME"}}}), tf({{"ARTIST", {"ACME"}}})});
    ui.w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    ui.click(ui.row("ARTIST"), 0, 2);
    Sheet sh(ui);
    CHECK(sh.open());
    if (!sh.open()) return;
    sh.w.appearance = ui.w.appearance;
    wpe_test_sheet_select_page(sh.s, 0);
    spin(3);
    NSTextView* tv = wpe_test_sheet_common_editor(sh.s);
    WPEEditorScrollView* area = (WPEEditorScrollView*)tv.enclosingScrollView;
    CHECK([area isKindOfClass:[WPEEditorScrollView class]]);
    if (![area isKindOfClass:[WPEEditorScrollView class]]) return;
    [sh.w.contentView layoutSubtreeIfNeeded];
    const NSRect page = area.superview.bounds, f = area.frame;
    CHECK(std::fabs(NSMinX(f) - kTextAreaMargin) < 0.01);
    CHECK(std::fabs(NSMaxX(page) - NSMaxX(f) - kTextAreaMargin) < 0.01);
    CHECK(std::fabs(NSMinY(f) - kTextAreaMargin) < 0.01);
    CHECK(std::fabs(NSMaxY(page) - NSMaxY(f) - kTextAreaMargin) < 0.01);
    CHECK(!area.wpeFloating && area.shadow == nil);
    CHECK_EQ(area.borderType, NSNoBorder);
    CHECK(area.wpeFrameLine.superview == area);
    CHECK_EQ(tv.focusRingType, NSFocusRingTypeExterior);
    CHECK(NSEqualRects(area.focusRingMaskBounds, area.bounds));
    CHECK(sh.w.firstResponder == tv);
    CHECK_EQ(tv.textContainer.lineFragmentPadding, kTextPadding);
    CHECK(NSEqualSizes(tv.textContainerInset, NSMakeSize(kTextAreaTextInset - kTextPadding, kTextAreaTextInset)));
    CHECK_EQ(str(tv.string), std::string("ACME"));
    // Drawn: the first letter starts kTextAreaTextInset in, the first line's top kTextAreaTextInset down.
    tv.selectedRange = NSMakeRange(0, 0);
    NSFont* font = WPEListFont();
    const LabelInk ink = labelInk(renderLive(area, area.bounds, 2), 2, font.capHeight, 1, 1);
    CHECK(ink.found);
    CHECK(ink.left >= kTextAreaTextInset - 0.3 && ink.left <= kTextAreaTextInset + 1);
    const double baselineOffset = -WPELineTop(font, 0);  // TextKit's, from a line's top to its baseline
    const double capTop = kTextAreaTextInset + baselineOffset - font.capHeight;
    CHECK(std::fabs(ink.capTop - capTop) <= 0.5);
    if (std::getenv("WPE_MEASURE"))
        std::printf("  Common value: text area %s in %s, first letter x %.2f, caps %.2f..%.2f\n", NSStringFromRect(f).UTF8String,
                    NSStringFromRect(page).UTF8String, ink.left, ink.capTop, ink.capBottom);
    sh.esc();
}

namespace {

// A whole-window capture leaves out layer content (scroll views on recent macOS), so the views that
// draw it are rendered one by one and composed over the content view's own capture. Everything is
// rendered live at 2x with renderLive, as the bar tests measure it; the page band and the button bar are
// rendered from their own views too, so the review images show exactly what those tests checked.
void snapshot(NSWindow* w, NSArray<NSView*>* parts, NSString* path) {
    const CGFloat scale = 2;
    NSView* root = w.contentView;
    [root layoutSubtreeIfNeeded];
    [root displayIfNeeded];
    NSBitmapImageRep* canvas = renderLive(root, root.bounds, scale);
    NSMutableArray<NSView*>* all = [parts mutableCopy];
    // A scrolled table's visible rect reaches under its header, so the header goes over it; floating group
    // rows (Details) live in their scroll view's floating container, not in the table.
    for (NSView* part in parts) {
        if (![part isKindOfClass:[NSTableView class]] || ((NSTableView*)part).enclosingScrollView.hidden) continue;
        NSTableView* t = (NSTableView*)part;
        if (t.headerView) [all addObject:t.headerView];
        for (NSView* v in t.enclosingScrollView.subviews)
            if ([NSStringFromClass([v class]) containsString:@"Floating"]) [all addObjectsFromArray:v.subviews];
    }
    for (NSView* v in root.subviews)
        if ([v isKindOfClass:[WPEBarView class]]) [all addObject:v];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:canvas];
    for (NSView* part in all) {
        const NSRect visible = part.visibleRect;
        if (NSIsEmptyRect(visible)) continue;
        NSBitmapImageRep* rep = renderLive(part, visible, scale);
        [rep drawInRect:[part convertRect:visible toView:root]
               fromRect:NSZeroRect
              operation:NSCompositingOperationSourceOver
               fraction:1
         respectFlipped:YES
                  hints:nil];
    }
    [NSGraphicsContext restoreGraphicsState];
    [[canvas representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

void writePNG(NSBitmapImageRep* rep, NSString* path) {
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

}

// Details: a section header stays at the top while its lines scroll under it, as an opaque band in the
// Mac group-row style.
TEST(details_section_headers_float_as_an_opaque_band) {
    UI ui({tf({{"TITLE", {"t"}}})});
    ui.w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    ui.backend->details = sampleDetails();
    for (int i = 0; i < 40; ++i) ui.backend->details.push_back({"General", double(10 + i), "Line " + std::to_string(i), "v"});
    wpe_test_select_tab(ui.c, 1);
    spin(5);
    NSTableView* t = wpe_test_details_table(ui.c);
    CHECK(t.floatsGroupRows);
    const auto& lines = wpe_test_details(ui.c);
    NSInteger general = -1;
    for (size_t i = 0; i < lines.size(); ++i)
        if (lines[i].header && lines[i].name == "General") general = (NSInteger)i;
    CHECK(general > 0);
    if (general <= 0) return;
    [t scrollRowToVisible:general + 30];
    spin(5);
    [ui.w.contentView layoutSubtreeIfNeeded];
    NSTableRowView* r = [t rowViewAtRow:general makeIfNecessary:NO];
    CHECK(r != nil && r.floating);
    if (!r) return;
    CHECK([[r valueForKey:@"wpeBand"] boolValue]);
    // It sits at the top of the visible list, just under the list header, over the lines scrolled under it.
    const NSRect band = [r convertRect:r.bounds toView:nil];
    const NSRect header = [t.headerView convertRect:t.headerView.bounds toView:nil];
    CHECK(std::fabs(NSMaxY(band) - NSMinY(header)) <= 0.5);
    const NSRect natural = [t convertRect:[t rectOfRow:general] toView:nil];
    CHECK(NSMinY(natural) >= NSMinY(header) - 0.5);  // where the row itself is: scrolled out of view
    CHECK(![t isRowSelected:general]);
    // AppKit's blur banner behind floating group rows is hidden: the band is drawn opaque.
    for (NSView* v in r.subviews)
        if (![v isKindOfClass:[NSTableCellView class]]) CHECK(v.hidden);
    NSBitmapImageRep* rep = renderLive(r, r.bounds, 2);
    NSUInteger px[4] = {};
    [rep getPixel:px atX:rep.pixelsWide * 3 / 4 y:rep.pixelsHigh / 2];
    CHECK_EQ(px[3], NSUInteger(255));
    // The window's colour (ECECEC in the classic design, light).
    CHECK(distance(pixel(rep, rep.pixelsWide * 3 / 4, rep.pixelsHigh / 2), resolved(WPEColors.sectionBand, r)) <= 2);
    NSTableCellView* cell = [r viewAtColumn:0];
    CHECK_EQ(str(cell.textField.stringValue), std::string("General"));
    CHECK([cell.textField.font isEqual:WPEGroupFont()]);
}

TEST(zz_snapshots_for_review) {
    const char* dir = std::getenv("WPE_SNAPSHOT_DIR");
    if (!dir) return;
    NSString* out = @(dir);
    // WPE_SNAPSHOT_SIZE=WxH renders the pages at another content size (the README screenshot uses 720x540).
    NSSize pageSize = NSMakeSize(1091, 648);
    if (const char* size = std::getenv("WPE_SNAPSHOT_SIZE")) {
        double width = 0, height = 0;
        if (std::sscanf(size, "%lfx%lf", &width, &height) == 2 && width >= 480 && height >= 360)
            pageSize = NSMakeSize(width, height);
    }
    for (NSString* look in @[ @"light", @"dark" ]) {
        NSData* cover = makePNG(600, 600, [NSColor colorWithSRGBRed:0.1 green:0.55 blue:0.6 alpha:1]);
        // Made-up tags (no real artist, album or file) and a plain generated cover.
        UI ui({tf({{"ARTIST", {"The Example Ensemble"}}, {"TITLE", {"First Light"}},
                   {"ALBUM", {"Synthetic Sessions"}}, {"DATE", {"2026"}}, {"GENRE", {"Ambient"}}, {"ALBUM ARTIST", {"The Example Ensemble"}},
                   {"TRACKNUMBER", {"03"}}, {"TOTALTRACKS", {"10"}}, {"DISCNUMBER", {"1"}}, {"TOTALDISCS", {"1"}},
                   {"MOOD", {"Calm"}}, {"STYLE", {"Drone", "Minimal"}}})},
              {artWith({{art::FrontCover, picOf(cover)}})});
        ui.w.appearance = [NSAppearance appearanceNamed:[look isEqualToString:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        [ui.w setContentSize:pageSize];
        [ui.w makeFirstResponder:ui.table];  // nothing selected, as when the Windows dialog opens
        spin(10);
        snapshot(ui.w, @[ wpe_test_tab_control(ui.c), ui.table, wpe_test_art_table(ui.c) ],
                 [out stringByAppendingPathComponent:[NSString stringWithFormat:@"metadata-%@.png", look]]);
        // Two rows selected: the accent fill (emphasized, as in the key window) and the unemphasized grey.
        [ui.table selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)] byExtendingSelection:NO];
        spin(3);
        for (BOOL emphasized : {YES, NO}) {
            for (NSInteger r : {1, 2}) [ui.table rowViewAtRow:r makeIfNecessary:YES].emphasized = emphasized;
            snapshot(ui.w, @[ wpe_test_tab_control(ui.c), ui.table ],
                     [out stringByAppendingPathComponent:[NSString stringWithFormat:@"metadata-selected-%@-%@.png",
                                                                                    emphasized ? @"accent" : @"unemphasized", look]]);
        }
        // Editing a value (the editor fills its cell; the row is selected and emphasized as in the key window),
        // then a multi-line value in its overlay.
        ui.click(ui.row("ALBUM"), 1);
        collapseSelection(cellAt(ui.table, 1, (NSInteger)ui.row("ALBUM")).textField.currentEditor);
        [ui.table rowViewAtRow:(NSInteger)ui.row("ALBUM") makeIfNecessary:YES].emphasized = YES;
        snapshot(ui.w, @[ wpe_test_tab_control(ui.c), ui.table ],
                 [out stringByAppendingPathComponent:[NSString stringWithFormat:@"metadata-editing-%@.png", look]]);
        ui.esc();
        ui.select(ui.row("GENRE"));
        ui.ret();
        collapseSelection(cellAt(ui.table, 1, (NSInteger)ui.row("GENRE")).textField.currentEditor);
        ui.ret(NSEventModifierFlagOption);  // a line break after the text: the multi-line overlay
        if (WPEEditorScrollView* overlay = overlayIn(ui.w)) {
            NSTextView* tv = overlay.documentView;
            [tv insertText:@"second line" replacementRange:tv.selectedRange];
            snapshot(ui.w, @[ wpe_test_tab_control(ui.c), ui.table, overlay ],
                     [out stringByAppendingPathComponent:[NSString stringWithFormat:@"metadata-multiline-%@.png", look]]);
        }
        ui.esc();  // cancels the edit only
        [ui.table deselectAll:nil];
        ui.backend->details = {
            {"Location", 0, "File name", "03 First Light.flac"},
            {"Location", 1, "Folder name", "/Music/The Example Ensemble/Synthetic Sessions"},
            {"Location", 2, "File path", "/Music/The Example Ensemble/Synthetic Sessions/03 First Light.flac"},
            {"Location", 3, "Subsong index", "0"},
            {"Location", 4, "File size", "30.1 MB (31 562 240 bytes)"},
            {"Location", 5, "Last modified", "2026-01-01 12:00:00"},
            {"General", 0, "Items selected", "1"},
            {"General", 1, "Duration", "4:05.000 (10 804 500 samples)"},
            {"General", 2, "Sample rate", "44100 Hz"},
            {"General", 3, "Channels", "2"},
            {"General", 4, "Bits per sample", "16"},
            {"General", 5, "Bitrate", "1030 kbps"},
            {"General", 6, "Codec", "FLAC"},
            {"General", 7, "Encoding", "lossless"},
            {"ReplayGain", 0, "Track gain", "-7.50 dB"},
            {"ReplayGain", 1, "Track peak", "0.950000"},
            {"Playback statistics", 0, "Play count", "3"},
        };
        ui.backend->rg = {gains(-7.5f, 0.95f, -7.25f, 0.98f)};
        ui.backend->onChange();
        spin(10);
        wpe_test_select_tab(ui.c, 1);
        spin(10);
        snapshot(ui.w, @[ wpe_test_tab_control(ui.c), wpe_test_details_table(ui.c) ],
                 [out stringByAppendingPathComponent:[NSString stringWithFormat:@"details-%@.png", look]]);
        // Scrolled in a short window: the General header floats over its lines.
        [ui.w setContentSize:NSMakeSize(1091, 330)];
        spin(5);
        [wpe_test_details_table(ui.c) scrollRowToVisible:13];
        spin(10);
        snapshot(ui.w, @[ wpe_test_tab_control(ui.c), wpe_test_details_table(ui.c) ],
                 [out stringByAppendingPathComponent:[NSString stringWithFormat:@"details-scrolled-%@.png", look]]);
        [ui.w setContentSize:NSMakeSize(1091, 648)];
        spin(5);
        wpe_test_select_tab(ui.c, 2);
        spin(10);
        snapshot(ui.w, @[ wpe_test_tab_control(ui.c), wpe_test_rg_table(ui.c) ],
                 [out stringByAppendingPathComponent:[NSString stringWithFormat:@"replaygain-%@.png", look]]);
        wpe_test_select_tab(ui.c, 3);
        spin(40);
        snapshot(ui.w, @[ wpe_test_tab_control(ui.c), ui.table, wpe_test_art_table(ui.c) ],
                 [out stringByAppendingPathComponent:[NSString stringWithFormat:@"artwork-%@.png", look]]);
        [wpe_test_art_table(ui.c) selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
        ui.backspace();
        [ui.w setContentSize:NSMakeSize(800, 624)];
        spin(10);
        snapshot(ui.w, @[ wpe_test_tab_control(ui.c), ui.table, wpe_test_art_table(ui.c) ],
                 [out stringByAppendingPathComponent:[NSString stringWithFormat:@"artwork-small-%@.png", look]]);
    }
    // The bottom of the live window (the content view rendered as it is, nothing composed): the end of
    // the Artwork list and the button bar with its status line, at 916 pt and at 1092 pt (the width of the
    // Windows screenshots the lists were measured from); and each button alone. All at 2x.
    for (NSString* look in @[ @"light", @"dark" ]) {
        NSData* cover = makePNG(600, 600, [NSColor colorWithSRGBRed:0.1 green:0.55 blue:0.6 alpha:1]);
        UI ui({tf({{"TITLE", {"t"}}})}, {artWith({{art::FrontCover, picOf(cover)}})});
        ui.w.appearance = [NSAppearance appearanceNamed:[look isEqualToString:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        wpe_test_select_tab(ui.c, 3);
        for (CGFloat width : {916.0, 1092.0}) {
            [ui.w setContentSize:NSMakeSize(width, 600)];
            [ui.w makeFirstResponder:wpe_test_art_table(ui.c)];
            spin(20);
            NSView* root = ui.w.contentView;
            [root layoutSubtreeIfNeeded];
            const CGFloat strip = NSHeight(wpe_test_buttons(ui.c)[1].superview.frame) + 40;
            writePNG(renderLive(root, NSMakeRect(0, 0, width, strip), 2),
                     [out stringByAppendingPathComponent:[NSString stringWithFormat:@"buttons-%g-%@.png", width, look]]);
        }
        for (NSButton* b in wpe_test_buttons(ui.c))
            writePNG(renderLive(b, b.bounds, 2), [out stringByAppendingPathComponent:[NSString stringWithFormat:@"button-%@-%@.png", b.title, look]]);
        // With news in the status line: a staged picture removal (Apply enabled).
        [wpe_test_art_table(ui.c) selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [ui.w makeFirstResponder:wpe_test_art_table(ui.c)];
        ui.backspace();
        spin(10);
        NSView* root = ui.w.contentView;
        [root layoutSubtreeIfNeeded];
        writePNG(renderLive(root, NSMakeRect(0, 0, 916, NSHeight(wpe_test_buttons(ui.c)[1].superview.frame)), 2),
                 [out stringByAppendingPathComponent:[NSString stringWithFormat:@"buttons-pending-%@.png", look]]);
    }
    // The Edit Value sheet, both pages.
    for (NSString* look in @[ @"light", @"dark" ]) {
        UI ui({tf({{"ARTIST", {"The Example Ensemble"}}}), tf({{"ARTIST", {"The Example Ensemble", "Guest"}}})});
        ui.w.appearance = [NSAppearance appearanceNamed:[look isEqualToString:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        ui.click(ui.row("ARTIST"), 0, 2);
        Sheet sh(ui);
        if (!sh.open()) continue;
        sh.w.appearance = ui.w.appearance;
        spin(10);
        snapshot(sh.w, @[ wpe_test_sheet_tab_control(sh.s), sh.table ],
                 [out stringByAppendingPathComponent:[NSString stringWithFormat:@"editvalue-pertrack-%@.png", look]]);
        wpe_test_sheet_select_page(sh.s, 0);
        spin(5);
        snapshot(sh.w, @[ wpe_test_sheet_tab_control(sh.s), wpe_test_sheet_common_editor(sh.s).enclosingScrollView ],
                 [out stringByAppendingPathComponent:[NSString stringWithFormat:@"editvalue-common-%@.png", look]]);
        sh.esc();
    }
    for (NSString* look in @[ @"light", @"dark" ]) {
        UI ui({tf({{"TITLE", {"x"}}})});
        stageTitle(ui, @"new");
        commandW(ui);
        NSAlert* a = wpe_test_close_prompt(ui.c);
        if (!a) continue;
        NSAppearance* appearance = [NSAppearance appearanceNamed:[look isEqualToString:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        a.window.appearance = appearance;
        [a layout];
        NSView* content = a.window.contentView;
        // The alert's background is a visual-effect layer that a view capture leaves out: the capture goes
        // over the window colour, as the alert shows it.
        NSBitmapImageRep* drawn = renderLive(content, content.bounds, 2);
        NSBitmapImageRep* canvas = [drawn copy];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:canvas];
        [appearance performAsCurrentDrawingAppearance:^{
            [NSColor.windowBackgroundColor setFill];
            NSRectFill(NSMakeRect(0, 0, canvas.size.width, canvas.size.height));
        }];
        [drawn drawInRect:NSMakeRect(0, 0, canvas.size.width, canvas.size.height)
                 fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver
                 fraction:1
           respectFlipped:YES
                    hints:nil];
        [NSGraphicsContext restoreGraphicsState];
        writePNG(canvas, [out stringByAppendingPathComponent:[NSString stringWithFormat:@"close-prompt-%@.png", look]]);
        wpe_test_answer_close_prompt(ui.c, kKeepEditing);
    }
}

int main() {
    @autoreleasepool {
        CFDictionaryRef session = CGSessionCopyCurrentDictionary();
        if (!session) {
            std::printf("skipped: no window server session\n");
            return 0;
        }
        CFRelease(session);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if (const char* probe = std::getenv("WPE_QUIT_PROBE")) return runQuitProbe(probe);
        const int rc = wpetest::run_all();
        spin();
        return rc;
    }
}
