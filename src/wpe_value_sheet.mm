#import "wpe_value_sheet.h"

#import "wpe_chrome.h"
#import "wpe_views.h"

#include "wpe_window.h"

#include <algorithm>
#include <cmath>
#include <utility>

using namespace wpe::ui;

namespace {

NSString* SheetStr(const std::string& s) {
    NSString* r = [NSString stringWithUTF8String:s.c_str()];
    return r ?: @"";
}

std::string SheetUtf8(NSString* s) {
    const char* p = s.UTF8String;
    return p ? std::string(p) : std::string();
}

// The host's column identifiers and titles (FB2KPropertiesEditMulti.nib), and its hint.
NSString* const kItemColumn = @"item";
NSString* const kValueColumn = @"value";
NSString* const kRowView = @"row";
NSString* const kMultiValueHint = @"Delimit multiple values with ;";

constexpr NSInteger kItemCol = 0;
constexpr NSInteger kValueCol = 1;

// The host's pages, in its order. The sheet opens on Per-track.
enum : NSInteger { kPageCommon = 0, kPagePerTrack, kPageCount };

constexpr unsigned short kKeyReturn = 36;
constexpr unsigned short kKeyTab = 48;
constexpr unsigned short kKeyEnter = 76;
constexpr unsigned short kKeyBackspace = 51;
constexpr unsigned short kKeyForwardDelete = 117;
constexpr unsigned short kKeyEscape = 53;

constexpr CGFloat kHeadingHeight = 30;
constexpr CGFloat kItemColumnFraction = 0.36;

NSEventModifierFlags SheetMods(NSEvent* e) {
    return e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption |
                              NSEventModifierFlagControl);
}

}

// The bar's multi-value hint. When the sheet is too narrow for all of it, it is shortened in the middle (so
// the ";" it is about stays visible) and the full text becomes its tooltip.
@interface WPESheetHintLabel : NSTextField
@end

@implementation WPESheetHintLabel
- (void)updateTruncationToolTip {
    const NSEdgeInsets in = self.alignmentRectInsets;
    const CGFloat room = NSWidth(self.frame) - in.left - in.right;
    const BOOL truncated = !self.hidden && room + 0.01 < self.intrinsicContentSize.width;
    self.toolTip = truncated ? self.stringValue : nil;
}
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self updateTruncationToolTip];
}
- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [self updateTruncationToolTip];
}
@end

@interface WPEEditValueSheet () <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate,
                                 NSTextViewDelegate, WPEPageTableOwner, WPEWindowOwner>
@end

@implementation WPEEditValueSheet {
    wpe::PerTrackEdit _edit;
    std::function<void(bool)> _done;
    NSString* _title;
    NSArray<NSString*>* _names;
    NSArray<NSString*>* _tips;
    NSWindow* _parent;
    BOOL _finished;
    NSFont* _font;

    NSTextField* _heading;
    NSSegmentedControl* _tabs;
    NSInteger _page;
    NSScrollView* _listScroll;
    WPEPageTableView* _list;
    NSScrollView* _commonScroll;
    NSTextView* _common;
    NSTextField* _hint;
    NSButton* _ok;
    NSButton* _cancel;

    // The open Value editor: a cell's text field, or a text view over the cell for multi-line values.
    NSTextField* _editField;
    NSScrollView* _mlScroll;
    NSTextView* _mlText;
    NSInteger _editRow;
    NSString* _editInitial;
    NSInteger _pendingRow;  // the next row to edit (Return/Tab), opened on the next run loop pass
    NSMutableArray<NSTextField*>* _fieldsToReset;
    NSMutableArray<NSView*>* _viewsToRemove;
    NSMutableIndexSet* _refreshRows;
    BOOL _flushScheduled;
}

#pragma mark Lifetime

