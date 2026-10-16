#import "wpe_chrome.h"

#include <algorithm>
#include <cmath>

using namespace wpe::ui;

namespace {

// TextKit's metrics (what text field cells and field editors lay out with); main thread only.
NSLayoutManager* WPEMetrics() {
    static NSLayoutManager* lm = [[NSLayoutManager alloc] init];
    return lm;
}

NSFont* WPEFontOrSystem(NSFont* font) { return font ?: [NSFont systemFontOfSize:0]; }

CGContextRef WPEContext() {
    NSGraphicsContext* g = NSGraphicsContext.currentContext;
    return g ? g.CGContext : nullptr;
}

// A rect snapped to the device pixel grid of the current context (at least one pixel each way).
NSRect WPEAligned(NSRect r) {
    CGContextRef ctx = WPEContext();
    if (!ctx) return r;
    CGRect d = CGContextConvertRectToDeviceSpace(ctx, NSRectToCGRect(r));
    const CGFloat x0 = std::round(CGRectGetMinX(d)), y0 = std::round(CGRectGetMinY(d));
    const CGFloat x1 = std::max(x0 + 1, std::round(CGRectGetMaxX(d))), y1 = std::max(y0 + 1, std::round(CGRectGetMaxY(d)));
    return NSRectFromCGRect(CGContextConvertRectToUserSpace(ctx, CGRectMake(x0, y0, x1 - x0, y1 - y0)));
}

// Fills a rect snapped to device pixels.
void WPEFill(NSRect r) { NSRectFillUsingOperation(WPEAligned(r), NSCompositingOperationSourceOver); }

// One-device-pixel lines: the row of pixels starting at y, the column of pixels starting at x.
void WPEHLine(CGFloat x0, CGFloat x1, CGFloat y) { WPEFill(NSMakeRect(x0, y, x1 - x0, WPEHairline())); }
void WPEVLine(CGFloat x, CGFloat y0, CGFloat y1) { WPEFill(NSMakeRect(x, y0, WPEHairline(), y1 - y0)); }

}

CGFloat WPEHairline() {
    CGContextRef ctx = WPEContext();
    if (!ctx) return 1;
    const CGSize d = CGContextConvertSizeToDeviceSpace(ctx, CGSizeMake(1, 1));
    const CGFloat scale = std::max(std::fabs(d.width), std::fabs(d.height));
    return scale >= 1 ? 1 / std::round(scale) : 1;
}

CGFloat WPEDeviceScale(NSView* view, BOOL drawing) {
    if (drawing && WPEContext()) return 1 / WPEHairline();
    NSWindow* w = view.window;
    const CGFloat scale = w ? w.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
    return scale > 0 ? scale : 1;
}

CGFloat WPECentredBaseline(NSFont* font, CGFloat top, CGFloat height, CGFloat scale) {
    const CGFloat ideal = top + height / 2 + WPEFontOrSystem(font).capHeight / 2;
    if (!(scale > 0)) return ideal;
    return std::floor(ideal * scale + 0.5) / scale;
}

CGFloat WPELineHeight(NSFont* font) { return [WPEMetrics() defaultLineHeightForFont:WPEFontOrSystem(font)]; }

CGFloat WPELineTop(NSFont* font, CGFloat baseline) {
    return baseline - [WPEMetrics() defaultBaselineOffsetForFont:WPEFontOrSystem(font)];
}

// A line of fixed height L gets its extra leading (L minus TextKit's line height) above the glyphs, so its
// baseline is L - (line height - baseline offset) below the line's top. The cap box of n such lines then
// sits L / 2 - descent - cap / 2 below the block's centre, whatever n is.
CGFloat WPEFixedLineCapLift(NSFont* font, CGFloat lineHeight, CGFloat scale) {
    font = WPEFontOrSystem(font);
    const CGFloat descent = WPELineHeight(font) - [WPEMetrics() defaultBaselineOffsetForFont:font];
    const CGFloat lift = lineHeight / 2 - descent - font.capHeight / 2;
    return scale > 0 ? std::round(lift * scale) / scale : lift;
}

