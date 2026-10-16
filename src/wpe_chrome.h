#pragma once
// Pieces of the Properties window: native controls for the page switch and the button bar, laid out
// the Mac way, around the Columns UI-style lists (header, rows, Artwork cells, group bands). Cocoa only
// (no SDK).
//
// The lists keep the Windows dialog's layout, measured from screenshots of the foobar2000 1.6
// Properties dialog on Windows 11 (175% scaling: one Windows pixel at 100% is one macOS point, so a
// screenshot length in px divided by 1.75 is points; the screenshots themselves are not published, the
// measured values below are what the code and tests use): row and header heights, column shares, the
// Artwork rows. Everything else is the Mac's: the system font at standard sizes with no
// tracking, text optically centred (the capitals' box on the row's centre line, as FooquX places
// it), the system's semantic colours (light, dark, Increase Contrast) with the accent-colour selection
// of any Mac list, and inline editors that fill their cell with a focus ring. The chrome around the
// lists is stock AppKit: an NSSegmentedControl for the pages, push buttons in Mac order with a real
// default button, a Tools pull-down, and an inline status line.

#import <Cocoa/Cocoa.h>

#include <foobar2000/helpers-mac/foobar2000-mac-helpers.h>

#define WPEColors FB2K_OBJC_CLASS(WPEColors)
#define WPEHeaderView FB2K_OBJC_CLASS(WPEHeaderView)
#define WPERowView FB2K_OBJC_CLASS(WPERowView)
#define WPEBarView FB2K_OBJC_CLASS(WPEBarView)
#define WPEPullDownButton FB2K_OBJC_CLASS(WPEPullDownButton)
#define WPEGlyphButton FB2K_OBJC_CLASS(WPEGlyphButton)
#define WPEGlyphButtonCell FB2K_OBJC_CLASS(WPEGlyphButtonCell)
#define WPEThumbView FB2K_OBJC_CLASS(WPEThumbView)
#define WPEListTextCell FB2K_OBJC_CLASS(WPEListTextCell)
#define WPEListCellView FB2K_OBJC_CLASS(WPEListCellView)
#define WPEListField FB2K_OBJC_CLASS(WPEListField)
#define WPEEditorScrollView FB2K_OBJC_CLASS(WPEEditorScrollView)
#define WPEEditorTextView FB2K_OBJC_CLASS(WPEEditorTextView)
#define WPEFrameLineView FB2K_OBJC_CLASS(WPEFrameLineView)