- (instancetype)initWithEdit:(wpe::PerTrackEdit)edit
                       title:(NSString*)title
                       names:(NSArray<NSString*>*)names
                    toolTips:(NSArray<NSString*>*)toolTips
                        size:(NSSize)size
                        done:(std::function<void(bool)>)done {
    WPEWindow* win = [[WPEWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                    backing:NSBackingStoreBuffered
                                                      defer:YES];
    self = [super initWithWindow:win];
    if (!self) return nil;
    _edit = std::move(edit);
    _done = std::move(done);
    _title = [title copy] ?: @"";
    _names = [names copy] ?: @[];
    _tips = [toolTips copy] ?: @[];
    _page = -1;
    _editRow = -1;
    _pendingRow = -1;
    _fieldsToReset = [NSMutableArray array];
    _viewsToRemove = [NSMutableArray array];
    _refreshRows = [NSMutableIndexSet indexSet];
    _font = WPEListFont();

    win.owner = self;
    win.delegate = self;
    win.title = _title;
    win.releasedWhenClosed = NO;
    win.restorable = NO;
    win.tabbingMode = NSWindowTabbingModeDisallowed;
    win.contentMinSize = NSMakeSize(360, 240);
    win.backgroundColor = WPEColors.dialog;
    [self buildContent];
    [self selectPage:kPagePerTrack];
    return self;
}

- (const wpe::PerTrackEdit&)edit {
    return _edit;
}

- (void)beginForWindow:(NSWindow*)parent {
    if (_finished) return;
    _parent = parent;
    [self.window.contentView layoutSubtreeIfNeeded];
    if (parent) [parent beginSheet:self.window completionHandler:nil];
    [self.window makeFirstResponder:_page == kPageCommon ? (NSResponder*)_common : (NSResponder*)_list];
}

- (void)finish:(BOOL)ok {
    if (_finished) return;
    _pendingRow = -1;
    if (ok) {
        if (_page == kPagePerTrack) [self endEdit:YES focus:YES];
        else _edit.setCommon(SheetUtf8(_common.string));  // the host's fixTrackVals
    } else {
        [self endEdit:NO focus:YES];
    }
    _finished = YES;
    [self flushUI];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _list.owner = nil;
    _list.dataSource = nil;
    _list.delegate = nil;
    _common.delegate = nil;
    _tabs.target = nil;
    WPEWindow* win = (WPEWindow*)self.window;
    win.owner = nil;
    win.delegate = nil;
    NSWindow* parent = _parent;
    _parent = nil;
    if (parent && win.sheetParent == parent) [parent endSheet:win returnCode:ok ? NSModalResponseOK : NSModalResponseCancel];
    [win orderOut:nil];
    auto done = std::move(_done);
    _done = nullptr;
    if (done) done(ok);
}

- (void)okPressed:(id)sender {
    (void)sender;
    [self finish:YES];
}

- (void)cancelPressed:(id)sender {
    (void)sender;
    [self finish:NO];
}

- (void)windowDidResize:(NSNotification*)note {
    (void)note;
    if (_mlText) [self endEdit:YES focus:YES];
}

#pragma mark Building

- (void)buildContent {
    NSView* content = self.window.contentView;
    const CGFloat width = NSWidth(content.bounds);

    // A sheet has no title bar, so the title ("Edit Value : Artist Name") heads the sheet, centred like
    // the field name at the top of the host's sheet.
    _heading = [NSTextField labelWithString:_title];
    _heading.translatesAutoresizingMaskIntoConstraints = NO;
    _heading.font = [NSFont systemFontOfSize:kListFontSize weight:NSFontWeightSemibold];
    _heading.textColor = NSColor.labelColor;
    _heading.alignment = NSTextAlignmentCenter;
    _heading.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_heading setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];

    // The host's two pages, as a native segmented control under the heading, leading-aligned as in the
    // Properties window (in line with the Per-track list's Item header).
    _tabs = WPEPageControl(@[ @"Common value", @"Per-track" ], self, @selector(tabPicked:));

    [self buildList:width];
    [self buildCommon:width];
    NSView* pages = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 200)];
    pages.translatesAutoresizingMaskIntoConstraints = NO;
    // Per-track's list fills the page, edge to edge like the window's lists; Common value is a text area
    // inset from the page's edges, so its frame and focus ring sit on the window's background.
    for (NSView* page in @[ _commonScroll, _listScroll ]) {
        const CGFloat m = page == _commonScroll ? kTextAreaMargin : 0;
        page.hidden = YES;
        [pages addSubview:page];
        [NSLayoutConstraint activateConstraints:@[
            [page.topAnchor constraintEqualToAnchor:pages.topAnchor constant:m],
            [pages.bottomAnchor constraintEqualToAnchor:page.bottomAnchor constant:m],
            [page.leadingAnchor constraintEqualToAnchor:pages.leadingAnchor constant:m],
            [pages.trailingAnchor constraintEqualToAnchor:page.trailingAnchor constant:m],
        ]];
    }

    // The bar: the multi-value hint at the leading edge, Cancel and OK (the default button, rightmost)
    // at the trailing edge, as in the Properties window.
    WPEBarView* bar = [[WPEBarView alloc] initWithFrame:NSMakeRect(0, 0, width, 44)];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.wpeTopLine = YES;
    _hint = [WPESheetHintLabel labelWithString:kMultiValueHint];
    _hint.translatesAutoresizingMaskIntoConstraints = NO;
    _hint.font = WPEStatusFont();
    _hint.textColor = NSColor.secondaryLabelColor;
    _hint.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _hint.cell.truncatesLastVisibleLine = YES;
    _hint.hidden = !_edit.multiValue();
    [_hint setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    _cancel = WPEPushButton(@"Cancel", self, @selector(cancelPressed:));
    _cancel.toolTip = @"Discard the changes made here (Esc)";
    _ok = WPEPushButton(@"OK", self, @selector(okPressed:));
    _ok.toolTip = @"Use these values (⌘↩); they are written with OK or Apply in the Properties window";
    for (NSView* v in @[ _hint, _cancel, _ok ]) [bar addSubview:v];

    // The heading and the page control sit on a grey band, as the window's page control does.
    WPEBarView* band = [[WPEBarView alloc] initWithFrame:NSMakeRect(0, 0, width, kHeadingHeight + 30)];
    band.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView* v in @[ _heading, _tabs ]) [band addSubview:v];
    for (NSView* v in @[ band, pages, bar ]) [content addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [band.topAnchor constraintEqualToAnchor:content.topAnchor],
        [band.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [band.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [band.bottomAnchor constraintEqualToAnchor:pages.topAnchor],

        [_heading.centerYAnchor constraintEqualToAnchor:content.topAnchor constant:kHeadingHeight / 2],
        [_heading.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor constant:kBarMargin],
        [_heading.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-kBarMargin],
        [_heading.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],

        [_tabs.topAnchor constraintEqualToAnchor:content.topAnchor constant:kHeadingHeight],
        [_tabs.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:kPageControlInset],
        [_tabs.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-kPageControlInset],

        [pages.topAnchor constraintEqualToAnchor:_tabs.bottomAnchor constant:kPageBandInset],
        [pages.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [pages.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [pages.bottomAnchor constraintEqualToAnchor:bar.topAnchor],

        [bar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [_ok.topAnchor constraintEqualToAnchor:bar.topAnchor constant:kBarInset],
        [bar.bottomAnchor constraintEqualToAnchor:_ok.bottomAnchor constant:kBarInset],

        [_ok.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-kBarMargin],
        [_cancel.trailingAnchor constraintEqualToAnchor:_ok.leadingAnchor constant:-kBarSpacing],
        [_cancel.widthAnchor constraintEqualToAnchor:_ok.widthAnchor],
        [_cancel.centerYAnchor constraintEqualToAnchor:_ok.centerYAnchor],

        [_hint.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:kBarMargin],
        [_hint.firstBaselineAnchor constraintEqualToAnchor:_ok.firstBaselineAnchor],
        // The label's frame reaches past its text (its alignment rect) by a few points; the whole frame
        // keeps out of the gap before Cancel, so at the sheet's narrowest the text is shortened instead.
        [_hint.trailingAnchor constraintLessThanOrEqualToAnchor:_cancel.leadingAnchor
                                                       constant:-(kBarSpacing + _hint.alignmentRectInsets.right)],
    ]];
    // OK is the default button (accent-filled); its key is Command-Return, because Return belongs to the
    // list and its editors (it moves to the next track).
    WPEMakeDefaultButton(_ok);
}

// Item | Value, in the Properties window's list look.
- (void)buildList:(CGFloat)width {
    _list = [[WPEPageTableView alloc] initWithFrame:NSMakeRect(0, 0, width, 200)];
    _list.owner = self;
    const CGFloat itemWidth = std::round(width * kItemColumnFraction);
    NSTableColumn* item = [[NSTableColumn alloc] initWithIdentifier:kItemColumn];
    item.title = @"Item";
    item.width = itemWidth;
    item.minWidth = 60;
    item.resizingMask = NSTableColumnUserResizingMask;
    NSTableColumn* value = [[NSTableColumn alloc] initWithIdentifier:kValueColumn];
    value.title = @"Value";
    value.width = width - itemWidth;
    value.minWidth = 80;
    value.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [_list addTableColumn:item];
    [_list addTableColumn:value];
    _list.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _list.allowsMultipleSelection = YES;
    _list.headerView = [[WPEHeaderView alloc] initWithFrame:NSMakeRect(0, 0, width, kHeaderHeight)];
    _list.cornerView = [[WPEHeaderCorner alloc] initWithFrame:NSMakeRect(0, 0, 16, kHeaderHeight)];
    _list.backgroundColor = WPEColors.list;
    _list.usesAlternatingRowBackgroundColors = NO;
    _list.gridStyleMask = NSTableViewGridNone;
    _list.intercellSpacing = NSMakeSize(0, 0);
    _list.rowSizeStyle = NSTableViewRowSizeStyleCustom;
    _list.rowHeight = kRowHeight;
    _list.style = NSTableViewStylePlain;
    _list.focusRingType = NSFocusRingTypeNone;
    _list.allowsColumnReordering = NO;
    _list.allowsColumnSelection = NO;
    _list.allowsTypeSelect = NO;
    _list.allowsEmptySelection = YES;
    _list.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    _list.dataSource = self;
    _list.delegate = self;

    _listScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, width, 200)];
    _listScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _listScroll.documentView = _list;
    _listScroll.hasVerticalScroller = YES;
    _listScroll.hasHorizontalScroller = NO;
    _listScroll.autohidesScrollers = YES;
    _listScroll.borderType = NSNoBorder;
    _listScroll.drawsBackground = YES;
    _listScroll.backgroundColor = WPEColors.list;
    _listScroll.contentView.postsBoundsChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(listScrolled:)
                                                 name:NSViewBoundsDidChangeNotification
                                               object:_listScroll.contentView];
}