NSFont* WPEListFont() { return [NSFont systemFontOfSize:kListFontSize]; }
NSFont* WPEChromeFont() { return [NSFont systemFontOfSize:kChromeFontSize]; }
NSFont* WPEStatusFont() { return [NSFont systemFontOfSize:kStatusFontSize]; }
NSFont* WPEGroupFont() { return [NSFont systemFontOfSize:kGroupFontSize weight:NSFontWeightSemibold]; }

NSDictionary<NSAttributedStringKey, id>* WPEHeaderAttributes(NSColor* color, NSParagraphStyle* para) {
    NSMutableDictionary* a = [@{
        NSFontAttributeName : WPEChromeFont(),
        NSForegroundColorAttributeName : color ?: NSColor.headerTextColor,
    } mutableCopy];
    if (para) a[NSParagraphStyleAttributeName] = para;
    return a;
}

NSDictionary<NSAttributedStringKey, id>* WPEListAttributes(NSFont* font, NSColor* color) {
    NSMutableParagraphStyle* para = [[NSMutableParagraphStyle alloc] init];
    para.lineBreakMode = NSLineBreakByTruncatingTail;
    return @{
        NSFontAttributeName : font ?: WPEListFont(),
        NSForegroundColorAttributeName : color ?: NSColor.labelColor,
        NSParagraphStyleAttributeName : para,
    };
}

void WPESetListText(NSTextField* field, NSString* text, NSColor* color) {
    field.textColor = color ?: NSColor.labelColor;
    field.stringValue = text ?: @"";
}

#pragma mark - Colours

@implementation WPEColors

+ (NSColor*)dialog {
    return NSColor.windowBackgroundColor;
}
+ (NSColor*)list {
    return NSColor.controlBackgroundColor;
}
+ (NSColor*)alternateRow {
    NSArray<NSColor*>* colours = NSColor.alternatingContentBackgroundColors;
    return colours.count > 1 ? colours[1] : NSColor.controlBackgroundColor;
}
+ (NSColor*)columnLine {
    return NSColor.separatorColor;
}
+ (NSColor*)headerLine {
    return NSColor.separatorColor;
}
+ (NSColor*)barLine {
    return NSColor.separatorColor;
}
+ (NSColor*)selection {
    return NSColor.selectedContentBackgroundColor;
}
+ (NSColor*)selectionInactive {
    return NSColor.unemphasizedSelectedContentBackgroundColor;
}
+ (NSColor*)sectionBand {
    return NSColor.windowBackgroundColor;
}

@end

#pragma mark - Native controls

NSButton* WPEPushButton(NSString* title, id target, SEL action) {
    NSButton* b = [NSButton buttonWithTitle:title target:target action:action];
    b.bezelStyle = NSBezelStylePush;  // what "automatic" resolves to in a dialog's bar, but stated
    b.controlSize = NSControlSizeRegular;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    // Layout anchors are alignment rects: the bezel, not the classic design's shadow margins.
    [b.widthAnchor constraintGreaterThanOrEqualToConstant:kButtonMinWidth].active = YES;
    return b;
}