namespace wpe::ui {
// Lists (measured from the screenshots).
constexpr CGFloat kHeaderHeight = 18;    // 32 px incl. its bottom line
constexpr CGFloat kRowHeight = 21;       // 37 px row pitch
constexpr CGFloat kArtRowHeight = 106;   // 185 px; the picture cell is square
constexpr CGFloat kArtDetailsLineHeight = 17;  // pitch of the Artwork Details lines (30 px)
constexpr CGFloat kCellInset = 4;          // list cells: their text starts this far in (and ends this far from the edge)
constexpr CGFloat kTextPadding = 2;        // the text system's line fragment padding: glyphs start this far into a text rect
constexpr CGFloat kHeaderInset = 3;        // header titles: their ink starts 4 pt (7 px) into the column
constexpr CGFloat kListFontSize = 12;      // list items
constexpr CGFloat kChromeFontSize = 11;    // list header, hints
constexpr CGFloat kNameColumnFraction = 0.2815;  // Name column: its divider at 537 of 1908 px

// Inline editors. A single-line editor fills its cell (the row's full height, column line to column
// line) with its text exactly where the cell's label has it, and its focus ring inside the cell: the
// ring's mask is the cell inset by this much, about the ring's width, so the ring ends at the cell's edges.
constexpr CGFloat kEditorRingInset = 3;
// The Edit Value sheet's Common value text area: inset from the page's edges (its focus ring fits in the
// margin), and its text inset from the area's edges.
constexpr CGFloat kTextAreaMargin = 6;
constexpr CGFloat kTextAreaTextInset = 6;

// Artwork: the thumbnail is inset in its square cell and rounded, with a hairline edge; the remove
// column is pinned to the trailing edge (Details takes the rest of the width).
constexpr CGFloat kThumbInset = 4;
constexpr CGFloat kThumbRadius = 4;
constexpr CGFloat kArtRemoveWidth = 30;
constexpr CGFloat kArtGlyphSize = 15;        // SF Symbol point size of the Artwork "+" and "×"
constexpr CGFloat kAddGlyphSize = 12;        // the add row's plus.circle.fill
constexpr CGFloat kAddGlyphGap = 4;          // between that glyph and "add new"
constexpr CGFloat kGroupFontSize = 11;       // Details section headers (semibold, secondary label colour)

// Chrome: native controls, positioned by their alignment rects.
constexpr CGFloat kBarMargin = 14;           // bar content to the window's sides
constexpr CGFloat kBarSpacing = 12;          // between push buttons, and around the status line
constexpr CGFloat kBarInset = 12;            // above and below the push buttons
constexpr CGFloat kPageBandInset = 6;        // above and below the page control
// The page control is leading-aligned: its bezel starts where the list below it starts its text (the Name
// header's title and every cell's glyphs, kCellInset in), at any window width.
constexpr CGFloat kPageControlInset = kCellInset;
constexpr CGFloat kButtonMinWidth = 80;      // Apply, Cancel and OK share one width, at least this
constexpr CGFloat kStatusFontSize = 11;      // the status line in the button bar
constexpr CGFloat kStatusSpinnerGap = 6;     // spinner to status text
}

// The window's colours: the system's semantic colours, so light and dark mode, Increase Contrast and the
// accent and highlight colours come from AppKit. The selection is the accent fill of any Mac list (white
// text) while the list has the focus in the key window, and the unemphasized grey otherwise.
@interface WPEColors : NSObject
+ (NSColor*)dialog;             // windowBackgroundColor: the window, the page band and the button bar
+ (NSColor*)list;               // controlBackgroundColor: lists and their header
+ (NSColor*)alternateRow;       // alternatingContentBackgroundColors[1]: every other row
+ (NSColor*)columnLine;         // separatorColor: the faint Name | Value line
+ (NSColor*)headerLine;         // separatorColor: the header's lines, a section band's bottom line
+ (NSColor*)barLine;            // separatorColor: the button bar's top line
+ (NSColor*)selection;          // selectedContentBackgroundColor (emphasized)
+ (NSColor*)selectionInactive;  // unemphasizedSelectedContentBackgroundColor
+ (NSColor*)sectionBand;        // windowBackgroundColor: Details section headers (opaque, also floating)
@end

NSFont* WPEListFont();
NSFont* WPEChromeFont();
NSFont* WPEStatusFont();  // the status line
NSFont* WPEGroupFont();   // Details section headers
// Text attributes for the list header: font (no tracking), colour.
NSDictionary<NSAttributedStringKey, id>* WPEHeaderAttributes(NSColor* color, NSParagraphStyle* para);
// List cell text: `font`, colour, truncated at the tail (no tracking).
NSDictionary<NSAttributedStringKey, id>* WPEListAttributes(NSFont* font, NSColor* color);
// Sets a list cell's text (plain, in the field's own font) and colour. In a selected row AppKit draws it
// in the emphasized style (white on the accent colour) through the cell's background style.
void WPESetListText(NSTextField* field, NSString* text, NSColor* color);
// One device pixel in the current graphics context (0.5 pt on Retina, also when caching at 2x).
CGFloat WPEHairline();
// Device pixels per point: of the current graphics context while `drawing`, else of `view`'s window (or
// the main screen).
CGFloat WPEDeviceScale(NSView* view, BOOL drawing);