- (void)disableSubstitutions:(NSTextView*)tv {
    if (![tv isKindOfClass:[NSTextView class]]) return;
    tv.automaticQuoteSubstitutionEnabled = NO;
    tv.automaticDashSubstitutionEnabled = NO;
    tv.automaticTextReplacementEnabled = NO;
    tv.automaticSpellingCorrectionEnabled = NO;
    tv.continuousSpellCheckingEnabled = NO;
    tv.automaticDataDetectionEnabled = NO;
    tv.automaticLinkDetectionEnabled = NO;
}

// The host's Common value page: one text for every track (a text view, so it can hold line breaks), in a
// text area with a hairline frame and the focus ring, its text kTextAreaTextInset from the frame.
- (void)buildCommon:(CGFloat)width {
    WPEEditorScrollView* sv =
        WPEMakeTextEditor(NSMakeRect(0, 0, width, 200), _font, NSMakeSize(kTextAreaTextInset, kTextAreaTextInset), self);
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    _commonScroll = sv;
    _common = sv.documentView;
}

#pragma mark Pages

// As in the window: a page picked from the keyboard on the control itself keeps the focus there.
- (void)tabPicked:(id)sender {
    const BOOL keepFocus = sender == _tabs && self.window.firstResponder == _tabs;
    [self selectPage:_tabs.selectedSegment focusPage:!keepFocus];
}