NSSegmentedControl* WPEPageControl(NSArray<NSString*>* labels, id target, SEL action) {
    NSSegmentedControl* c = [NSSegmentedControl segmentedControlWithLabels:labels
                                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                    target:target
                                                                    action:action];
    c.translatesAutoresizingMaskIntoConstraints = NO;
    c.controlSize = NSControlSizeRegular;
    c.segmentStyle = NSSegmentStyleAutomatic;
    c.selectedSegment = -1;
    [c setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return c;
}

void WPEMakeDefaultButton(NSButton* button) {
    NSWindow* w = button.window;
    if (w) w.defaultButtonCell = button.cell;
    // The default button keeps its look (accent-filled while the window is key) but answers
    // Command-Return only: plain Return belongs to the list and its editors.
    button.keyEquivalent = @"\r";
    button.keyEquivalentModifierMask = NSEventModifierFlagCommand;
}

NSTextField* WPEStatusLabel() {
    NSTextField* l = [NSTextField labelWithString:@""];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = WPEStatusFont();
    l.textColor = NSColor.secondaryLabelColor;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    l.maximumNumberOfLines = 1;
    l.cell.usesSingleLineMode = YES;
    [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [l setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return l;
}

void WPESetStatusText(NSTextField* label, NSString* text, BOOL error) {
    label.stringValue = text ?: @"";
    label.textColor = error ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    label.toolTip = text.length ? text : nil;
}

@implementation WPEPullDownButton

+ (instancetype)pullDownWithTitle:(NSString*)title {
    WPEPullDownButton* b = [[self alloc] initWithFrame:NSMakeRect(0, 0, 80, 25) pullsDown:YES];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.controlSize = NSControlSizeRegular;
    b.autoenablesItems = YES;
    NSMenuItem* titleItem = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
    [b.menu addItem:titleItem];
    return b;
}

- (BOOL)wpeReady {
    return !self.prepare || self.prepare();
}

- (void)mouseDown:(NSEvent*)event {
    if ([self wpeReady]) [super mouseDown:event];
}

- (void)performClick:(id)sender {
    if ([self wpeReady]) [super performClick:sender];
}

// Space, Return and the arrows open the menu of a focused pull-down (Full Keyboard Access).
- (void)keyDown:(NSEvent*)event {
    NSString* c = event.charactersIgnoringModifiers;
    const unichar k = c.length ? [c characterAtIndex:0] : 0;
    const BOOL opens = k == ' ' || k == '\r' || k == 3 || k == NSUpArrowFunctionKey || k == NSDownArrowFunctionKey;
    if (opens && ![self wpeReady]) return;
    [super keyDown:event];
}

- (BOOL)accessibilityPerformPress {
    return [self wpeReady] ? [super accessibilityPerformPress] : NO;
}

- (BOOL)accessibilityPerformShowMenu {
    if (![self wpeReady]) return NO;
    return [NSPopUpButton instancesRespondToSelector:@selector(accessibilityPerformShowMenu)] ? [super accessibilityPerformShowMenu]
                                                                                                : [super accessibilityPerformPress];
}

// The items' key equivalents are shown in the menu; whether one applies is up to the window (Paste
// Fields belongs to the Metadata list only), so the button never performs them itself.
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    (void)event;
    return NO;
}

@end

#pragma mark - List header and rows

@implementation WPEHeaderView

- (void)drawRect:(NSRect)dirty {
    [WPEColors.list setFill];
    NSRectFill(NSIntersectionRect(dirty, self.bounds));
    NSTableView* table = self.tableView;
    NSMutableParagraphStyle* para = [[NSMutableParagraphStyle alloc] init];
    para.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary* attrs = WPEHeaderAttributes(NSColor.headerTextColor, para);
    NSFont* font = attrs[NSFontAttributeName];
    const CGFloat right = NSMaxX(self.bounds);
    const CGFloat px = WPEHairline();
    const CGFloat lineY = NSMaxY(self.bounds) - px;  // the bottom line is not part of the titles' box
    const CGFloat scale = WPEDeviceScale(self, YES);
    for (NSInteger i = 0; i < table.numberOfColumns; ++i) {
        const NSRect r = [self headerRectOfColumn:i];
        if (NSWidth(r) <= 0) continue;
        NSString* title = table.tableColumns[(NSUInteger)i].title;
        if (title.length && NSWidth(r) > 2 * kHeaderInset) {
            // Optically centred: the capitals' box on the centre line of the header above its bottom line.
            const CGFloat baseline = WPECentredBaseline(font, NSMinY(r), lineY - NSMinY(r), scale);
            const NSRect tr = NSMakeRect(NSMinX(r) + kHeaderInset, WPELineTop(font, baseline), NSWidth(r) - 2 * kHeaderInset,
                                         WPELineHeight(font));
            [title drawWithRect:tr options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:attrs];
        }
        if (NSMaxX(r) < right - 0.5) {
            [WPEColors.headerLine setFill];
            WPEVLine(NSMaxX(r) - px, NSMinY(r), lineY);
        }
    }
    [WPEColors.headerLine setFill];
    WPEHLine(0, right, lineY);
}

@end

@implementation WPERowView

- (void)setWpeShaded:(BOOL)value {
    if (_wpeShaded == value) return;
    _wpeShaded = value;
    self.needsDisplay = YES;
}

- (void)setWpeColumnLineX:(CGFloat)value {
    if (_wpeColumnLineX == value) return;
    _wpeColumnLineX = value;
    self.needsDisplay = YES;
}

- (void)setWpeBand:(BOOL)value {
    if (_wpeBand == value) return;
    _wpeBand = value;
    [self wpeUpdateBanner];
    self.needsDisplay = YES;
}

// A floating group row gets AppKit's banner (a blur material) behind its cells; the band drawn here is
// opaque instead, so a section header looks the same floating or not and nothing shows through it.
- (void)wpeUpdateBanner {
    for (NSView* v in self.subviews)
        if (![v isKindOfClass:[NSTableCellView class]] && [NSStringFromClass([v class]) hasSuffix:@"BannerView"]) v.hidden = self.wpeBand;
}

- (void)didAddSubview:(NSView*)subview {
    [super didAddSubview:subview];
    [self wpeUpdateBanner];
}

- (void)setFloating:(BOOL)floating {
    [super setFloating:floating];
    [self wpeUpdateBanner];
    self.needsDisplay = YES;
}

- (void)drawBackgroundInRect:(NSRect)dirty {
    const NSRect area = NSIntersectionRect(dirty, self.bounds);
    if (self.wpeBand) {
        [WPEColors.sectionBand setFill];
        NSRectFill(area);
        [WPEColors.headerLine setFill];
        WPEHLine(0, NSWidth(self.bounds), self.flipped ? NSHeight(self.bounds) - WPEHairline() : 0);
        return;
    }
    [WPEColors.list setFill];
    NSRectFill(area);
    if (self.wpeShaded) {  // translucent in dark mode: over the list colour
        [WPEColors.alternateRow setFill];
        NSRectFillUsingOperation(area, NSCompositingOperationSourceOver);
    }
    if (self.wpeColumnLineX > 0) {
        [WPEColors.columnLine setFill];
        WPEVLine(self.wpeColumnLineX - WPEHairline(), 0, NSHeight(self.bounds));
    }
}

- (void)drawSelectionInRect:(NSRect)dirty {
    (void)dirty;
    if (self.selectionHighlightStyle == NSTableViewSelectionHighlightStyleNone) return;
    [(self.isEmphasized ? WPEColors.selection : WPEColors.selectionInactive) setFill];
    NSRectFill(self.bounds);
}

// White text on the accent fill (the cells' labelColor and secondaryLabelColor turn white); dark text on
// the unemphasized grey, as in any Mac list.
- (NSBackgroundStyle)interiorBackgroundStyle {
    const BOOL accent = self.isSelected && self.isEmphasized && !self.wpeBand &&
                        self.selectionHighlightStyle != NSTableViewSelectionHighlightStyleNone;
    return accent ? NSBackgroundStyleEmphasized : NSBackgroundStyleNormal;
}

@end

#pragma mark - Bars

@implementation WPEBarView

- (BOOL)isFlipped {
    return YES;
}

- (void)setWpeTopLine:(BOOL)value {
    _wpeTopLine = value;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirty {
    [WPEColors.dialog setFill];
    NSRectFill(NSIntersectionRect(dirty, self.bounds));
    if (self.wpeTopLine) {
        [WPEColors.barLine setFill];
        WPEHLine(0, NSWidth(self.bounds), 0);
    }
}

@end

#pragma mark - Artwork glyphs and thumbnails

@implementation WPEGlyphButtonCell

// Pressed (while the mouse is down on it): one step stronger. On the accent fill of a selected row: white.
- (void)wpeTint:(NSView*)view pressed:(BOOL)pressed {
    if (![view isKindOfClass:[NSButton class]]) return;
    NSColor* tint = nil;
    if (self.backgroundStyle == NSBackgroundStyleEmphasized)
        tint = pressed ? NSColor.alternateSelectedControlTextColor : [NSColor.alternateSelectedControlTextColor colorWithAlphaComponent:0.75];
    else
        tint = pressed ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor;
    ((NSButton*)view).contentTintColor = tint;
}

- (void)setHighlighted:(BOOL)flag {
    [super setHighlighted:flag];
    [self wpeTint:self.controlView pressed:flag];
}

- (void)highlight:(BOOL)flag withFrame:(NSRect)frame inView:(NSView*)view {
    [self wpeTint:view pressed:flag];
    [super highlight:flag withFrame:frame inView:view];
}

- (void)setBackgroundStyle:(NSBackgroundStyle)style {
    [super setBackgroundStyle:style];
    [self wpeTint:self.controlView pressed:self.isHighlighted];
}

@end

@implementation WPEGlyphButton

+ (Class)cellClass {
    return [WPEGlyphButtonCell class];
}

+ (instancetype)symbol:(NSString*)name label:(NSString*)label target:(id)target action:(SEL)action {
    WPEGlyphButton* b = [[self alloc] initWithFrame:NSMakeRect(0, 0, 24, 24)];
    if (![b.cell isKindOfClass:[WPEGlyphButtonCell class]]) b.cell = [[WPEGlyphButtonCell alloc] initImageCell:nil];
    b.buttonType = NSButtonTypeMomentaryChange;
    b.bordered = NO;
    b.title = @"";
    b.imagePosition = NSImageOnly;
    b.imageScaling = NSImageScaleNone;
    NSImage* image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:label];
    b.image = [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:kArtGlyphSize
                                                                                                  weight:NSFontWeightRegular]];
    b.contentTintColor = NSColor.tertiaryLabelColor;
    b.accessibilityLabel = label;
    b.target = target;
    b.action = action;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.focusRingType = NSFocusRingTypeNone;
    b.refusesFirstResponder = YES;
    return b;
}

@end

@implementation WPEThumbView

// Drawn here (not by the image view's layer), so the rounding and the edge are always there.
- (BOOL)wantsUpdateLayer {
    return NO;
}

- (BOOL)isOpaque {
    return NO;
}

- (NSRect)wpeImageRect {
    NSImage* image = self.image;
    const NSRect box = NSInsetRect(self.bounds, kThumbInset, kThumbInset);
    const NSSize size = image.size;
    if (!image || size.width <= 0 || size.height <= 0 || NSIsEmptyRect(box)) return NSZeroRect;
    const CGFloat k = std::min(NSWidth(box) / size.width, NSHeight(box) / size.height);
    const CGFloat w = std::max<CGFloat>(1, std::round(size.width * k)), h = std::max<CGFloat>(1, std::round(size.height * k));
    return NSMakeRect(std::round(NSMidX(box) - w / 2), std::round(NSMidY(box) - h / 2), w, h);
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    const NSRect r = [self wpeImageRect];
    if (NSIsEmptyRect(r)) return;
    const CGFloat radius = std::min<CGFloat>(kThumbRadius, std::min(NSWidth(r), NSHeight(r)) / 2);
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius] addClip];
    [self.image drawInRect:r
                  fromRect:NSZeroRect
                 operation:NSCompositingOperationSourceOver
                  fraction:1
            respectFlipped:YES
                     hints:@{NSImageHintInterpolation : @(NSImageInterpolationHigh)}];
    [NSGraphicsContext restoreGraphicsState];
    const CGFloat px = WPEHairline();
    NSBezierPath* edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, px / 2, px / 2)
                                                         xRadius:std::max<CGFloat>(0, radius - px / 2)
                                                         yRadius:std::max<CGFloat>(0, radius - px / 2)];
    edge.lineWidth = px;
    [NSColor.separatorColor setStroke];
    [edge stroke];
}