// Optical vertical centring (FooquX's rule): the baseline that puts `font`'s cap box on the centre
// line of [top, top + height) in a flipped view, on the nearest device pixel at `scale` (a tie goes down
// the screen; scale 0: not rounded).
CGFloat WPECentredBaseline(NSFont* font, CGFloat top, CGFloat height, CGFloat scale);
// TextKit's default line for `font` (what a text field cell and its field editor lay out): its height,
// and its top for a given baseline.
CGFloat WPELineHeight(NSFont* font);
CGFloat WPELineTop(NSFont* font, CGFloat baseline);
// For lines of a fixed `lineHeight` (a paragraph style's minimum = maximum, its extra leading above the
// glyphs): the baseline offset that puts the cap box of a block of such lines on the block's centre, so a
// label of them centred in its cell is optically centred (rounded to `scale`'s pixels).
CGFloat WPEFixedLineCapLift(NSFont* font, CGFloat lineHeight, CGFloat scale);

// A stock push button (rounded bezel, regular size, system font) for Auto Layout, at least
// kButtonMinWidth wide.
NSButton* WPEPushButton(NSString* title, id target, SEL action);
// A select-one segmented control of `labels` (regular size) for Auto Layout; `action` is sent when the
// user picks a segment, not when selectedSegment is set.
NSSegmentedControl* WPEPageControl(NSArray<NSString*>* labels, id target, SEL action);
// Makes `button` its window's default button (accent-filled while the window is key) whose key is
// Command-Return only: plain Return stays with the lists and their editors (WPEWindow keeps it away from
// the default button too).
void WPEMakeDefaultButton(NSButton* button);
// The status line: 11 pt, secondary label colour, truncated at the tail.
NSTextField* WPEStatusLabel();
// Sets the status text (systemRed for errors); its tool tip is the whole text.
void WPESetStatusText(NSTextField* label, NSString* text, BOOL error);

// A pull-down button (the Tools menu). The first menu item is its title. `prepare` runs before the menu
// opens (by mouse, keyboard or accessibility); returning NO keeps it closed. The menu's key equivalents
// are shown but not performed here: the window decides when they apply.
@interface WPEPullDownButton : NSPopUpButton
+ (instancetype)pullDownWithTitle:(NSString*)title;
@property(nonatomic, copy) BOOL (^prepare)(void);
@end

// List header: the list's background, left-aligned titles optically centred, separator-colour dividers
// after each column that ends before the right edge, and a bottom line.
@interface WPEHeaderView : NSTableHeaderView
@end

// List row: the list background or the alternate row colour (shaded), an optional faint line at
// `columnLineX`, and the Mac selection: the accent fill while emphasized (the list has the focus in the
// key window), when the cells' text turns white (the emphasized background style), and the unemphasized
// grey otherwise; or an opaque section band (Details group rows, also while floating).
@interface WPERowView : NSTableRowView
@property(nonatomic) BOOL wpeShaded;
@property(nonatomic) CGFloat wpeColumnLineX;  // 0: none
@property(nonatomic) BOOL wpeBand;             // section header (Details): window-colour band, bottom line
@end

// Bar in the window's colour (the page band at the top, the button bar at the bottom) with an optional
// top hairline.
@interface WPEBarView : NSView
@property(nonatomic) BOOL wpeTopLine;
@end

// The text cell of every list cell (Metadata, Details, ReplayGain, Artwork names, Edit Value). Its text
// field (WPEListField) fills the list cell; the text rect holds one TextKit line, optically centred
// (WPECentredBaseline), its glyphs kCellInset from the cell's edges. The field editor gets the same rect,
// so starting an edit moves nothing. While it is an editor (`wpeEditing`) it keeps the normal background
// style in a selected row (text colours on the editor's text background) and its focus ring mask is the
// cell inset by kEditorRingInset.
@interface WPEListTextCell : NSTextFieldCell
// From the field's edges to the text rect (the glyphs start kTextPadding further in): kCellInset -
// kTextPadding, or more after a glyph.
@property(nonatomic) CGFloat wpeLeadingInset;
@property(nonatomic) CGFloat wpeTrailingInset;
@property(nonatomic) BOOL wpeEditing;
// The text rect for `bounds` (the field's, flipped) at `scale` device pixels per point.
- (NSRect)wpeTextRectForBounds:(NSRect)bounds scale:(CGFloat)scale;
@end