- (void)selectPage:(NSInteger)page {
    [self selectPage:page focusPage:YES];
}

// Leaving Per-track commits its edit; leaving Common value gives every track that text unless it still
// reads "< different values >" (the host's fixTrackVals). Common value shows the shared text, or that
// marker when the tracks differ (fixCommonVal).
- (void)selectPage:(NSInteger)page focusPage:(BOOL)focusPage {
    if (_finished || page < 0 || page >= kPageCount) {
        _tabs.selectedSegment = _page;
        return;
    }
    if (page == _page) return;
    if (_page == kPagePerTrack) {
        _pendingRow = -1;
        [self endEdit:YES focus:YES];
    } else if (_page == kPageCommon) {
        _edit.setCommon(SheetUtf8(_common.string));
    }
    _page = page;
    _tabs.selectedSegment = page;
    _listScroll.hidden = page != kPagePerTrack;
    _commonScroll.hidden = page != kPageCommon;
    if (page == kPageCommon) {
        _common.string = SheetStr(_edit.commonText());
        [_common.undoManager removeAllActions];
        if (focusPage) [self.window makeFirstResponder:_common];
        [_common selectAll:nil];
    } else {
        [_list reloadData];
        [self refreshRowDecorations];
        if (focusPage) [self.window makeFirstResponder:_list];
    }
}

// Control-Tab / Control-Shift-Tab and Command-1 / Command-2 switch pages, as in the window.
- (BOOL)wpeWindowShortcut:(NSEvent*)event {
    if (_finished || event.type != NSEventTypeKeyDown) return NO;
    const NSEventModifierFlags mods = SheetMods(event);
    if (event.keyCode == kKeyTab && (mods & NSEventModifierFlagControl) &&
        !(mods & (NSEventModifierFlagCommand | NSEventModifierFlagOption))) {
        [self selectPage:(_page + 1) % kPageCount];
        return YES;
    }
    NSString* key = event.charactersIgnoringModifiers;
    if (mods == NSEventModifierFlagCommand && key.length == 1) {
        const unichar c = [key characterAtIndex:0];
        if (c >= '1' && c < '1' + kPageCount) {
            [self selectPage:c - '1'];
            return YES;
        }
    }
    return NO;
}

// Escape or Command-period: an open edit is cancelled first, then the sheet.
- (void)wpeCancel {
    if ([self editing]) {
        [self endEdit:NO focus:YES];
        return;
    }
    [self finish:NO];
}

#pragma mark List data

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    return tableView == _list ? (NSInteger)_edit.size() : 0;
}

- (NSTableCellView*)makeCell:(NSString*)identifier {
    return WPEMakeListCell(identifier, _font, self, nil);
}

- (NSString*)nameOfTrack:(NSInteger)row {
    NSString* name = row >= 0 && (NSUInteger)row < _names.count ? _names[(NSUInteger)row] : nil;
    return name.length ? name : [NSString stringWithFormat:@"Track %ld", (long)row + 1];
}

- (void)configureCell:(NSTableCellView*)cell column:(NSInteger)col row:(NSInteger)row {
    NSTextField* tf = cell.textField;
    if (!tf || tf == _editField || row < 0 || (size_t)row >= _edit.size()) return;
    if (col == kItemCol) {
        WPESetListText(tf, [self nameOfTrack:row], NSColor.labelColor);
        NSString* tip = (NSUInteger)row < _tips.count ? _tips[(NSUInteger)row] : nil;
        tf.toolTip = tip.length ? tip : nil;
    } else {
        WPESetListText(tf, SheetStr(wpe::single_line(_edit.text((size_t)row))), NSColor.labelColor);
        tf.toolTip = nil;
    }
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    if (tableView != _list || !column) return nil;
    const BOOL item = [column.identifier isEqualToString:kItemColumn];
    NSTableCellView* cell = [tableView makeViewWithIdentifier:column.identifier owner:self];
    if (!cell) cell = [self makeCell:column.identifier];
    [self configureCell:cell column:item ? kItemCol : kValueCol row:row];
    return cell;
}

- (NSTableRowView*)tableView:(NSTableView*)tableView rowViewForRow:(NSInteger)row {
    (void)row;
    WPERowView* v = [tableView makeViewWithIdentifier:kRowView owner:self];
    if (!v) {
        v = [[WPERowView alloc] initWithFrame:NSZeroRect];
        v.identifier = kRowView;
    }
    return v;
}