@end

#pragma mark - List text cells and inline editors

@implementation WPEListTextCell {
    NSBackgroundStyle _rowStyle;  // what the row asked for (an editor keeps the normal style)
    CGFloat _drawScale;           // device pixels per point while drawing (0: the window's)
}

- (void)wpeInit {
    _wpeLeadingInset = kCellInset - kTextPadding;
    _wpeTrailingInset = kCellInset - kTextPadding;
    _rowStyle = NSBackgroundStyleNormal;
}

- (instancetype)initTextCell:(NSString*)string {
    self = [super initTextCell:string];
    if (self) [self wpeInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder*)coder {
    self = [super initWithCoder:coder];
    if (self) [self wpeInit];
    return self;
}

- (id)copyWithZone:(NSZone*)zone {
    WPEListTextCell* c = [super copyWithZone:zone];
    c->_wpeLeadingInset = _wpeLeadingInset;
    c->_wpeTrailingInset = _wpeTrailingInset;
    c->_wpeEditing = _wpeEditing;
    c->_rowStyle = _rowStyle;
    c->_drawScale = 0;
    return c;
}

- (CGFloat)wpeScale:(NSView*)view {
    return _drawScale > 0 ? _drawScale : WPEDeviceScale(view ?: self.controlView, NO);
}

- (NSRect)wpeTextRectForBounds:(NSRect)bounds scale:(CGFloat)scale {
    NSFont* font = WPEFontOrSystem(self.font);
    NSRect r;
    r.origin.x = NSMinX(bounds) + _wpeLeadingInset;
    r.size.width = std::max<CGFloat>(0, NSWidth(bounds) - _wpeLeadingInset - _wpeTrailingInset);
    r.origin.y = WPELineTop(font, WPECentredBaseline(font, NSMinY(bounds), NSHeight(bounds), scale));
    r.size.height = WPELineHeight(font);
    return r;
}

- (NSRect)titleRectForBounds:(NSRect)bounds {
    return [self wpeTextRectForBounds:bounds scale:[self wpeScale:nil]];
}

- (NSRect)drawingRectForBounds:(NSRect)bounds {
    return [self wpeTextRectForBounds:bounds scale:[self wpeScale:nil]];
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView*)view {
    // The background (an editor's) covers the whole cell, not only the text rect.
    if (self.drawsBackground && self.backgroundColor) {
        [self.backgroundColor setFill];
        NSRectFillUsingOperation(frame, NSCompositingOperationSourceOver);
    }
    _drawScale = WPEDeviceScale(view, YES);
    [super drawWithFrame:frame inView:view];
    _drawScale = 0;
}

// The field editor gets the label's text rect: editing starts with the text exactly where it was.
- (void)editWithFrame:(NSRect)rect inView:(NSView*)view editor:(NSText*)editor delegate:(id)delegate event:(NSEvent*)event {
    [super editWithFrame:[self wpeTextRectForBounds:rect scale:[self wpeScale:view]] inView:view editor:editor delegate:delegate event:event];
}

- (void)selectWithFrame:(NSRect)rect
                 inView:(NSView*)view
                 editor:(NSText*)editor
               delegate:(id)delegate
                  start:(NSInteger)start
                 length:(NSInteger)length {
    [super selectWithFrame:[self wpeTextRectForBounds:rect scale:[self wpeScale:view]]
                    inView:view
                    editor:editor
                  delegate:delegate
                     start:start
                    length:length];
}

- (void)setBackgroundStyle:(NSBackgroundStyle)style {
    _rowStyle = style;
    [super setBackgroundStyle:_wpeEditing ? NSBackgroundStyleNormal : style];
}

- (void)setWpeEditing:(BOOL)editing {
    _wpeEditing = editing;
    [super setBackgroundStyle:editing ? NSBackgroundStyleNormal : _rowStyle];
}

// An editor's focus ring stays inside its cell (labels have none).
- (NSRect)focusRingMaskBoundsForFrame:(NSRect)frame inView:(NSView*)view {
    (void)view;
    return _wpeEditing ? NSInsetRect(frame, kEditorRingInset, kEditorRingInset) : NSZeroRect;
}

- (void)drawFocusRingMaskWithFrame:(NSRect)frame inView:(NSView*)view {
    (void)view;
    if (_wpeEditing) NSRectFill(NSInsetRect(frame, kEditorRingInset, kEditorRingInset));
}

@end

@implementation WPEListCellView

- (void)setBackgroundStyle:(NSBackgroundStyle)style {
    [super setBackgroundStyle:style];
    if (self.imageView)
        self.imageView.contentTintColor =
            style == NSBackgroundStyleEmphasized ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor;
}

@end

@implementation WPEListField

+ (Class)cellClass {
    return [WPEListTextCell class];
}

- (NSEdgeInsets)alignmentRectInsets {
    return NSEdgeInsetsZero;
}

// The focus ring is the cell's (an editor's: inside the list cell; a label's: none), whatever NSControl
// would decide for an unbezeled field.
- (NSRect)focusRingMaskBounds {
    return [self.cell focusRingMaskBoundsForFrame:self.bounds inView:self];
}

- (void)drawFocusRingMask {
    [self.cell drawFocusRingMaskWithFrame:self.bounds inView:self];
}

@end

NSTextField* WPEListTextField(NSFont* font, id<NSTextFieldDelegate> delegate) {
    NSTextField* tf = [[WPEListField alloc] initWithFrame:NSMakeRect(0, 0, 100, kRowHeight)];
    if (![tf.cell isKindOfClass:[WPEListTextCell class]]) tf.cell = [[WPEListTextCell alloc] initTextCell:@""];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.bordered = NO;
    tf.bezeled = NO;
    tf.drawsBackground = NO;
    tf.editable = NO;
    tf.selectable = NO;
    tf.font = font ?: WPEListFont();
    tf.textColor = NSColor.labelColor;
    tf.usesSingleLineMode = YES;
    tf.cell.scrollable = NO;
    tf.cell.wraps = NO;
    tf.lineBreakMode = NSLineBreakByTruncatingTail;
    tf.allowsEditingTextAttributes = NO;
    tf.focusRingType = NSFocusRingTypeNone;
    tf.delegate = delegate;
    for (NSLayoutConstraintOrientation o : {NSLayoutConstraintOrientationHorizontal, NSLayoutConstraintOrientationVertical}) {
        [tf setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:o];
        [tf setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:o];
    }
    return tf;
}

WPEListCellView* WPEMakeListCell(NSString* identifier, NSFont* font, id<NSTextFieldDelegate> delegate, NSImage* glyph) {
    WPEListCellView* cell = [[WPEListCellView alloc] initWithFrame:NSMakeRect(0, 0, 100, kRowHeight)];
    cell.identifier = identifier;
    NSTextField* tf = WPEListTextField(font, delegate);
    [cell addSubview:tf];
    cell.textField = tf;
    [NSLayoutConstraint activateConstraints:@[
        [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
        [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
        [tf.topAnchor constraintEqualToAnchor:cell.topAnchor],
        [tf.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor],
    ]];
    if (glyph) {
        NSImageView* iv = [NSImageView imageViewWithImage:glyph];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.contentTintColor = NSColor.secondaryLabelColor;
        iv.accessibilityElement = NO;  // the text says what the row does
        [cell addSubview:iv];
        cell.imageView = iv;
        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:kCellInset],
            [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
        // The text starts kAddGlyphGap after the glyph's alignment rect (its intrinsic size).
        ((WPEListTextCell*)tf.cell).wpeLeadingInset = kCellInset + iv.intrinsicContentSize.width + kAddGlyphGap - kTextPadding;
    }
    return cell;
}

void WPEBeginInlineEdit(NSTextField* tf) {
    if ([tf.cell isKindOfClass:[WPEListTextCell class]]) ((WPEListTextCell*)tf.cell).wpeEditing = YES;
    tf.textColor = NSColor.textColor;
    tf.backgroundColor = NSColor.textBackgroundColor;
    tf.drawsBackground = YES;  // over the whole cell: no selection colour around the editor
    tf.editable = YES;
    tf.selectable = YES;
    tf.cell.wraps = NO;
    tf.cell.scrollable = YES;
    tf.focusRingType = NSFocusRingTypeExterior;
    [tf noteFocusRingMaskChanged];
}

void WPEEndInlineEdit(NSTextField* tf) {
    tf.editable = NO;
    tf.selectable = NO;
    tf.drawsBackground = NO;
    tf.cell.scrollable = NO;
    tf.cell.wraps = NO;
    tf.lineBreakMode = NSLineBreakByTruncatingTail;
    tf.focusRingType = NSFocusRingTypeNone;
    if ([tf.cell isKindOfClass:[WPEListTextCell class]]) ((WPEListTextCell*)tf.cell).wpeEditing = NO;
    [tf noteFocusRingMaskChanged];
}

@implementation WPEFrameLineView

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)isOpaque {
    return NO;
}

- (NSView*)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    const CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds), px = WPEHairline();
    [WPEColors.headerLine setFill];
    WPEHLine(0, w, 0);
    WPEHLine(0, w, h - px);
    WPEVLine(0, px, h - px);
    WPEVLine(w - px, px, h - px);
}