// A list cell: an optional glyph (the add row's ⊕, tinted secondary, white in an emphasized selection) and
// the text field filling the cell.
@interface WPEListCellView : NSTableCellView
@end

// A list text field: its cell is a WPEListTextCell, its alignment rect is its frame (a plain text field's
// reaches 2 pt outside it), so laid out to fill a cell it is exactly the cell, and its focus ring is the cell's.
@interface WPEListField : NSTextField
@end

// A list text field (WPEListField): not editable until WPEBeginInlineEdit, single line, truncated.
NSTextField* WPEListTextField(NSFont* font, id<NSTextFieldDelegate> delegate);
// A list cell with its text field filling it; a template `glyph` starts kCellInset in (where the other
// rows' text starts) and the text kAddGlyphGap after it.
WPEListCellView* WPEMakeListCell(NSString* identifier, NSFont* font, id<NSTextFieldDelegate> delegate, NSImage* glyph);
// Turns a list cell's text field into its inline editor (text colours, the text background over the whole
// cell, editable, scrolling, the focus ring inside the cell) and back into a label.
void WPEBeginInlineEdit(NSTextField* field);
void WPEEndInlineEdit(NSTextField* field);

// Multi-line editors (a value with line breaks, over its cell; Edit Value's Common value): a borderless
// scroll view (no legacy bezel) framed by a separator-colour hairline (WPEFrameLineView), with the focus
// ring around it while its text view (focus ring type exterior) has the focus in the key window, and, when
// it floats over the list, a soft shadow.
@interface WPEEditorScrollView : NSScrollView
@property(nonatomic) BOOL wpeFloating;
@property(nonatomic, readonly) NSView* wpeFrameLine;
@end
// Its text view: the text container exactly at textContainerInset, also a fractional one (a half point at
// 2x: NSTextView would round it to whole points), so an overlay's first line can sit where a cell's line is.
@interface WPEEditorTextView : NSTextView
@end
// A one-device-pixel separator-colour frame along its bounds; takes no clicks.
@interface WPEFrameLineView : NSView
@end
// An editor scroll view and its text view (the document view: plain text, no substitutions or
// corrections) in `font`; the glyphs start `inset.width` from the frame's leading edge and the first line's
// top is `inset.height` below its top (the text container's line fragment padding is kTextPadding, as a
// field editor's).
WPEEditorScrollView* WPEMakeTextEditor(NSRect frame, NSFont* font, NSSize inset, id<NSTextViewDelegate> delegate);
// The text inset of a multi-line overlay placed over a list cell (its top on the row's top) that puts its first
// line exactly where the cell's single line is drawn.
NSSize WPEOverlayTextInset(NSFont* font, CGFloat rowHeight, CGFloat scale);

// Borderless SF Symbol button (Artwork: "+" in an empty picture cell, "×" to remove a picture), tinted
// tertiaryLabelColor and secondaryLabelColor while pressed; in an emphasized selection (the cell's
// background style) white, a little translucent, and opaque while pressed.
@interface WPEGlyphButtonCell : NSButtonCell
@end
@interface WPEGlyphButton : NSButton
+ (instancetype)symbol:(NSString*)name label:(NSString*)label target:(id)target action:(SEL)action;
@end

// Artwork thumbnail: the image fitted into the cell inset by kThumbInset, its corners rounded by
// kThumbRadius and edged with a separator-colour hairline.
@interface WPEThumbView : NSImageView
- (NSRect)wpeImageRect;  // where the image is drawn (empty without an image)
@end