// Every other row shaded, and the faint Item | Value line, as in the window's lists.
- (void)decorateRowView:(NSTableRowView*)rowView row:(NSInteger)row {
    if (![rowView isKindOfClass:[WPERowView class]]) return;
    WPERowView* v = (WPERowView*)rowView;
    v.wpeBand = NO;
    v.wpeShaded = (row % 2) == 1;
    v.wpeColumnLineX = NSMaxX([_list rectOfColumn:kItemCol]);
}

- (void)tableView:(NSTableView*)tableView didAddRowView:(NSTableRowView*)rowView forRow:(NSInteger)row {
    (void)tableView;
    [self decorateRowView:rowView row:row];
}

- (void)refreshRowDecorations {
    [_list enumerateAvailableRowViewsUsingBlock:^(NSTableRowView* rowView, NSInteger row) {
        [self decorateRowView:rowView row:row];
    }];
}

- (void)tableViewColumnDidResize:(NSNotification*)note {
    (void)note;
    if (_mlText) [self endEdit:YES focus:YES];
    [self refreshRowDecorations];
}

- (void)listScrolled:(NSNotification*)note {
    (void)note;
    if (_mlText) {
        [self endEdit:YES focus:YES];
        return;
    }
    if (_editField && _editRow >= 0) {
        const NSRange visible = [_list rowsInRect:_list.visibleRect];
        if (!NSLocationInRange((NSUInteger)_editRow, visible)) [self endEdit:YES focus:YES];
    }
}

- (void)refreshRow:(NSInteger)row {
    if (row < 0 || row >= _list.numberOfRows) return;
    for (NSInteger col = 0; col < 2; ++col) {
        NSTableCellView* cell = [_list viewAtColumn:col row:row makeIfNecessary:NO];
        if (cell) [self configureCell:cell column:col row:row];
    }
}

- (void)scheduleFlush {
    if (_flushScheduled) return;
    _flushScheduled = YES;
    __weak WPEEditValueSheet* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf flushUI];
    });
}

// Applies cell changes that must not happen inside field-editor callbacks.
- (void)flushUI {
    _flushScheduled = NO;
    for (NSTextField* tf in _fieldsToReset) [self resetEditorField:tf];
    [_fieldsToReset removeAllObjects];
    for (NSView* v in _viewsToRemove) [v removeFromSuperview];
    [_viewsToRemove removeAllObjects];
    NSIndexSet* rows = [_refreshRows copy];
    [_refreshRows removeAllIndexes];
    for (NSUInteger i = rows.firstIndex; i != NSNotFound; i = [rows indexGreaterThanIndex:i]) [self refreshRow:(NSInteger)i];
}

#pragma mark Editing (as on the window's Metadata list)

- (BOOL)editing {
    return _editField != nil || _mlText != nil;
}

- (void)resetEditorField:(NSTextField*)tf {
    if (tf == _editField) return;
    WPEEndInlineEdit(tf);
}

- (NSInteger)focusRow {
    NSInteger row = _list.selectedRow;
    if (row < 0 && _edit.size() > 0) row = 0;
    return row;
}