@end

@implementation WPEEditorScrollView {
    WPEFrameLineView* _line;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.borderType = NSNoBorder;
    self.hasVerticalScroller = YES;
    self.hasHorizontalScroller = NO;
    self.autohidesScrollers = YES;
    self.drawsBackground = YES;
    self.backgroundColor = NSColor.textBackgroundColor;
    self.focusRingType = NSFocusRingTypeExterior;
    _line = [[WPEFrameLineView alloc] initWithFrame:self.bounds];
    _line.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_line positioned:NSWindowAbove relativeTo:nil];
    return self;
}

- (NSView*)wpeFrameLine {
    return _line;
}

// The frame line stays above the clip view and the scrollers.
- (void)tile {
    [super tile];
    if (_line && self.subviews.lastObject != _line) [self addSubview:_line positioned:NSWindowAbove relativeTo:nil];
    _line.frame = self.bounds;
}

- (void)setWpeFloating:(BOOL)floating {
    _wpeFloating = floating;
    if (floating) {
        self.wantsLayer = YES;
        NSShadow* s = [[NSShadow alloc] init];
        s.shadowBlurRadius = 6;
        s.shadowOffset = NSMakeSize(0, -2);
        s.shadowColor = [NSColor colorWithWhite:0 alpha:0.28];
        self.shadow = s;
    } else {
        self.shadow = nil;
    }
}