// Opens the Value editor of a track with its text selected. A non-nil key event is then replayed into
// it, so typing on the list replaces the value (dead keys and input methods included).
- (void)beginEditRow:(NSInteger)row key:(NSEvent*)key {
    _pendingRow = -1;
    if (_finished || _page != kPagePerTrack) return;
    if ([self editing]) [self endEdit:YES focus:YES];
    [self flushUI];
    if (row < 0 || (size_t)row >= _edit.size()) return;
    [_list selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [_list scrollRowToVisible:row];
    NSString* text = SheetStr(_edit.text((size_t)row));
    if (_edit.multiline((size_t)row)) {
        [self beginMultilineRow:row text:text initial:text];
    } else {
        NSTableCellView* cell = [_list viewAtColumn:kValueCol row:row makeIfNecessary:YES];
        NSTextField* tf = cell.textField;
        if (!tf) return;
        _editField = tf;
        _editRow = row;
        _editInitial = [text copy];
        tf.stringValue = text;
        WPEBeginInlineEdit(tf);  // fills the cell, the text where the label's was, the focus ring inside
        if (![self.window makeFirstResponder:tf]) {
            _editField = nil;
            _editRow = -1;
            _editInitial = nil;
            [self resetEditorField:tf];
            [self configureCell:cell column:kValueCol row:row];
            return;
        }
        NSTextView* fe = (NSTextView*)tf.currentEditor;
        [self disableSubstitutions:fe];
        [fe selectAll:nil];
    }
    if (key) {
        NSResponder* fr = self.window.firstResponder;
        if (fr && fr != _list) [fr keyDown:key];
    }
}

// Over the Value cell, from the row's top down, inside the visible list.
- (NSRect)multilineFrameForRow:(NSInteger)row {
    NSView* content = self.window.contentView;
    const NSRect cell = [_list convertRect:[_list frameOfCellAtColumn:kValueCol row:row] toView:content];
    const NSRect visible = [_listScroll.contentView convertRect:_listScroll.contentView.bounds toView:content];
    const CGFloat height = std::max<CGFloat>(_list.rowHeight * 6, 96);
    NSRect f = NSMakeRect(NSMinX(cell), NSMaxY(cell) - height, NSWidth(cell), height);
    if (content.isFlipped) f.origin.y = NSMinY(cell);
    if (NSMaxY(f) > NSMaxY(visible)) f.origin.y = NSMaxY(visible) - height;
    if (NSMinY(f) < NSMinY(visible)) f.origin.y = NSMinY(visible);
    if (NSHeight(f) > NSHeight(visible)) {
        f.origin.y = NSMinY(visible);
        f.size.height = NSHeight(visible);
    }
    return f;
}

// Multi-line values (COMMENT, LYRICS, values with line breaks) get a text view floating over the cell, as
// in the window: no bezel, a hairline frame, a soft shadow, the focus ring, the first line where the text was.
- (void)beginMultilineRow:(NSInteger)row text:(NSString*)text initial:(NSString*)initial {
    WPEEditorScrollView* sv = WPEMakeTextEditor([self multilineFrameForRow:row], _font,
                                                WPEOverlayTextInset(_font, _list.rowHeight, WPEDeviceScale(_list, NO)), self);
    sv.wpeFloating = YES;
    NSTextView* tv = sv.documentView;
    tv.string = text;
    [self.window.contentView addSubview:sv positioned:NSWindowAbove relativeTo:nil];
    _mlScroll = sv;
    _mlText = tv;
    _editRow = row;
    _editInitial = [initial copy];
    [self.window makeFirstResponder:tv];
    [tv selectAll:nil];
}

// Ends the open edit (committing its text into the sheet's values when asked). Returns its row, or -1.
// focus is NO only when AppKit is already moving focus elsewhere (the editor is resigning).
- (NSInteger)endEdit:(BOOL)commit focus:(BOOL)focus {
    if (![self editing]) return -1;
    const NSInteger row = _editRow;
    NSString* initial = _editInitial ?: @"";
    NSString* text = nil;
    if (_mlText) {
        NSTextView* tv = _mlText;
        NSScrollView* sv = _mlScroll;
        _mlText = nil;
        _mlScroll = nil;
        text = [tv.string copy];
        tv.delegate = nil;
        if (focus && self.window.firstResponder == tv) [self.window makeFirstResponder:_list];
        [_viewsToRemove addObject:sv];
    } else {
        NSTextField* tf = _editField;
        _editField = nil;
        NSText* fe = tf.currentEditor;
        text = fe ? [fe.string copy] : [tf.stringValue copy];
        if (focus && fe) [self.window makeFirstResponder:_list];
        [_fieldsToReset addObject:tf];
    }
    _editRow = -1;
    _editInitial = nil;
    if (row >= 0 && (size_t)row < _edit.size()) {
        if (commit && ![text isEqualToString:initial]) _edit.setText((size_t)row, SheetUtf8(text));
        [_refreshRows addIndex:(NSUInteger)row];
    }
    if (focus) [self flushUI];
    else [self scheduleFlush];
    return row;
}

- (void)scheduleEditRow:(NSInteger)row {
    _pendingRow = row;
    __weak WPEEditValueSheet* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf runPendingEdit:row];
    });
}

- (void)runPendingEdit:(NSInteger)row {
    if (_pendingRow != row) return;
    [self beginEditRow:row key:nil];
}

// Commits the edit and opens the next (delta > 0) or previous track's value; Return and Tab wrap, the
// arrows stop at the ends.
- (void)advanceBy:(NSInteger)delta wrap:(BOOL)wrap {
    const NSInteger row = _editRow;
    const NSInteger n = (NSInteger)_edit.size();
    if (!wrap && (row + delta < 0 || row + delta >= n)) return;
    if ([self endEdit:YES focus:YES] < 0 || n == 0) return;
    [self scheduleEditRow:((row + delta) % n + n) % n];
}

- (void)switchToMultiline:(NSTextView*)fieldEditor {
    NSString* text = [fieldEditor.string copy];
    const NSRange sel = fieldEditor.selectedRange;
    const NSInteger row = _editRow;
    NSString* initial = [_editInitial copy];
    [self endEdit:NO focus:YES];
    __weak WPEEditValueSheet* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf openMultilineRow:row text:text initial:initial selection:sel];
    });
}

- (void)openMultilineRow:(NSInteger)row text:(NSString*)text initial:(NSString*)initial selection:(NSRange)sel {
    if (_finished || _page != kPagePerTrack || [self editing] || row < 0 || (size_t)row >= _edit.size()) return;
    [self flushUI];
    [self beginMultilineRow:row text:text initial:initial];
    if (!_mlText) return;
    if (NSMaxRange(sel) <= text.length) _mlText.selectedRange = sel;
    [_mlText insertText:@"\n" replacementRange:_mlText.selectedRange];
}

- (BOOL)editCommand:(SEL)sel textView:(NSTextView*)tv multiline:(BOOL)multiline {
    NSEvent* ev = ((WPEWindow*)self.window).currentKeyEvent ?: NSApp.currentEvent;
    const BOOL shift = ev.type == NSEventTypeKeyDown && (ev.modifierFlags & NSEventModifierFlagShift) != 0;
    if (sel == @selector(insertTab:)) {
        [self advanceBy:+1 wrap:YES];
        return YES;
    }
    if (sel == @selector(insertBacktab:)) {
        [self advanceBy:-1 wrap:YES];
        return YES;
    }
    if (sel == @selector(insertNewline:)) {
        [self advanceBy:shift ? -1 : +1 wrap:YES];
        return YES;
    }
    if (sel == @selector(cancelOperation:) || sel == @selector(complete:)) {
        [self endEdit:NO focus:YES];
        return YES;
    }
    if (sel == @selector(insertNewlineIgnoringFieldEditor:) || sel == @selector(insertLineBreak:)) {
        if (multiline) [tv insertText:@"\n" replacementRange:tv.selectedRange];
        else [self switchToMultiline:tv];
        return YES;
    }
    if (!multiline && (sel == @selector(moveUp:) || sel == @selector(moveDown:))) {
        [self advanceBy:sel == @selector(moveUp:) ? -1 : +1 wrap:NO];
        return YES;
    }
    return NO;
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)sel {
    if (!control || control != _editField) return NO;
    return [self editCommand:sel textView:textView multiline:NO];
}

- (void)controlTextDidEndEditing:(NSNotification*)note {
    if (_editField && note.object == _editField) [self endEdit:YES focus:NO];
}

// The multi-line Value editor, and the Common value text: Return there is OK (Option-Return adds a
// line), Escape is Cancel, Tab moves on to the buttons.
- (BOOL)textView:(NSTextView*)textView doCommandBySelector:(SEL)sel {
    if (textView && textView == _mlText) return [self editCommand:sel textView:textView multiline:YES];
    if (!textView || textView != _common) return NO;
    if (sel == @selector(insertNewline:)) {
        [self finish:YES];
        return YES;
    }
    if (sel == @selector(insertNewlineIgnoringFieldEditor:) || sel == @selector(insertLineBreak:)) {
        [textView insertText:@"\n" replacementRange:textView.selectedRange];
        return YES;
    }
    if (sel == @selector(cancelOperation:) || sel == @selector(complete:)) {
        [self finish:NO];
        return YES;
    }
    if (sel == @selector(insertTab:)) {
        [self.window selectNextKeyView:nil];
        return YES;
    }
    if (sel == @selector(insertBacktab:)) {
        [self.window selectPreviousKeyView:nil];
        return YES;
    }
    return NO;
}

- (void)textDidEndEditing:(NSNotification*)note {
    if (_mlText && note.object == _mlText) [self endEdit:YES focus:NO];
}

#pragma mark List events

- (NSView*)wpePageEditingView:(NSTableView*)table {
    (void)table;
    return _mlText ? _mlScroll : _editField;
}

- (BOOL)wpePage:(NSTableView*)table mouseDown:(NSEvent*)event {
    (void)table;
    _pendingRow = -1;
    const NSPoint p = [_list convertPoint:event.locationInWindow fromView:nil];
    // The second click of a double-click goes to the view that took the first one (the list), even when
    // that click opened an editor under the mouse: hand it to the editor so word selection works.
    if (event.clickCount > 1) {
        NSView* editor = _mlText ? _mlScroll : _editField;
        NSResponder* target = _mlText ? (NSResponder*)_mlText : (NSResponder*)_editField.currentEditor;
        if (editor && target && NSPointInRect(p, [editor convertRect:editor.bounds toView:_list])) {
            [target mouseDown:event];
            return YES;
        }
    }
    if ([self editing]) [self endEdit:YES focus:YES];
    [self flushUI];
    if (_finished) return YES;
    const NSInteger row = [_list rowAtPoint:p];
    const NSInteger col = [_list columnAtPoint:p];
    const NSEventModifierFlags mods =
        event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl);
    if (mods || row < 0 || col != kValueCol) return NO;  // a click on a track's name only selects it
    [self beginEditRow:row key:nil];
    return YES;
}