@end

@implementation WPEEditorTextView

- (NSPoint)textContainerOrigin {
    const NSSize inset = self.textContainerInset;
    return NSMakePoint(inset.width, inset.height);
}

@end

WPEEditorScrollView* WPEMakeTextEditor(NSRect frame, NSFont* font, NSSize inset, id<NSTextViewDelegate> delegate) {
    WPEEditorScrollView* sv = [[WPEEditorScrollView alloc] initWithFrame:frame];
    const NSSize size = sv.contentSize;
    NSTextView* tv = [[WPEEditorTextView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    tv.minSize = NSMakeSize(0, size.height);
    tv.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    tv.verticallyResizable = YES;
    tv.horizontallyResizable = NO;
    tv.autoresizingMask = NSViewWidthSizable;
    tv.textContainer.containerSize = NSMakeSize(size.width, CGFLOAT_MAX);
    tv.textContainer.widthTracksTextView = YES;
    tv.textContainer.lineFragmentPadding = kTextPadding;
    tv.textContainerInset = NSMakeSize(std::max<CGFloat>(0, inset.width - kTextPadding), inset.height);
    tv.richText = NO;
    tv.importsGraphics = NO;
    tv.allowsUndo = YES;
    tv.usesFindBar = NO;
    tv.font = font ?: WPEListFont();
    tv.textColor = NSColor.textColor;
    tv.backgroundColor = NSColor.textBackgroundColor;
    tv.drawsBackground = YES;
    tv.automaticQuoteSubstitutionEnabled = NO;
    tv.automaticDashSubstitutionEnabled = NO;
    tv.automaticTextReplacementEnabled = NO;
    tv.automaticSpellingCorrectionEnabled = NO;
    tv.continuousSpellCheckingEnabled = NO;
    tv.automaticDataDetectionEnabled = NO;
    tv.automaticLinkDetectionEnabled = NO;
    tv.focusRingType = NSFocusRingTypeExterior;  // drawn around the scroll view
    tv.delegate = delegate;
    sv.documentView = tv;
    return sv;
}

NSSize WPEOverlayTextInset(NSFont* font, CGFloat rowHeight, CGFloat scale) {
    font = WPEFontOrSystem(font);
    return NSMakeSize(kCellInset, WPELineTop(font, WPECentredBaseline(font, 0, rowHeight, scale)));
}