- (BOOL)wpePage:(NSTableView*)table keyDown:(NSEvent*)event {
    (void)table;
    const NSEventModifierFlags mods = SheetMods(event);
    if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) return NO;
    // A key that arrives between committing one value and opening the next goes to the next editor.
    if (_pendingRow >= 0) {
        [self beginEditRow:_pendingRow key:event];
        return YES;
    }
    if (_finished) return NO;
    const unsigned short code = event.keyCode;
    NSString* chars = event.characters;
    const unichar c = chars.length ? [chars characterAtIndex:0] : 0;
    if (code == kKeyReturn || code == kKeyEnter || c == NSF2FunctionKey) {
        [self beginEditRow:[self focusRow] key:nil];
        return YES;
    }
    if (code == kKeyBackspace || code == kKeyForwardDelete || c == NSDeleteFunctionKey) {
        [self clearSelected];
        return YES;
    }
    if (code == kKeyEscape) {
        [self wpeCancel];
        return YES;
    }
    if (c == NSHomeFunctionKey || c == NSEndFunctionKey || c == NSPageUpFunctionKey || c == NSPageDownFunctionKey) {
        const NSInteger n = (NSInteger)_edit.size();
        if (n == 0) return YES;
        const NSInteger cur = std::min([self focusRow], n - 1);
        const NSRange visible = [_list rowsInRect:_list.visibleRect];
        const NSInteger pageRows = std::max<NSInteger>(1, (NSInteger)visible.length - 1);
        NSInteger target = 0;
        if (c == NSEndFunctionKey) target = n - 1;
        else if (c == NSPageUpFunctionKey) target = std::max<NSInteger>(0, cur - pageRows);
        else if (c == NSPageDownFunctionKey) target = std::min<NSInteger>(n - 1, cur + pageRows);
        NSIndexSet* rows = [NSIndexSet indexSetWithIndex:(NSUInteger)target];
        if (mods & NSEventModifierFlagShift) {
            const NSInteger lo = std::min(cur, target), hi = std::max(cur, target);
            rows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange((NSUInteger)lo, (NSUInteger)(hi - lo + 1))];
        }
        [_list selectRowIndexes:rows byExtendingSelection:NO];
        [_list scrollRowToVisible:target];
        return YES;
    }
    if (c == '\t' || c == 0x19) return NO;
    const BOOL printable = chars.length == 0 || (c >= 0x20 && c != 0x7F && !(c >= 0xF700 && c <= 0xF8FF));
    if (printable && [self focusRow] >= 0) {
        [self beginEditRow:[self focusRow] key:event];
        return YES;
    }
    return NO;
}

- (NSMenu*)wpePage:(NSTableView*)table menuForEvent:(NSEvent*)event {
    (void)table;
    (void)event;
    return nil;
}

// Delete / Backspace clears the selected tracks' values (the field is then removed from them).
- (void)clearSelected {
    if (_finished || _page != kPagePerTrack) return;
    NSIndexSet* rows = _list.selectedRowIndexes;
    for (NSUInteger i = rows.firstIndex; i != NSNotFound; i = [rows indexGreaterThanIndex:i])
        if (i < _edit.size() && _edit.setText(i, "")) [_refreshRows addIndex:i];
    [self flushUI];
}

- (void)wpePageCopy:(NSTableView*)table {
    (void)table;
}

- (void)wpePageDelete:(NSTableView*)table {
    (void)table;
    [self clearSelected];
}

- (BOOL)wpePage:(NSTableView*)table validate:(SEL)action {
    (void)table;
    return action == @selector(delete:) && !_finished && _list.selectedRowIndexes.count > 0;
}

#pragma mark Test hooks

- (NSTableView*)wpeTestList {
    return _list;
}
- (NSString*)wpeTestHeading {
    return _heading.stringValue;
}
- (NSInteger)wpeTestEditRow {
    return _editRow;
}
- (NSString*)wpeTestEditorText {
    if (_mlText) return [_mlText.string copy];
    if (_editField) return _editField.currentEditor ? [_editField.currentEditor.string copy] : _editField.stringValue;
    return nil;
}
- (BOOL)wpeTestMultiline {
    return _mlText != nil;
}
- (NSInteger)wpeTestPage {
    return _page;
}
- (void)wpeTestSelectPage:(NSInteger)page {
    [self selectPage:page];
}
- (NSTextView*)wpeTestCommon {
    return _common;
}
- (NSArray<NSButton*>*)wpeTestButtons {
    return @[ _ok, _cancel ];
}
- (NSString*)wpeTestHint {
    return _hint.hidden ? nil : _hint.stringValue;
}
- (NSSegmentedControl*)wpeTestTabControl {
    return _tabs;
}
- (BOOL)wpeTestFinished {
    return _finished;
}

@end

#define WPE_S(s) ((WPEEditValueSheet*)(s))

NSWindow* wpe_test_sheet_window(id s) {
    return [WPE_S(s) window];
}
NSTableView* wpe_test_sheet_table(id s) {
    return [WPE_S(s) wpeTestList];
}
NSString* wpe_test_sheet_heading(id s) {
    return [WPE_S(s) wpeTestHeading];
}
NSInteger wpe_test_sheet_edit_row(id s) {
    return [WPE_S(s) wpeTestEditRow];
}
NSString* wpe_test_sheet_editor_text(id s) {
    return [WPE_S(s) wpeTestEditorText];
}
bool wpe_test_sheet_multiline(id s) {
    return [WPE_S(s) wpeTestMultiline];
}
NSInteger wpe_test_sheet_page(id s) {
    return [WPE_S(s) wpeTestPage];
}
void wpe_test_sheet_select_page(id s, NSInteger page) {
    [WPE_S(s) wpeTestSelectPage:page];
}
NSTextView* wpe_test_sheet_common_editor(id s) {
    return [WPE_S(s) wpeTestCommon];
}
NSArray<NSButton*>* wpe_test_sheet_buttons(id s) {
    return [WPE_S(s) wpeTestButtons];
}
NSString* wpe_test_sheet_hint(id s) {
    return [WPE_S(s) wpeTestHint];
}
NSSegmentedControl* wpe_test_sheet_tab_control(id s) {
    return [WPE_S(s) wpeTestTabControl];
}
const wpe::PerTrackEdit& wpe_test_sheet_model(id s) {
    return [WPE_S(s) edit];
}
