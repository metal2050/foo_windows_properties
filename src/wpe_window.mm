#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <Quartz/Quartz.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>

#include "wpe_window.h"

#import "wpe_chrome.h"
#import "wpe_value_sheet.h"
#import "wpe_views.h"

#include <foobar2000/helpers-mac/foobar2000-mac-helpers.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <functional>
#include <memory>
#include <set>

#define WPEPropertiesWindowController FB2K_OBJC_CLASS(WPEPropertiesWindowController)
#define WPETableView FB2K_OBJC_CLASS(WPETableView)
#define WPEArtTableView FB2K_OBJC_CLASS(WPEArtTableView)
#define WPEArtCell FB2K_OBJC_CLASS(WPEArtCell)
#define WPETableViewOwner FB2K_OBJC_CLASS(WPETableViewOwner)
#define WPEArtTableViewOwner FB2K_OBJC_CLASS(WPEArtTableViewOwner)
#define WPEArtPromise FB2K_OBJC_CLASS(WPEArtPromise)
#define WPEQuitGuard FB2K_OBJC_CLASS(WPEQuitGuard)

using namespace wpe::ui;
namespace art = wpe::art;
namespace rg = wpe::rg;
namespace details = wpe::details;

namespace {

NSString* WPEStr(const std::string& s) {
    NSString* r = [NSString stringWithUTF8String:s.c_str()];
    return r ?: @"";
}

std::string WPEUtf8(NSString* s) {
    const char* p = s.UTF8String;
    return p ? std::string(p) : std::string();
}

// Uppercases the first character of every word and leaves the rest alone ("AC/DC" stays "AC/DC").
std::string WPECapitalize(const std::string& in) {
    NSString* s = WPEStr(in);
    NSMutableString* out = [NSMutableString stringWithCapacity:s.length];
    __block NSUInteger last = 0;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length)
                          options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
                       usingBlock:^(NSString*, NSRange word, NSRange, BOOL*) {
                           if (word.length == 0) return;
                           const NSRange first = [s rangeOfComposedCharacterSequenceAtIndex:word.location];
                           [out appendString:[s substringWithRange:NSMakeRange(last, first.location - last)]];
                           [out appendString:[[s substringWithRange:first] uppercaseStringWithLocale:nil]];
                           last = NSMaxRange(first);
                       }];
    [out appendString:[s substringFromIndex:last]];
    return WPEUtf8(out);
}

NSString* const kWPEFrameName = @"WPEPropertiesWindow_foo_properties_wpe";
NSString* const kWPETableName = @"WPEPropertiesTable_foo_properties_wpe";
// "2": the columns changed (Details fills the width, × is pinned trailing); old saved widths do not apply.
NSString* const kWPEArtTableName = @"WPEPropertiesArtwork2_foo_properties_wpe";
NSString* const kWPEDetailsTableName = @"WPEPropertiesDetails_foo_properties_wpe";
NSString* const kWPEReplayGainTableName = @"WPEPropertiesReplayGain_foo_properties_wpe";
NSString* const kWPEDetailsHeader = @"details.header";
NSString* const kWPETabKey = @"WPEPropertiesTab_foo_properties_wpe";
NSString* const kWPENameColumn = @"name";
NSString* const kWPEValueColumn = @"value";
NSString* const kWPEAddNewName = @"addnew";
NSString* const kWPEAddNewValue = @"addnew.value";
NSString* const kWPEArtNameColumn = @"art.name";
NSString* const kWPEArtPictureColumn = @"art.picture";
NSString* const kWPEArtDetailsColumn = @"art.details";
NSString* const kWPEArtRemoveColumn = @"art.remove";
NSString* const kWPERowView = @"row";
NSString* const kWPEReading = @"Reading tags…";
NSString* const kWPELoadingArt = @"Loading album art…";
NSString* const kWPEReadingDetails = @"Reading details…";
NSString* const kWPEAddNew = @"add new";

constexpr NSInteger kNameCol = 0;
constexpr NSInteger kValueCol = 1;

constexpr NSInteger kArtNameCol = 0;
constexpr NSInteger kArtPictureCol = 1;
constexpr NSInteger kArtDetailsCol = 2;
constexpr NSInteger kArtRemoveCol = 3;

enum : NSInteger { kTabMetadata = 0, kTabDetails, kTabReplayGain, kTabArtwork, kTabCount };

constexpr unsigned short kKeyReturn = 36;
constexpr unsigned short kKeyTab = 48;
constexpr unsigned short kKeyEnter = 76;
constexpr unsigned short kKeyBackspace = 51;
constexpr unsigned short kKeyForwardDelete = 117;
constexpr unsigned short kKeyHelpInsert = 114;
constexpr unsigned short kKeyEscape = 53;

NSUInteger trimmedLength(NSString* s) {
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length;
}

// Keypad Enter (or fn+Return) without Command. It acts exactly like Return.
bool WPEIsEnter(NSEvent* e) {
    if (e.type != NSEventTypeKeyDown || (e.modifierFlags & NSEventModifierFlagCommand)) return false;
    return e.keyCode == kKeyEnter || [e.charactersIgnoringModifiers isEqualToString:@"\x03"];
}

// Return (or keypad Enter) with any modifiers.
bool WPEIsReturn(NSEvent* e) {
    if (e.type != NSEventTypeKeyDown) return false;
    return e.keyCode == kKeyReturn || e.keyCode == kKeyEnter || [e.charactersIgnoringModifiers isEqualToString:@"\r"] ||
           [e.charactersIgnoringModifiers isEqualToString:@"\x03"];
}

NSEventModifierFlags WPEMods(NSEvent* e) {
    return e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption |
                              NSEventModifierFlagControl);
}

NSString* plural(size_t n, NSString* word) {
    return [NSString stringWithFormat:@"%zu %@%@", n, word, n == 1 ? @"" : @"s"];
}

// The physical files a write touches: the tracks' (a CUE image's subsongs count once) and the pictures'.
size_t WPEFileCount(const std::vector<size_t>& tracks, const std::vector<art::FileOps>& artFiles,
                    const std::vector<std::string>& paths) {
    std::set<size_t> touched(tracks.begin(), tracks.end());
    for (auto& f : artFiles) touched.insert(f.tracks.begin(), f.tracks.end());
    std::set<std::string> files;
    for (size_t t : touched) files.insert(t < paths.size() && !paths[t].empty() ? paths[t] : std::to_string(t));
    return files.size();
}

// The tab a new window opens on when window state is not persisted (and the fallback when it is).
NSInteger g_wpeLastTab = kTabMetadata;

// Image types kept byte for byte when pasted or dropped (what foobar2000's attach dialog offers).
NSArray<NSString*>* WPEAttachableTypes() {
    return @[ @"public.png", @"public.jpeg", @"com.compuserve.gif", @"org.webmproject.webp", @"com.microsoft.bmp" ];
}

// Picture bytes as they are attached (art::conversion_for). JPEG/PNG/GIF/WebP/BMP, what foobar2000
// attaches, are the source's own bytes. Anything else macOS can decode is converted: a HEIF or AVIF photo
// to JPEG (it is lossy already; as PNG it would be several times larger in every file), everything else
// (TIFF, PDF, ICO, …) and every picture with transparency to lossless PNG. A converted picture is drawn
// upright (its orientation applied, as foobar2000 and other players ignore the tag) at full size, in its
// own colour space. nil when the data is not a picture.
art::Picture WPEPictureFromData(NSData* data) {
    if (!data.length) return nullptr;
    const auto* bytes = static_cast<const uint8_t*>(data.bytes);
    const art::Format source = art::sniff(bytes, data.length);
    if (art::attachable(source)) return art::make_picture(bytes, data.length);
    CGImageRef image = nullptr;
    // Whether the source has transparency: its own word for it, else its pixel format (the upright copy
    // below may have an alpha channel that the source does not).
    bool hasAlpha = false;
    if (CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr)) {
        if (CGImageSourceGetCount(src) > 0) {
            NSDictionary* props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, nullptr));
            if (NSNumber* a = props[(__bridge NSString*)kCGImagePropertyHasAlpha]) {
                hasAlpha = a.boolValue;
            } else if (CGImageRef full = CGImageSourceCreateImageAtIndex(src, 0, nullptr)) {
                const CGImageAlphaInfo info = CGImageGetAlphaInfo(full);
                hasAlpha = info != kCGImageAlphaNone && info != kCGImageAlphaNoneSkipFirst && info != kCGImageAlphaNoneSkipLast;
                CGImageRelease(full);
            }
            const double w = [props[(__bridge NSString*)kCGImagePropertyPixelWidth] doubleValue];
            const double h = [props[(__bridge NSString*)kCGImagePropertyPixelHeight] doubleValue];
            if (w > 0 && h > 0) {
                // The thumbnail call at the picture's own size is the one that applies the orientation.
                NSDictionary* options = @{
                    (__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
                    (__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform : @YES,
                    (__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize : @(std::max(w, h)),
                };
                image = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)options);
            }
            if (!image) image = CGImageSourceCreateImageAtIndex(src, 0, nullptr);
        }
        CFRelease(src);
    }
    if (!image) {
        // PDF and whatever else only AppKit renders.
        NSImage* ns = [[NSImage alloc] initWithData:data];
        NSData* tiff = ns.TIFFRepresentation;
        NSBitmapImageRep* rep = tiff ? [NSBitmapImageRep imageRepWithData:tiff] : nil;
        if (rep.CGImage) image = CGImageRetain(rep.CGImage);
        hasAlpha = rep.hasAlpha;
    }
    if (!image) return nullptr;
    const bool jpeg = art::conversion_for(source, hasAlpha) == art::Conversion::JPEG;
    NSMutableData* out = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,
                                                                  (__bridge CFStringRef)(jpeg ? UTTypeJPEG : UTTypePNG).identifier, 1, nullptr);
    bool ok = false;
    if (dest) {
        NSDictionary* props = jpeg ? @{(__bridge NSString*)kCGImageDestinationLossyCompressionQuality : @(art::kJPEGQuality)} : @{};
        CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)props);
        ok = CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CGImageRelease(image);
    if (!ok || !out.length) return nullptr;
    return art::make_picture(out.bytes, out.length);
}

art::Picture WPEPictureFromPasteboard(NSPasteboard* pb) {
    if (!pb) return nullptr;
    NSArray<NSURL*>* urls = [pb readObjectsForClasses:@[ NSURL.class ] options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
    for (NSURL* url in urls) {
        if (auto p = WPEPictureFromData([NSData dataWithContentsOfURL:url])) return p;
    }
    for (NSString* type in WPEAttachableTypes()) {
        NSData* d = [pb dataForType:type];
        if (d.length && art::attachable(art::sniff(static_cast<const uint8_t*>(d.bytes), d.length)))
            return art::make_picture(d.bytes, d.length);
    }
    for (NSString* type in @[ NSPasteboardTypeTIFF, NSPasteboardTypePNG, NSPasteboardTypePDF ]) {
        if (auto p = WPEPictureFromData([pb dataForType:type])) return p;
    }
    return nullptr;
}

BOOL WPEPasteboardMayHavePicture(NSPasteboard* pb) {
    if (!pb) return NO;
    NSMutableArray* types = [WPEAttachableTypes() mutableCopy];
    [types addObjectsFromArray:@[ NSPasteboardTypeTIFF, NSPasteboardTypePDF ]];
    if ([pb availableTypeFromArray:types]) return YES;
    return [pb canReadObjectForClasses:@[ NSURL.class ] options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
}

// Marks a picture dragged from the Artwork list itself (any format: a row is copied, never imported).
NSPasteboardType const kWPEArtRowType = @"io.github.metal2050.foo_windows_properties.artwork-row";

NSArray<NSPasteboardType>* WPEDropTypes() {
    NSMutableArray* types = [WPEAttachableTypes() mutableCopy];
    [types addObjectsFromArray:@[ NSPasteboardTypeFileURL, NSPasteboardTypeTIFF, kWPEArtRowType ]];
    return types;
}

struct WPEThumb {
    art::Picture key;
    NSImage* image = nil;
    art::Dimensions dims;  // from ImageIO, for formats whose header the model does not parse
};

}

@protocol WPETableViewOwner <NSObject>
- (BOOL)wpeTableMouseDown:(NSEvent*)event;
- (BOOL)wpeTableKeyDown:(NSEvent*)event;
- (NSMenu*)wpeTableMenuForEvent:(NSEvent*)event;
- (NSView*)wpeEditingView;
- (void)wpeCopy;
- (void)wpePaste;
- (void)wpeDelete;
- (BOOL)wpeCanCopy;
- (BOOL)wpeCanPaste;
@end

@protocol WPEArtTableViewOwner <NSObject>
- (BOOL)wpeArtKeyDown:(NSEvent*)event;
- (NSMenu*)wpeArtMenuForEvent:(NSEvent*)event;
- (void)wpeArtCopy;
- (void)wpeArtPaste;
- (void)wpeArtDelete;
- (BOOL)wpeArtValidate:(SEL)action;
// Quick Look (Space): the list is the panel's controller while it has the focus.
- (void)wpeArtBeginPreviewPanel:(QLPreviewPanel*)panel;
- (void)wpeArtEndPreviewPanel:(QLPreviewPanel*)panel;
@end

#pragma mark - WPETableView

@interface WPETableView : NSTableView
@property(weak) id<WPETableViewOwner> owner;
@end

@implementation WPETableView

// Cell text fields never receive clicks directly (that is what makes AppKit's click-to-edit feel slow);
// only the cell currently being edited does.
- (NSView*)hitTest:(NSPoint)point {
    NSView* v = [super hitTest:point];
    if (!v) return nil;
    NSView* editor = [self.owner wpeEditingView];
    if (editor && [v isDescendantOf:editor]) return v;
    return self;
}

- (void)mouseDown:(NSEvent*)event {
    if (![self.owner wpeTableMouseDown:event]) [super mouseDown:event];
}

- (void)keyDown:(NSEvent*)event {
    if (![self.owner wpeTableKeyDown:event]) [super keyDown:event];
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
    return [self.owner wpeTableMenuForEvent:event];
}

- (void)copy:(id)sender {
    (void)sender;
    [self.owner wpeCopy];
}

- (void)paste:(id)sender {
    (void)sender;
    [self.owner wpePaste];
}

- (void)delete:(id)sender {
    (void)sender;
    [self.owner wpeDelete];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    const SEL a = item.action;
    if (a == @selector(copy:)) return [self.owner wpeCanCopy];
    if (a == @selector(paste:)) return [self.owner wpeCanPaste];
    if (a == @selector(delete:)) return self.selectedRowIndexes.count > 0;
    if ([NSTableView instancesRespondToSelector:@selector(validateUserInterfaceItem:)])
        return [super validateUserInterfaceItem:item];
    return YES;
}

@end

#pragma mark - WPEArtTableView

@interface WPEArtTableView : NSTableView
@property(weak) id<WPEArtTableViewOwner> owner;
@end

@implementation WPEArtTableView

// Clicks on a picture or a label select the row (and double-click reaches doubleAction); only the
// "+" and "×" buttons take clicks themselves.
- (NSView*)hitTest:(NSPoint)point {
    NSView* v = [super hitTest:point];
    if (!v || v == self || ![v isDescendantOf:self]) return v;
    for (NSView* walk = v; walk && walk != self; walk = walk.superview)
        if ([walk isKindOfClass:[NSButton class]]) return walk;
    return self;
}

- (void)keyDown:(NSEvent*)event {
    if (![self.owner wpeArtKeyDown:event]) [super keyDown:event];
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
    return [self.owner wpeArtMenuForEvent:event];
}

- (void)copy:(id)sender {
    (void)sender;
    [self.owner wpeArtCopy];
}

- (void)paste:(id)sender {
    (void)sender;
    [self.owner wpeArtPaste];
}

- (void)delete:(id)sender {
    (void)sender;
    [self.owner wpeArtDelete];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    const SEL a = item.action;
    if (a == @selector(copy:) || a == @selector(paste:) || a == @selector(delete:)) return [self.owner wpeArtValidate:a];
    if ([NSTableView instancesRespondToSelector:@selector(validateUserInterfaceItem:)])
        return [super validateUserInterfaceItem:item];
    return YES;
}

// QLPreviewPanelController: Quick Look shows the selected pictures while this list is in the responder chain.
- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel*)panel {
    (void)panel;
    return self.owner != nil;
}

- (void)beginPreviewPanelControl:(QLPreviewPanel*)panel {
    [self.owner wpeArtBeginPreviewPanel:panel];
}

- (void)endPreviewPanelControl:(QLPreviewPanel*)panel {
    [self.owner wpeArtEndPreviewPanel:panel];
}

@end

// A picture dragged out of the Artwork list: a file promise ("Front Cover.jpg", written where it is
// dropped) plus the picture's own bytes under its type, for apps that take image data.
@interface WPEArtPromise : NSFilePromiseProvider
@property(nonatomic, copy) NSData* data;
@property(nonatomic, copy) NSString* uti;
@property(nonatomic, copy) NSString* fileName;
@end

@implementation WPEArtPromise

- (NSArray<NSPasteboardType>*)writableTypesForPasteboard:(NSPasteboard*)pasteboard {
    NSMutableArray<NSPasteboardType>* types = [[super writableTypesForPasteboard:pasteboard] mutableCopy];
    if (self.uti.length && ![types containsObject:self.uti]) [types addObject:self.uti];
    [types addObject:kWPEArtRowType];
    return types;
}

- (NSPasteboardWritingOptions)writingOptionsForType:(NSPasteboardType)type pasteboard:(NSPasteboard*)pasteboard {
    if ([type isEqualToString:self.uti] || [type isEqualToString:kWPEArtRowType]) return 0;
    return [super writingOptionsForType:type pasteboard:pasteboard];
}

- (id)pasteboardPropertyListForType:(NSPasteboardType)type {
    if ([type isEqualToString:self.uti]) return self.data;
    if ([type isEqualToString:kWPEArtRowType]) return self.fileName ?: @"";
    return [super pasteboardPropertyListForType:type];
}

@end

#pragma mark - WPEPageTableView

@implementation WPEPageTableView

// As on the Metadata list, only the cell being edited takes clicks itself.
- (NSView*)hitTest:(NSPoint)point {
    NSView* v = [super hitTest:point];
    if (!v) return nil;
    NSView* editor = [self.owner wpePageEditingView:self];
    if (editor && [v isDescendantOf:editor]) return v;
    return [v isDescendantOf:self] ? self : v;
}

- (void)mouseDown:(NSEvent*)event {
    if (![self.owner wpePage:self mouseDown:event]) [super mouseDown:event];
}

- (void)keyDown:(NSEvent*)event {
    if (![self.owner wpePage:self keyDown:event]) [super keyDown:event];
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
    return [self.owner wpePage:self menuForEvent:event];
}

- (void)copy:(id)sender {
    (void)sender;
    [self.owner wpePageCopy:self];
}

- (void)delete:(id)sender {
    (void)sender;
    [self.owner wpePageDelete:self];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    const SEL a = item.action;
    if (a == @selector(copy:) || a == @selector(delete:)) return [self.owner wpePage:self validate:a];
    if ([NSTableView instancesRespondToSelector:@selector(validateUserInterfaceItem:)])
        return [super validateUserInterfaceItem:item];
    return YES;
}

@end

// An Artwork cell; `button` is the "+" of an empty Picture cell or the "×" of the last column.
@interface WPEArtCell : NSTableCellView
@property(nonatomic, strong) NSButton* button;
@end

@implementation WPEArtCell
@end

// Above a legacy (always shown) vertical scroller: continues the list header.
@implementation WPEHeaderCorner

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirty {
    [WPEColors.list setFill];
    NSRectFill(NSIntersectionRect(dirty, self.bounds));
    [WPEColors.headerLine setFill];
    const CGFloat px = WPEHairline();
    NSRectFillUsingOperation(NSMakeRect(0, NSMaxY(self.bounds) - px, NSWidth(self.bounds), px), NSCompositingOperationSourceOver);
}

@end

#pragma mark - WPEWindow

@implementation WPEWindow {
    NSEvent* _currentKeyEvent;
}

- (NSEvent*)currentKeyEvent {
    return _currentKeyEvent;
}

- (void)sendEvent:(NSEvent*)event {
    if (event.type != NSEventTypeKeyDown) {
        [super sendEvent:event];
        return;
    }
    // Control-Tab is not always offered as a key equivalent; it switches tabs here too.
    if (event.keyCode == kKeyTab && (event.modifierFlags & NSEventModifierFlagControl) && [self.owner wpeWindowShortcut:event])
        return;
    if (WPEIsEnter(event)) {
        const NSEventModifierFlags mods =
            event.modifierFlags & ~(NSEventModifierFlagNumericPad | NSEventModifierFlagFunction);
        event = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                 location:event.locationInWindow
                            modifierFlags:mods
                                timestamp:event.timestamp
                             windowNumber:event.windowNumber
                                  context:nil
                               characters:@"\r"
              charactersIgnoringModifiers:@"\r"
                                isARepeat:event.isARepeat
                                  keyCode:kKeyReturn];
    }
    NSEvent* saved = _currentKeyEvent;
    _currentKeyEvent = event;
    [super sendEvent:event];
    _currentKeyEvent = saved;
}

- (void)cancelOperation:(id)sender {
    (void)sender;
    [self.owner wpeCancel];
}

// A Return nothing in the window took (a read-only page) ends here, as an unhandled key, rather than
// at the default button.
- (void)keyDown:(NSEvent*)event {
    if (WPEIsReturn(event) && !(WPEMods(event) & NSEventModifierFlagCommand)) {
        NSBeep();
        return;
    }
    [super keyDown:event];
}

- (id)responderForAction:(SEL)sel {
    for (NSResponder* r = self.firstResponder; r; r = r.nextResponder)
        if ([r respondsToSelector:sel]) return r;
    if ([self.delegate respondsToSelector:sel]) return self.delegate;
    return nil;
}

// Standard editing shortcuts work even when the host's Edit menu does not bind them.
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    if (event.type == NSEventTypeKeyDown) {
        const NSEventModifierFlags mods = WPEMods(event);
        NSString* key = event.charactersIgnoringModifiers.lowercaseString;
        // AppKit matches Enter against the OK button's Command-Return equivalent without checking modifiers;
        // let it reach -sendEvent:, which turns it into Return for the editor or the list.
        if (WPEIsEnter(event)) return NO;
        // Plain Return (any modifiers but Command) is never the default button's: it edits the list,
        // moves its editors on, and adds lines with Option. Only Command-Return is OK.
        if (WPEIsReturn(event) && !(mods & NSEventModifierFlagCommand)) return NO;
        if ([self.owner wpeWindowShortcut:event]) return YES;
        SEL sel = NULL;
        if (mods == NSEventModifierFlagCommand) {
            if ([key isEqualToString:@"x"]) sel = @selector(cut:);
            else if ([key isEqualToString:@"c"]) sel = @selector(copy:);
            else if ([key isEqualToString:@"v"]) sel = @selector(paste:);
            else if ([key isEqualToString:@"a"]) sel = @selector(selectAll:);
            else if ([key isEqualToString:@"z"]) sel = @selector(undo:);
            else if ([key isEqualToString:@"w"]) {
                [self performClose:nil];
                return YES;
            } else if ([key isEqualToString:@"."]) {
                [self cancelOperation:nil];
                return YES;
            }
        } else if (mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift) && [key isEqualToString:@"z"]) {
            sel = @selector(redo:);
        } else if (mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift) && [key isEqualToString:@"v"] &&
                   [self.firstResponder isKindOfClass:[NSText class]]) {
            sel = @selector(pasteAsPlainText:);  // Paste and Match Style
        }
        if (sel) {
            id target = [self responderForAction:sel];
            if (target && [NSApp sendAction:sel to:target from:self]) return YES;
        }
    }
    return [super performKeyEquivalent:event];
}

@end

#pragma mark - WPEPropertiesWindowController

@interface WPEPropertiesWindowController
    : NSWindowController <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate,
                          NSTextViewDelegate, NSMenuItemValidation, WPETableViewOwner, WPEArtTableViewOwner, WPEPageTableOwner,
                          WPEWindowOwner, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSFilePromiseProviderDelegate>
- (instancetype)initWithBackend:(std::shared_ptr<wpe::Backend>)backend show:(BOOL)show;
- (void)showCascadingFrom:(NSWindow*)previous;
- (BOOL)needsQuitReview;
- (void)reviewForQuit:(void (^)(BOOL closed))reply;
- (NSString*)quitNote;
@end

static NSMutableArray<WPEPropertiesWindowController*>* g_wpeWindows;

// After Apply in the quit prompt: foobar2000 is asked to quit again once everything is written (tests
// replace this; a real terminate: would end the test run).
static void (^g_wpeQuitAgain)(void);
static void WPEInstallQuitGuard();

// Whether the quit review can show a window's close prompt. Only a window that is ordered out on its own
// cannot (it is closed with the others and logged). One that is miniaturized, or ordered out because
// foobar2000 is hidden (Cmd-H orders out every window and isVisible is then NO), is brought back to ask.
static bool WPEQuitCanAsk(bool visible, bool miniaturized, bool appHidden) {
    return visible || miniaturized || appHidden;
}

@implementation WPEPropertiesWindowController {
    std::shared_ptr<wpe::Backend> _backend;
    wpe::Table _table;
    wpe::Config _cfg;
    BOOL _show;
    BOOL _persist;
    BOOL _started;

    NSSegmentedControl* _tabs;
    NSView* _pageHost;
    NSArray<NSView*>* _pages;
    NSArray<NSTableView*>* _pageTables;
    NSInteger _tab;

    WPETableView* _tableView;
    NSScrollView* _scroll;
    CGFloat _nameFraction;  // Name column share of the list width (kept when the window is resized)
    WPEPullDownButton* _tools;
    NSButton* _ok;
    NSButton* _cancel;
    NSButton* _apply;
    NSTextField* _status;
    NSProgressIndicator* _spinner;
    NSLayoutConstraint* _statusLeading;
    NSString* _statusText;
    BOOL _statusError;
    NSMenu* _menu;
    NSMenu* _toolsMenu;
    NSFont* _font;
    NSPasteboard* _pasteboard;

    NSTextField* _editField;
    NSScrollView* _mlScroll;
    NSTextView* _mlText;
    NSInteger _editRow;
    NSInteger _editCol;
    NSString* _editInitial;

    NSInteger _pendingRow;
    NSInteger _pendingCol;
    BOOL _needsReload;
    NSInteger _reloadSelect;
    NSMutableIndexSet* _refreshRows;
    NSMutableArray<NSTextField*>* _fieldsToReset;
    NSMutableArray<NSView*>* _viewsToRemove;
    BOOL _flushScheduled;

    BOOL _writing;
    BOOL _closeAfterWrite;
    BOOL _loading;
    BOOL _closed;
    BOOL _reloadPending;
    BOOL _reloadCheckScheduled;
    uint64_t _loadGeneration;

    // Details
    WPEPageTableView* _detailsTable;
    NSScrollView* _detailsScroll;
    CGFloat _detailsFraction;
    std::vector<details::Line> _details;
    NSMenu* _detailsMenu;
    BOOL _detailsRequested;
    BOOL _detailsLoading;
    BOOL _detailsReloadPending;
    BOOL _detailsReloadScheduled;
    BOOL _detailsStale;
    uint64_t _detailsGeneration;

    // ReplayGain
    WPEPageTableView* _rgTable;
    NSScrollView* _rgScroll;
    CGFloat _rgFraction;
    rg::Table _rg;
    NSMenu* _rgMenu;
    NSTextField* _rgEditField;
    NSInteger _rgEditRow;
    NSString* _rgEditInitial;
    NSInteger _rgPendingRow;
    NSString* _rgRetryText;  // a value that did not parse, about to reopen in _rgPendingRow's editor
    BOOL _rgNeedsRefresh;

    // Artwork
    WPEArtTableView* _artTable;
    NSScrollView* _artScroll;
    NSMenu* _artMenu;
    art::Table _art;
    std::array<WPEThumb, art::TypeCount> _thumbs;
    BOOL _artRequested;
    BOOL _artLoading;
    BOOL _artReloadPending;
    uint64_t _artGeneration;
    NSString* _artError;

    // One OK/Apply: tags first, then pictures.
    std::vector<art::FileOps> _artFiles;
    std::vector<std::pair<std::string, std::string>> _writeErrors;
    size_t _writeFiles;
    BOOL _writeAborted;
    BOOL _didTags;
    BOOL _didArt;
    BOOL _tagsOK;
    BOOL _artOK;
    BOOL _artSkipped;  // the tag update was aborted, so the pictures were not written

    // Format from other fields
    NSTextField* _formatField;
    NSTextField* _formatPattern;
    NSTextField* _formatPreview;
    NSString* _lastFormatField;
    NSString* _lastFormatPattern;

    // Edit Value (several tracks): the open sheet, and the row the context menu was opened on.
    WPEEditValueSheet* _valueSheet;
    NSInteger _menuRow;

    // Asking before unapplied changes are thrown away (the close button, ⌘W, quitting foobar2000).
    NSAlert* _closeAlert;              // the open "Do you want to apply the changes…?" prompt
    void (^_closeReply)(BOOL closed);  // the quit review waiting for its answer (YES: the window closed)
    BOOL _quitAfterWrite;              // Apply in the quit prompt: quit again once everything is written

    // Quick Look (Space) and dragging pictures out.
    QLPreviewPanel* _qlPanel;          // while this window controls the shared panel
    NSArray<NSURL*>* _qlItems;
    NSString* _qlDir;                  // this window's temporary folder for the previewed pictures
    std::array<std::pair<art::Picture, NSURL*>, art::TypeCount> _qlFiles;
    NSUInteger _qlSerial;
    NSInteger _dragRow;                // the row being dragged out of the list, or -1
}

#pragma mark Lifetime

- (instancetype)initWithBackend:(std::shared_ptr<wpe::Backend>)backend show:(BOOL)show {
    WPEWindow* win = [[WPEWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 800, 624)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:YES];
    self = [super initWithWindow:win];
    if (!self) return nil;
    _backend = std::move(backend);
    _show = show;
    _persist = show && _backend->persistWindowState();
    _editRow = -1;
    _editCol = -1;
    _pendingRow = -1;
    _reloadSelect = -1;
    _tab = -1;
    _rgEditRow = -1;
    _rgPendingRow = -1;
    _menuRow = -1;
    _dragRow = -1;
    _refreshRows = [NSMutableIndexSet indexSet];
    _fieldsToReset = [NSMutableArray array];
    _viewsToRemove = [NSMutableArray array];
    _statusText = @"";
    _cfg = _backend->config();
    _font = WPEListFont();

    win.owner = self;
    win.delegate = self;
    win.releasedWhenClosed = NO;
    win.restorable = NO;
    win.tabbingMode = NSWindowTabbingModeDisallowed;
    win.minSize = NSMakeSize(480, 360);
    win.backgroundColor = WPEColors.dialog;
    [self buildContent];
    [self updateTitle];

    NSInteger tab = g_wpeLastTab;
    if (_persist) {
        NSNumber* saved = [[NSUserDefaults standardUserDefaults] objectForKey:kWPETabKey];
        if ([saved isKindOfClass:[NSNumber class]]) tab = saved.integerValue;
    }
    [self selectTab:(tab >= 0 && tab < kTabCount) ? tab : kTabMetadata];

    __weak WPEPropertiesWindowController* weakSelf = self;
    _backend->setChangeHandler([weakSelf] { [weakSelf tracksChangedOutside]; });
    _backend->setDisplayChangeHandler([weakSelf] { [weakSelf detailsChangedOutside]; });
    return self;
}

- (void)showCascadingFrom:(NSWindow*)previous {
    NSWindow* win = self.window;
    if (_show) {
        const BOOL restored = _persist && [win setFrameUsingName:kWPEFrameName];
        if (!previous) {
            if (_persist) [win setFrameAutosaveName:kWPEFrameName];
            if (!restored) [win center];
        } else {
            if (!restored) [win setFrame:previous.frame display:NO];
            const NSPoint topLeft = NSMakePoint(NSMinX(previous.frame) + 22, NSMaxY(previous.frame) - 22);
            [win setFrameTopLeftPoint:topLeft];
            const NSRect f = [win constrainFrameRect:win.frame toScreen:previous.screen ?: NSScreen.mainScreen];
            [win setFrame:f display:NO];
        }
        [win makeKeyAndOrderFront:nil];
        WPEInstallQuitGuard();
    } else {
        [win.contentView layoutSubtreeIfNeeded];
    }
    [win makeFirstResponder:[self pageTable:_tab]];
    _started = YES;
    [self startLoadAfterWrite:NO];
    if (_tab == kTabArtwork) [self ensureArtLoaded];
    if (_tab == kTabDetails) [self ensureDetailsLoaded];
}

// The close button and ⌘W. A window with nothing to lose closes at once; otherwise it asks first (Cancel,
// Esc and ⌘. are explicit discards and never ask).
- (BOOL)windowShouldClose:(NSWindow*)sender {
    (void)sender;
    if (_writing) {
        NSBeep();
        return NO;
    }
    if (_closeAlert) return NO;  // already asking
    if (![self commitForClose]) return YES;
    [self askBeforeClosing:NO reply:nil];
    return NO;
}

- (void)windowWillClose:(NSNotification*)note {
    (void)note;
    _closed = YES;
    if (NSAlert* alert = _closeAlert) {  // closed while asking (foobar2000 quitting): the question is moot
        _closeAlert = nil;
        if (alert.window.sheetParent) [self.window endSheet:alert.window returnCode:NSModalResponseAbort];
    }
    if (auto reply = _closeReply) {
        _closeReply = nil;
        reply(YES);
    }
    if (_qlPanel) {
        QLPreviewPanel* panel = _qlPanel;
        [self wpeArtEndPreviewPanel:panel];
        if (panel.visible) [panel orderOut:nil];
    }
    [self removeQuickLookFiles];
    [_valueSheet finish:NO];
    [self endEditing:NO focusTable:NO];
    [self rgEndEdit:NO focus:NO];
    _pendingRow = -1;
    _rgPendingRow = -1;
    _rgRetryText = nil;
    _backend->setChangeHandler(nullptr);
    _backend->setDisplayChangeHandler(nullptr);
    _backend->cancelPending();
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_persist && [self.window.frameAutosaveName isEqualToString:kWPEFrameName]) {
        [self.window saveFrameUsingName:kWPEFrameName];
        [self.window setFrameAutosaveName:@""];
    }
    _tableView.owner = nil;
    _tableView.dataSource = nil;
    _tableView.delegate = nil;
    _artTable.owner = nil;
    _artTable.dataSource = nil;
    _artTable.delegate = nil;
    _detailsTable.owner = nil;
    _rgTable.owner = nil;
    for (NSTableView* t in _pageTables) {
        t.dataSource = nil;
        t.delegate = nil;
    }
    _tabs.target = nil;
    _tools.prepare = nil;
    ((WPEWindow*)self.window).owner = nil;
    WPEPropertiesWindowController* keep = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_wpeWindows removeObject:keep];
    });
    if (_quitAfterWrite) {
        // Apply in the quit prompt wrote everything: quit as asked. From a timer, not from the write's
        // completion: the quit review must not run inside a main-queue block.
        _quitAfterWrite = NO;
        if (g_wpeQuitAgain) g_wpeQuitAgain();
        else [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:0];
    }
}

- (void)windowDidResize:(NSNotification*)note {
    (void)note;
    if (_mlText) [self endEditing:YES focusTable:YES];
}

- (void)windowDidEndLiveResize:(NSNotification*)note {
    (void)note;
    if (_persist && [self.window.frameAutosaveName isEqualToString:kWPEFrameName])
        [self.window saveFrameUsingName:kWPEFrameName];
}

#pragma mark Building the window

- (NSTableColumn*)column:(NSString*)identifier title:(NSString*)title width:(CGFloat)width {
    NSTableColumn* c = [[NSTableColumn alloc] initWithIdentifier:identifier];
    c.title = title;
    c.width = width;
    c.minWidth = 20;
    c.resizingMask = NSTableColumnUserResizingMask;
    return c;
}

// The Columns UI-style list: the list background, no grid, a light header, alternate rows and the Mac
// selection (the accent fill, or the unemphasized grey) drawn by WPERowView.
- (void)styleTable:(NSTableView*)t {
    t.headerView = [[WPEHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 400, kHeaderHeight)];
    t.cornerView = [[WPEHeaderCorner alloc] initWithFrame:NSMakeRect(0, 0, 16, kHeaderHeight)];
    t.backgroundColor = WPEColors.list;
    t.usesAlternatingRowBackgroundColors = NO;
    t.gridStyleMask = NSTableViewGridNone;
    t.intercellSpacing = NSMakeSize(0, 0);
    t.rowSizeStyle = NSTableViewRowSizeStyleCustom;
    t.rowHeight = kRowHeight;
    t.style = NSTableViewStylePlain;
    t.focusRingType = NSFocusRingTypeNone;
    t.allowsColumnReordering = NO;
    t.allowsColumnSelection = NO;
    t.allowsTypeSelect = NO;
    t.allowsEmptySelection = YES;
    t.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    t.dataSource = self;
    t.delegate = self;
}

- (NSScrollView*)scrollFor:(NSTableView*)table {
    NSScrollView* s = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    s.documentView = table;
    s.hasVerticalScroller = YES;
    s.hasHorizontalScroller = NO;
    s.autohidesScrollers = YES;
    s.borderType = NSNoBorder;
    s.drawsBackground = YES;
    s.backgroundColor = WPEColors.list;
    return s;
}

- (void)buildMetadataPage:(CGFloat)width {
    _tableView = [[WPETableView alloc] initWithFrame:NSMakeRect(0, 0, width, 400)];
    _tableView.owner = self;
    const CGFloat nameWidth = std::round(width * kNameColumnFraction);
    NSTableColumn* nameCol = [self column:kWPENameColumn title:@"Name" width:nameWidth];
    nameCol.minWidth = 60;
    NSTableColumn* valueCol = [self column:kWPEValueColumn title:@"Value" width:width - nameWidth];
    valueCol.minWidth = 80;
    valueCol.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [_tableView addTableColumn:nameCol];
    [_tableView addTableColumn:valueCol];
    _tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _tableView.allowsMultipleSelection = YES;
    [self styleTable:_tableView];
    if (_persist) {
        _tableView.autosaveName = kWPETableName;
        _tableView.autosaveTableColumns = YES;
    }
    // The share itself is remembered, not derived from the autosaved absolute width: that width was saved
    // for another window width, and dividing it by this one would make the column creep on every reopen.
    _nameFraction = [self storedFractionFor:_tableView];
    _scroll = [self scrollFor:_tableView];
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    _scroll.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(clipBoundsChanged:)
                                                 name:NSViewBoundsDidChangeNotification
                                               object:_scroll.contentView];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(listFrameChanged:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:_scroll];
}

- (NSString*)fractionKeyFor:(NSTableView*)table {
    return table.autosaveName.length ? [table.autosaveName stringByAppendingString:@" NameFraction"] : nil;
}

// The Name column share saved by a previous window (only when window state is persisted).
- (CGFloat)storedFractionFor:(NSTableView*)table {
    NSString* key = _persist ? [self fractionKeyFor:table] : nil;
    NSNumber* saved = key ? [[NSUserDefaults standardUserDefaults] objectForKey:key] : nil;
    if ([saved isKindOfClass:[NSNumber class]] && saved.doubleValue >= 0.05 && saved.doubleValue <= 0.9) return saved.doubleValue;
    return kNameColumnFraction;
}

// The Name column share of a Name | Value list (nil for the Artwork list).
- (CGFloat*)nameFractionOf:(NSTableView*)table {
    if (table == _tableView) return &_nameFraction;
    if (table && table == _detailsTable) return &_detailsFraction;
    if (table && table == _rgTable) return &_rgFraction;
    return nullptr;
}

// Like the Windows list, the Name column keeps its share of the width (about 28%) as the window is
// resized; dragging the divider changes that share.
- (void)listFrameChanged:(NSNotification*)note {
    NSScrollView* scroll = [note.object isKindOfClass:[NSScrollView class]] ? note.object : _scroll;
    NSTableView* table = scroll.documentView;
    CGFloat* fraction = [self nameFractionOf:table];
    const CGFloat width = NSWidth(scroll.contentView.bounds);
    if (!fraction || width <= 0) return;
    NSTableColumn* name = table.tableColumns.firstObject;
    NSTableColumn* value = table.tableColumns.lastObject;
    if (!name || !value || name == value) return;
    // By the time this runs, the last-column-only autoresizing has already fitted Value to the new width,
    // so setting Name alone would add its change on top (the columns would overflow or underfill the
    // clip view, the list could be swiped sideways and the header would end short). Value takes the rest.
    const CGFloat target = std::round(width * *fraction);
    const CGFloat nameWidth = std::max(name.minWidth, std::min(target, width - value.minWidth));
    if (std::fabs(name.width - nameWidth) >= 0.5) name.width = nameWidth;
    const CGFloat valueWidth = std::max(value.minWidth, width - name.width);
    if (std::fabs(value.width - valueWidth) >= 0.01) value.width = valueWidth;
}

// Details and ReplayGain: Name | Value lists like Metadata (same columns, rows and shading).
- (WPEPageTableView*)nameValuePage:(CGFloat)width
                          autosave:(NSString*)autosave
                          fraction:(CGFloat*)fraction
                            scroll:(NSScrollView* __strong*)scroll {
    WPEPageTableView* t = [[WPEPageTableView alloc] initWithFrame:NSMakeRect(0, 0, width, 400)];
    t.owner = self;
    const CGFloat nameWidth = std::round(width * kNameColumnFraction);
    NSTableColumn* nameCol = [self column:kWPENameColumn title:@"Name" width:nameWidth];
    nameCol.minWidth = 60;
    NSTableColumn* valueCol = [self column:kWPEValueColumn title:@"Value" width:width - nameWidth];
    valueCol.minWidth = 80;
    valueCol.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [t addTableColumn:nameCol];
    [t addTableColumn:valueCol];
    t.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    t.allowsMultipleSelection = YES;
    [self styleTable:t];
    t.floatsGroupRows = NO;
    if (_persist) {
        t.autosaveName = autosave;
        t.autosaveTableColumns = YES;
    }
    *fraction = [self storedFractionFor:t];
    NSScrollView* s = [self scrollFor:t];
    s.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(listFrameChanged:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:s];
    *scroll = s;
    return t;
}

- (void)buildArtworkPage {
    _artTable = [[WPEArtTableView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    _artTable.owner = self;
    // Name | Picture | Details | ×: Name and Picture one picture width each, Details the rest of the
    // width, and × pinned to the trailing edge (no empty header stub, no gap after it).
    NSTableColumn* name = [self column:kWPEArtNameColumn title:@"Name" width:kArtRowHeight];
    name.minWidth = 60;
    NSTableColumn* picture = [self column:kWPEArtPictureColumn title:@"Picture" width:kArtRowHeight];
    picture.resizingMask = NSTableColumnNoResizing;
    picture.minWidth = picture.maxWidth = kArtRowHeight;
    NSTableColumn* details = [self column:kWPEArtDetailsColumn title:@"Details" width:2 * kArtRowHeight];
    details.minWidth = 60;
    details.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    NSTableColumn* remove = [self column:kWPEArtRemoveColumn title:@"" width:kArtRemoveWidth];
    remove.resizingMask = NSTableColumnNoResizing;
    remove.minWidth = remove.maxWidth = kArtRemoveWidth;
    for (NSTableColumn* c in @[ name, picture, details, remove ]) [_artTable addTableColumn:c];
    // Only Details autoresizes, so it takes whatever width the window and the Name column leave.
    _artTable.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _artTable.allowsMultipleSelection = YES;
    [self styleTable:_artTable];
    _artTable.rowHeight = kArtRowHeight;
    _artTable.target = self;
    _artTable.doubleAction = @selector(artDoubleClicked:);
    [_artTable registerForDraggedTypes:WPEDropTypes()];
    // Pictures drag out as files ("Front Cover.jpg") and as image data, or onto another row as a copy.
    [_artTable setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    [_artTable setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
    if (_persist) {
        _artTable.autosaveName = kWPEArtTableName;
        _artTable.autosaveTableColumns = YES;
    }
    _artScroll = [self scrollFor:_artTable];
}

- (NSMenuItem*)item:(NSString*)title action:(SEL)action in:(NSMenu*)menu {
    NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    mi.target = self;
    [menu addItem:mi];
    return mi;
}

- (void)buildMenus {
    _menu = [[NSMenu alloc] initWithTitle:@""];
    _menu.autoenablesItems = YES;
    [self item:@"Edit" action:@selector(editSelected:) in:_menu];
    // With several tracks a double-click on a name opens Edit Value, so renaming moves to the menu.
    if (_backend->trackCount() >= 2) {
        [self item:@"Edit values per track…" action:@selector(editValuesPerTrack:) in:_menu];
        [self item:@"Rename" action:@selector(renameField:) in:_menu];
    }
    [self item:@"Add New Field" action:@selector(addField:) in:_menu];
    [self item:@"Remove" action:@selector(removeSelected:) in:_menu];
    [_menu addItem:[NSMenuItem separatorItem]];
    [self item:@"Copy" action:@selector(copyFields:) in:_menu];
    [self item:@"Paste" action:@selector(pasteFields:) in:_menu];
    [_menu addItem:[NSMenuItem separatorItem]];
    [self item:@"Capitalize" action:@selector(capitalizeSelected:) in:_menu];
    [self item:@"Auto Track Number" action:@selector(autoTrackNumber:) in:_menu];

    // Tools: operations on the window's staged Metadata (nothing here touches files directly). The
    // pull-down's first item is its title.
    _toolsMenu = _tools.menu;
    _toolsMenu.autoenablesItems = YES;
    [self item:@"Format from Other Fields…" action:@selector(formatFromOtherFields:) in:_toolsMenu];
    [self item:@"Auto Track Number" action:@selector(autoTrackNumber:) in:_toolsMenu];
    [_toolsMenu addItem:[NSMenuItem separatorItem]];
    [self item:@"Copy All Fields" action:@selector(copyAllFields:) in:_toolsMenu];
    NSMenuItem* pasteFields = [self item:@"Paste Fields" action:@selector(pasteAllFields:) in:_toolsMenu];
    pasteFields.keyEquivalent = @"v";
    pasteFields.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [self item:@"Remove All Fields" action:@selector(removeAllFields:) in:_toolsMenu];
    [_toolsMenu addItem:[NSMenuItem separatorItem]];
    NSMenu* selection = [[NSMenu alloc] initWithTitle:@"Selection"];
    selection.autoenablesItems = YES;
    [self item:@"Edit" action:@selector(editSelected:) in:selection];
    [self item:@"Remove" action:@selector(removeSelected:) in:selection];
    [self item:@"Copy" action:@selector(copyFields:) in:selection];
    [self item:@"Paste" action:@selector(pasteFields:) in:selection];
    [self item:@"Capitalize" action:@selector(capitalizeSelected:) in:selection];
    NSMenuItem* sel = [[NSMenuItem alloc] initWithTitle:@"Selection" action:NULL keyEquivalent:@""];
    sel.submenu = selection;
    [_toolsMenu addItem:sel];

    // Artwork rows. The wording is the host's own (FB2KPropertiesDialogV2.nib, Artwork page).
    _artMenu = [[NSMenu alloc] initWithTitle:@""];
    _artMenu.autoenablesItems = YES;
    [self item:@"Import from file…" action:@selector(artImport:) in:_artMenu];
    [self item:@"Export to file…" action:@selector(artExport:) in:_artMenu];
    [_artMenu addItem:[NSMenuItem separatorItem]];
    [self item:@"Copy" action:@selector(artCopy:) in:_artMenu];
    [self item:@"Paste here" action:@selector(artPaste:) in:_artMenu];
    [_artMenu addItem:[NSMenuItem separatorItem]];
    [self item:@"Remove" action:@selector(artRemove:) in:_artMenu];

    _detailsMenu = [[NSMenu alloc] initWithTitle:@""];
    _detailsMenu.autoenablesItems = YES;
    [self item:@"Copy" action:@selector(detailsCopy:) in:_detailsMenu];
    [self item:@"Select All" action:@selector(detailsSelectAll:) in:_detailsMenu];

    _rgMenu = [[NSMenu alloc] initWithTitle:@""];
    _rgMenu.autoenablesItems = YES;
    [self item:@"Edit" action:@selector(rgEditSelected:) in:_rgMenu];
    [self item:@"Clear" action:@selector(rgClearSelected:) in:_rgMenu];
    [_rgMenu addItem:[NSMenuItem separatorItem]];
    [self item:@"Copy" action:@selector(rgCopy:) in:_rgMenu];
}

- (void)buildContent {
    NSView* content = self.window.contentView;
    const CGFloat width = NSWidth(content.bounds);

    // The pages: a native segmented control in a band under the title bar, at its leading edge where the
    // list's text starts (kPageControlInset: in line with the Name header). It takes keyboard focus and
    // speaks to VoiceOver like any segmented control.
    WPEBarView* band = [[WPEBarView alloc] initWithFrame:NSMakeRect(0, 0, width, 34)];
    band.translatesAutoresizingMaskIntoConstraints = NO;
    _tabs = WPEPageControl(@[ @"Metadata", @"Details", @"ReplayGain", @"Artwork" ], self, @selector(tabPicked:));
    [band addSubview:_tabs];

    [self buildMetadataPage:width];
    _detailsTable = [self nameValuePage:width autosave:kWPEDetailsTableName fraction:&_detailsFraction scroll:&_detailsScroll];
    _detailsTable.floatsGroupRows = YES;  // the section header stays at the top while its lines scroll
    _rgTable = [self nameValuePage:width autosave:kWPEReplayGainTableName fraction:&_rgFraction scroll:&_rgScroll];
    [self buildArtworkPage];
    _pages = @[ _scroll, _detailsScroll, _rgScroll, _artScroll ];
    _pageTables = @[ _tableView, _detailsTable, _rgTable, _artTable ];

    _pageHost = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 400)];
    _pageHost.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView* page in _pages) {
        page.hidden = YES;
        [_pageHost addSubview:page];
        [NSLayoutConstraint activateConstraints:@[
            [page.topAnchor constraintEqualToAnchor:_pageHost.topAnchor],
            [page.bottomAnchor constraintEqualToAnchor:_pageHost.bottomAnchor],
            [page.leadingAnchor constraintEqualToAnchor:_pageHost.leadingAnchor],
            [page.trailingAnchor constraintEqualToAnchor:_pageHost.trailingAnchor],
        ]];
    }

    // The button bar, in Mac order: the Tools pull-down and the status line at the leading edge;
    // Apply, Cancel and OK (the default button, rightmost) at the trailing edge.
    WPEBarView* buttonBar = [[WPEBarView alloc] initWithFrame:NSMakeRect(0, 0, width, 44)];
    buttonBar.translatesAutoresizingMaskIntoConstraints = NO;
    buttonBar.wpeTopLine = YES;  // a separator above a window's bottom bar, as AppKit draws one
    _tools = [WPEPullDownButton pullDownWithTitle:@"Tools"];
    _tools.toolTip = @"Operations on the fields in this window (written with OK or Apply)";
    __weak WPEPropertiesWindowController* weakSelf = self;
    _tools.prepare = ^BOOL {
        WPEPropertiesWindowController* me = weakSelf;
        return me ? [me prepareTools] : NO;
    };
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 16, 16)];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.indeterminate = YES;
    _spinner.displayedWhenStopped = NO;
    _spinner.hidden = YES;
    _status = WPEStatusLabel();
    _apply = WPEPushButton(@"Apply", self, @selector(applyPressed:));
    _apply.toolTip = @"Write the changes and keep the window open";
    _cancel = WPEPushButton(@"Cancel", self, @selector(cancelPressed:));
    _cancel.toolTip = @"Close without writing (Esc)";
    _ok = WPEPushButton(@"OK", self, @selector(okPressed:));
    _ok.toolTip = @"Write the changes and close (⌘↩)";
    for (NSView* v in @[ _tools, _spinner, _status, _apply, _cancel, _ok ]) [buttonBar addSubview:v];

    for (NSView* v in @[ band, _pageHost, buttonBar ]) [content addSubview:v];

    // Every control is placed by its alignment rect (its bezel), in both AppKit designs.
    _statusLeading = [_status.leadingAnchor constraintEqualToAnchor:_tools.trailingAnchor constant:kBarSpacing];
    [NSLayoutConstraint activateConstraints:@[
        [band.topAnchor constraintEqualToAnchor:content.topAnchor],
        [band.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [band.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_tabs.topAnchor constraintEqualToAnchor:band.topAnchor constant:kPageBandInset],
        [band.bottomAnchor constraintEqualToAnchor:_tabs.bottomAnchor constant:kPageBandInset],
        [_tabs.leadingAnchor constraintEqualToAnchor:band.leadingAnchor constant:kPageControlInset],
        [_tabs.trailingAnchor constraintLessThanOrEqualToAnchor:band.trailingAnchor constant:-kPageControlInset],

        [_pageHost.topAnchor constraintEqualToAnchor:band.bottomAnchor],
        [_pageHost.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_pageHost.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_pageHost.bottomAnchor constraintEqualToAnchor:buttonBar.topAnchor],

        [buttonBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [buttonBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [buttonBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [_ok.topAnchor constraintEqualToAnchor:buttonBar.topAnchor constant:kBarInset],
        [buttonBar.bottomAnchor constraintEqualToAnchor:_ok.bottomAnchor constant:kBarInset],

        [_ok.trailingAnchor constraintEqualToAnchor:buttonBar.trailingAnchor constant:-kBarMargin],
        [_cancel.trailingAnchor constraintEqualToAnchor:_ok.leadingAnchor constant:-kBarSpacing],
        [_apply.trailingAnchor constraintEqualToAnchor:_cancel.leadingAnchor constant:-kBarSpacing],
        [_cancel.widthAnchor constraintEqualToAnchor:_ok.widthAnchor],
        [_apply.widthAnchor constraintEqualToAnchor:_ok.widthAnchor],
        [_cancel.centerYAnchor constraintEqualToAnchor:_ok.centerYAnchor],
        [_apply.centerYAnchor constraintEqualToAnchor:_ok.centerYAnchor],

        [_tools.leadingAnchor constraintEqualToAnchor:buttonBar.leadingAnchor constant:kBarMargin],
        [_tools.centerYAnchor constraintEqualToAnchor:_ok.centerYAnchor],
        [_spinner.leadingAnchor constraintEqualToAnchor:_tools.trailingAnchor constant:kBarSpacing],
        [_spinner.centerYAnchor constraintEqualToAnchor:_ok.centerYAnchor],
        _statusLeading,
        [_status.trailingAnchor constraintLessThanOrEqualToAnchor:_apply.leadingAnchor constant:-kBarSpacing],
        [_status.firstBaselineAnchor constraintEqualToAnchor:_ok.firstBaselineAnchor],
    ]];

    [self buildMenus];
    WPEMakeDefaultButton(_ok);
    self.window.initialFirstResponder = _tableView;
    [self updateButtons];
}

// "Properties — <title>" or "Properties — N Tracks"; one local file also gets the title bar's proxy icon
// (Command-click for its path, drag it out like any document window's file).
- (void)updateTitle {
    self.window.title = WPEStr(_backend->windowTitle());
    const std::string file = _backend->representedFile();
    NSURL* url = file.empty() ? nil : [NSURL fileURLWithPath:WPEStr(file) isDirectory:NO];
    if (!(url == self.window.representedURL || [url isEqual:self.window.representedURL])) self.window.representedURL = url;
}

#pragma mark Tabs

- (NSTableView*)pageTable:(NSInteger)tab {
    return (tab >= 0 && tab < (NSInteger)_pageTables.count) ? _pageTables[(NSUInteger)tab] : _tableView;
}

// A page picked from the keyboard on the control itself (Full Keyboard Access: Tab to it, arrow, Space)
// leaves the focus on the control, as AppKit segmented controls do; a click, Control-Tab or Command-1…4
// moves it to the page's list.
- (void)tabPicked:(id)sender {
    const BOOL keepFocus = sender == _tabs && self.window.firstResponder == _tabs;
    [self selectTab:_tabs.selectedSegment focusPage:!keepFocus];
}

- (void)selectTab:(NSInteger)tab {
    [self selectTab:tab focusPage:YES];
}

- (void)selectTab:(NSInteger)tab focusPage:(BOOL)focusPage {
    if (tab < 0 || tab >= kTabCount) return;
    if (tab != _tab && _tab == kTabMetadata) [self prepareCommand];
    // A ReplayGain value that does not parse keeps the page (and its editor, with the typed text).
    if (tab != _tab && _tab == kTabReplayGain && ![self rgFinishEdit]) {
        _tabs.selectedSegment = _tab;
        return;
    }
    const BOOL focus = focusPage && _tab >= 0 && tab != _tab;
    _tab = tab;
    _tabs.selectedSegment = tab;
    for (NSInteger i = 0; i < (NSInteger)_pages.count; ++i) _pages[(NSUInteger)i].hidden = i != tab;
    g_wpeLastTab = tab;
    if (_persist) [[NSUserDefaults standardUserDefaults] setInteger:tab forKey:kWPETabKey];
    if (tab == kTabArtwork && _started) [self ensureArtLoaded];
    if (tab == kTabDetails && _started) {
        if (_detailsStale) [self detailsChangedOutside];
        else [self ensureDetailsLoaded];
    }
    if (focus) [self.window makeFirstResponder:[self pageTable:tab]];
    [self updateButtons];
}

- (void)showMetadataPage {
    if (_tab != kTabMetadata) [self selectTab:kTabMetadata];
}

// Control-Tab / Control-Shift-Tab and Command-1…4 switch tabs; Command-Shift-V is Paste fields.
- (BOOL)wpeWindowShortcut:(NSEvent*)event {
    if (_closed || event.type != NSEventTypeKeyDown) return NO;
    const NSEventModifierFlags mods = WPEMods(event);
    if (event.keyCode == kKeyTab && (mods & NSEventModifierFlagControl) &&
        !(mods & (NSEventModifierFlagCommand | NSEventModifierFlagOption))) {
        const NSInteger step = (mods & NSEventModifierFlagShift) ? kTabCount - 1 : 1;
        [self selectTab:(_tab + step) % kTabCount];
        return YES;
    }
    NSString* key = event.charactersIgnoringModifiers.lowercaseString;
    if (mods == NSEventModifierFlagCommand && key.length == 1) {
        const unichar c = [key characterAtIndex:0];
        if (c >= '1' && c < '1' + kTabCount) {
            [self selectTab:c - '1'];
            return YES;
        }
    }
    // Paste fields belongs to the Metadata list. In a text editor (Metadata, ReplayGain, the multi-line
    // editor) the key is the text view's own Paste and Match Style, and other pages leave it alone.
    if (mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift) && [key isEqualToString:@"v"]) {
        if (_tab != kTabMetadata || [self anyEditing] || [self.window.firstResponder isKindOfClass:[NSText class]]) return NO;
        [self pasteAllFields:nil];
        return YES;
    }
    return NO;
}

#pragma mark Loading

- (void)startLoadAfterWrite:(BOOL)afterWrite {
    const uint64_t generation = ++_loadGeneration;
    _loading = YES;
    _reloadPending = NO;
    __weak WPEPropertiesWindowController* weakSelf = self;
    const bool sync = _backend->load(afterWrite, [weakSelf, generation](std::vector<wpe::TrackFields> fields,
                                                                         std::vector<rg::Info> gains) {
        [weakSelf finishLoad:fields replayGain:gains generation:generation];
    });
    if (!sync && _loading && generation == _loadGeneration) {
        [self setStatus:kWPEReading error:NO];
        [self updateButtons];
    }
}

- (void)finishLoad:(const std::vector<wpe::TrackFields>&)fields
        replayGain:(std::vector<rg::Info>&)gains
        generation:(uint64_t)generation {
    if (generation != _loadGeneration || _closed) return;
    _loading = NO;
    if ([_statusText isEqualToString:kWPEReading]) [self setStatus:@"" error:NO];
    gains.resize(fields.size());
    [self applyReplayGain:std::move(gains)];
    [self applyFields:fields];
    [self schedulePendingReload];
}

- (void)applyReplayGain:(std::vector<rg::Info>)gains {
    [self rgEndEdit:NO focus:_tab == kTabReplayGain];
    _rgPendingRow = -1;
    _rgRetryText = nil;
    _rg.load(std::move(gains));
    _rgNeedsRefresh = NO;
    [self flushUI];
    NSIndexSet* sel = _rgTable.selectedRowIndexes;
    [_rgTable reloadData];
    [self refreshRowDecorations:_rgTable];
    [_rgTable selectRowIndexes:sel byExtendingSelection:NO];  // like Windows, nothing is selected at first
}

- (void)applyFields:(const std::vector<wpe::TrackFields>&)fields {
    [self endEditing:NO focusTable:YES];
    _pendingRow = -1;
    NSMutableArray<NSString*>* selectedFields = [NSMutableArray array];
    [_tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL*) {
        if (i < _table.size()) [selectedFields addObject:WPEStr(_table.row(i).field)];
    }];
    const NSPoint scroll = _scroll.contentView.bounds.origin;

    _table.load(fields, _cfg);
    _needsReload = NO;
    [_refreshRows removeAllIndexes];
    [_tableView reloadData];
    [self refreshRowDecorations:_tableView];

    NSMutableIndexSet* sel = [NSMutableIndexSet indexSet];
    for (NSString* f in selectedFields) {
        const size_t i = _table.find(WPEUtf8(f));
        if (i != wpe::npos) [sel addIndex:i];
    }
    // Like the Windows dialog, the list opens with nothing selected (keys act on the first row then).
    [_tableView selectRowIndexes:sel byExtendingSelection:NO];
    [_scroll.contentView scrollToPoint:scroll];
    [_scroll reflectScrolledClipView:_scroll.contentView];
    [self updateTitle];
    [self updateButtons];
}

// A change that arrives while a cell is being edited or tags are loading is remembered and reloaded
// (if the table is still clean) once that finishes, so later edits never start from stale values.
- (void)tracksChangedOutside {
    if (_closed) return;
    [self artChangedOutside];
    [self detailsChangedOutside];
    if (_writing || _loading || [self anyEditing] || _pendingRow >= 0 || _rgPendingRow >= 0) {
        _reloadPending = YES;
        return;
    }
    if (_table.dirty() || _rg.dirty()) return;
    [self startLoadAfterWrite:NO];
}

// Any inline editor open (Metadata or ReplayGain), or the Edit Value sheet.
- (BOOL)anyEditing {
    return [self isEditing] || _rgEditField != nil || _valueSheet != nil;
}

- (void)schedulePendingReload {
    if (!_reloadPending || _reloadCheckScheduled || _closed) return;
    _reloadCheckScheduled = YES;
    __weak WPEPropertiesWindowController* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf runPendingReload];
    });
}

- (void)runPendingReload {
    _reloadCheckScheduled = NO;
    if (!_reloadPending || _closed || _writing || _loading || [self anyEditing]) return;
    if (_pendingRow >= 0 || _rgPendingRow >= 0) {
        [self schedulePendingReload];
        return;
    }
    _reloadPending = NO;
    if (!_table.dirty() && !_rg.dirty()) [self startLoadAfterWrite:NO];
}

#pragma mark Table data

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    if (tableView == _tableView) return (NSInteger)_table.size() + 1;  // + "add new"
    if (tableView == _artTable) return (NSInteger)art::TypeCount;
    if (tableView == _detailsTable) return (NSInteger)_details.size();
    if (tableView == _rgTable) return (NSInteger)rg::FieldCount;
    return 0;
}

- (BOOL)isAddNewRow:(NSInteger)row {
    return row >= 0 && (size_t)row == _table.size();
}

// A list cell: its text field fills it (WPEListTextCell: the text optically centred, kCellInset in), or,
// with a glyph, the glyph kCellInset in and the text after it.
- (NSTableCellView*)makeCell:(NSString*)identifier {
    return WPEMakeListCell(identifier, _font, self, nil);
}

- (NSTableCellView*)makeCell:(NSString*)identifier glyph:(NSImage*)glyph {
    return WPEMakeListCell(identifier, _font, self, glyph);
}

- (void)configureCell:(NSTableCellView*)cell column:(NSInteger)col row:(NSInteger)row {
    NSTextField* tf = cell.textField;
    if (!tf || tf == _editField || row < 0 || (size_t)row >= _table.size()) return;
    const wpe::Row& r = _table.row((size_t)row);
    if (col == kNameCol) {
        WPESetListText(tf, WPEStr(r.label), NSColor.labelColor);
        tf.toolTip = r.standard ? WPEStr(r.field) : nil;
    } else {
        const wpe::Display d = _table.display((size_t)row);
        WPESetListText(tf, WPEStr(d.text), d.mixed ? NSColor.secondaryLabelColor : NSColor.labelColor);
        tf.toolTip = nil;
    }
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    if (tableView == _artTable) return [self artViewForColumn:column row:row];
    if (tableView == _detailsTable) return [self detailsViewForColumn:column row:row];
    if (tableView == _rgTable) {
        const BOOL name = [column.identifier isEqualToString:kWPENameColumn];
        NSTableCellView* cell = [tableView makeViewWithIdentifier:column.identifier owner:self];
        if (!cell) cell = [self makeCell:column.identifier];
        [self configureReplayGainCell:cell column:name ? kNameCol : kValueCol row:row];
        return cell;
    }
    if (tableView != _tableView) return nil;
    const BOOL nameColumn = [column.identifier isEqualToString:kWPENameColumn];
    if ([self isAddNewRow:row]) {
        NSString* ident = nameColumn ? kWPEAddNewName : kWPEAddNewValue;
        NSTableCellView* cell = [tableView makeViewWithIdentifier:ident owner:self];
        if (!cell) {
            // The add row: plus.circle.fill where the names start, then "add new" (foobar2000's wording).
            NSImage* glyph = nil;
            if (nameColumn) {
                glyph = [NSImage imageWithSystemSymbolName:@"plus.circle.fill" accessibilityDescription:nil];
                glyph = [glyph imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:kAddGlyphSize
                                                                                                            weight:NSFontWeightRegular]];
            }
            cell = [self makeCell:ident glyph:glyph];
            WPESetListText(cell.textField, nameColumn ? kWPEAddNew : @"", NSColor.secondaryLabelColor);
            cell.textField.toolTip = nameColumn ? @"Add a new field (Insert)" : nil;
            if (nameColumn) {
                cell.textField.accessibilityLabel = @"Add New Field";
                cell.textField.accessibilityHelp = @"Adds a field: type its name, then Return to type its value (Insert)";
            }
        }
        return cell;
    }
    NSString* ident = column.identifier;
    NSTableCellView* cell = [tableView makeViewWithIdentifier:ident owner:self];
    if (!cell) cell = [self makeCell:ident];
    [self configureCell:cell column:nameColumn ? kNameCol : kValueCol row:row];
    return cell;
}

- (NSTableRowView*)tableView:(NSTableView*)tableView rowViewForRow:(NSInteger)row {
    (void)row;
    WPERowView* v = [tableView makeViewWithIdentifier:kWPERowView owner:self];
    if (!v) {
        v = [[WPERowView alloc] initWithFrame:NSZeroRect];
        v.identifier = kWPERowView;
    }
    return v;
}

// Every other row is shaded (Metadata only), and field rows get the faint Name|Value line.
- (void)decorateRowView:(NSTableRowView*)rowView row:(NSInteger)row table:(NSTableView*)table {
    if (![rowView isKindOfClass:[WPERowView class]]) return;
    WPERowView* v = (WPERowView*)rowView;
    v.wpeBand = NO;
    if (table == _artTable) {
        v.wpeShaded = NO;
        v.wpeColumnLineX = 0;
        return;
    }
    if (table == _detailsTable && row >= 0 && (size_t)row < _details.size() && _details[(size_t)row].header) {
        v.wpeBand = YES;
        v.wpeShaded = NO;
        v.wpeColumnLineX = 0;
        return;
    }
    v.wpeShaded = (row % 2) == 1;
    const BOOL field = table != _tableView || (row >= 0 && (size_t)row < _table.size());
    v.wpeColumnLineX = field && table.numberOfColumns > 1 ? NSMaxX([table rectOfColumn:0]) : 0;
}

- (void)tableView:(NSTableView*)tableView didAddRowView:(NSTableRowView*)rowView forRow:(NSInteger)row {
    [self decorateRowView:rowView row:row table:tableView];
}

- (void)refreshRowDecorations:(NSTableView*)table {
    [table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView* rowView, NSInteger row) {
        [self decorateRowView:rowView row:row table:table];
    }];
}

// Details: section headers span the row and cannot be selected.
- (BOOL)tableView:(NSTableView*)tableView isGroupRow:(NSInteger)row {
    return tableView == _detailsTable && row >= 0 && (size_t)row < _details.size() && _details[(size_t)row].header;
}

- (NSIndexSet*)tableView:(NSTableView*)tableView selectionIndexesForProposedSelection:(NSIndexSet*)proposed {
    if (tableView != _detailsTable) return proposed;
    NSMutableIndexSet* out = [proposed mutableCopy];
    [proposed enumerateIndexesUsingBlock:^(NSUInteger i, BOOL*) {
        if (i >= _details.size() || _details[i].header) [out removeIndex:i];
    }];
    return out;
}

- (void)tableViewSelectionDidChange:(NSNotification*)note {
    [self updateButtons];
    if (note.object == _artTable) [self reloadQuickLook];
}

- (void)tableViewColumnDidResize:(NSNotification*)note {
    NSTableView* table = note.object;
    if (table == _tableView && _mlText) [self endEditing:YES focusTable:YES];
    CGFloat* fraction = [self nameFractionOf:table];
    if (fraction && table.headerView.resizedColumn == 0) {
        const CGFloat width = NSWidth(table.enclosingScrollView.contentView.bounds);
        if (width > 0) {
            *fraction = std::clamp<CGFloat>(table.tableColumns.firstObject.width / width, 0.05, 0.9);
            if (NSString* key = _persist ? [self fractionKeyFor:table] : nil)
                [[NSUserDefaults standardUserDefaults] setDouble:*fraction forKey:key];
        }
    }
    [self refreshRowDecorations:table];
}

- (void)clipBoundsChanged:(NSNotification*)note {
    (void)note;
    if (_mlText) {
        [self endEditing:YES focusTable:YES];
        return;
    }
    if (_editField && _editRow >= 0) {
        const NSRange visible = [_tableView rowsInRect:_tableView.visibleRect];
        if (!NSLocationInRange((NSUInteger)_editRow, visible)) [self endEditing:YES focusTable:YES];
    }
}

- (void)refreshRow:(NSInteger)row {
    if (row < 0 || row >= _tableView.numberOfRows) return;
    for (NSInteger col = 0; col < 2; ++col) {
        NSTableCellView* cell = [_tableView viewAtColumn:col row:row makeIfNecessary:NO];
        if (cell) [self configureCell:cell column:col row:row];
    }
}

- (void)scheduleFlush {
    if (_flushScheduled) return;
    _flushScheduled = YES;
    __weak WPEPropertiesWindowController* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf flushUI];
    });
}

// Applies table changes that must not happen inside field-editor callbacks.
- (void)flushUI {
    _flushScheduled = NO;
    for (NSTextField* tf in _fieldsToReset) [self resetEditorField:tf];
    [_fieldsToReset removeAllObjects];
    for (NSView* v in _viewsToRemove) [v removeFromSuperview];
    [_viewsToRemove removeAllObjects];
    if (_rgNeedsRefresh) {
        _rgNeedsRefresh = NO;
        [self refreshReplayGainRows];
    }
    if (_needsReload) {
        _needsReload = NO;
        [_refreshRows removeAllIndexes];
        [_tableView reloadData];
        [self refreshRowDecorations:_tableView];
        if (_reloadSelect >= 0 && _table.size() > 0) {
            const NSInteger r = std::min<NSInteger>(_reloadSelect, (NSInteger)_table.size() - 1);
            [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)r] byExtendingSelection:NO];
            [_tableView scrollRowToVisible:r];
        }
        _reloadSelect = -1;
    } else if (_refreshRows.count) {
        NSIndexSet* rows = [_refreshRows copy];
        [_refreshRows removeAllIndexes];
        [rows enumerateIndexesUsingBlock:^(NSUInteger i, BOOL*) {
            [self refreshRow:(NSInteger)i];
        }];
    }
    [self updateButtons];
}

#pragma mark Editing

- (NSView*)wpeEditingView {
    return _editField;
}

- (BOOL)isEditing {
    return _editField != nil || _mlText != nil;
}

- (void)resetEditorField:(NSTextField*)tf {
    if (tf == _editField || tf == _rgEditField) return;
    WPEEndInlineEdit(tf);
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

// Starts editing a cell with its text fully selected. A non-nil key event is then replayed into the
// editor, so typing on the list replaces the value (dead keys and input methods included).
- (void)beginEditRow:(NSInteger)row column:(NSInteger)col key:(NSEvent*)key {
    _pendingRow = -1;
    if (_writing || _loading || _closed) return;
    if ([self isAddNewRow:row]) {
        [self addFieldWithKey:key];
        return;
    }
    if ([self isEditing]) [self endEditing:YES focusTable:YES];
    [self flushUI];
    if (row < 0 || (size_t)row >= _table.size()) return;
    const wpe::Row& r = _table.row((size_t)row);
    if (_table.isPendingName((size_t)row)) col = kNameCol;
    else if (col == kNameCol && r.standard) col = kValueCol;

    [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [_tableView scrollRowToVisible:row];

    NSString* text = col == kNameCol ? WPEStr(r.field) : WPEStr(_table.editText((size_t)row));
    if (col == kValueCol && _table.isMultiline((size_t)row)) {
        [self beginMultilineRow:row text:text initial:text];
    } else {
        NSTableCellView* cell = [_tableView viewAtColumn:col row:row makeIfNecessary:YES];
        NSTextField* tf = cell.textField;
        if (!tf) return;
        _editField = tf;
        _editRow = row;
        _editCol = col;
        _editInitial = [text copy];
        tf.stringValue = text;
        // The editor fills the cell, its text where the label's was, with the focus ring inside the cell.
        WPEBeginInlineEdit(tf);
        if (![self.window makeFirstResponder:tf]) {
            _editField = nil;
            _editRow = _editCol = -1;
            [self resetEditorField:tf];
            [self configureCell:cell column:col row:row];
            return;
        }
        NSTextView* fe = (NSTextView*)tf.currentEditor;
        [self disableSubstitutions:fe];
        [fe selectAll:nil];
    }
    if (key) {
        NSResponder* fr = self.window.firstResponder;
        if (fr && fr != _tableView) [fr keyDown:key];
    }
}

// Over the Value cell (column line to the list's edge), from the row's top down, inside the visible list.
- (NSRect)multilineFrameForRow:(NSInteger)row {
    NSView* content = self.window.contentView;
    const NSRect cell = [_tableView convertRect:[_tableView frameOfCellAtColumn:kValueCol row:row] toView:content];
    const NSRect visible = [_scroll.contentView convertRect:_scroll.contentView.bounds toView:content];
    const CGFloat height = std::max<CGFloat>(_tableView.rowHeight * 6, 96);
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

// Multiline values (COMMENT, LYRICS, values with line breaks) get a text view floating over the cell: no
// bezel, a hairline frame, a soft shadow and the focus ring, its first line where the cell's text was.
- (void)beginMultilineRow:(NSInteger)row text:(NSString*)text initial:(NSString*)initial {
    const NSRect frame = [self multilineFrameForRow:row];
    WPEEditorScrollView* sv =
        WPEMakeTextEditor(frame, _font, WPEOverlayTextInset(_font, _tableView.rowHeight, WPEDeviceScale(_tableView, NO)), self);
    sv.wpeFloating = YES;
    NSTextView* tv = sv.documentView;
    tv.string = text;
    [self.window.contentView addSubview:sv positioned:NSWindowAbove relativeTo:nil];

    _mlScroll = sv;
    _mlText = tv;
    _editRow = row;
    _editCol = kValueCol;
    _editInitial = [initial copy];
    [self.window makeFirstResponder:tv];
    [tv selectAll:nil];
}

// Ends the current edit. Returns the row the edit ended on (after any structural change), or -1.
// focusTable is NO only when AppKit is already moving focus elsewhere (the editor is resigning).
- (NSInteger)endEditing:(BOOL)commit focusTable:(BOOL)focusTable {
    if (!_editField && !_mlText) return -1;
    const NSInteger row = _editRow, col = _editCol;
    NSString* initial = _editInitial ?: @"";
    NSString* text = nil;

    if (_mlText) {
        NSTextView* tv = _mlText;
        NSScrollView* sv = _mlScroll;
        _mlText = nil;
        _mlScroll = nil;
        text = [tv.string copy];
        tv.delegate = nil;
        if (focusTable && self.window.firstResponder == tv) [self.window makeFirstResponder:_tableView];
        [_viewsToRemove addObject:sv];
    } else {
        NSTextField* tf = _editField;
        _editField = nil;
        NSText* fe = tf.currentEditor;
        text = fe ? [fe.string copy] : [tf.stringValue copy];
        if (focusTable && fe) [self.window makeFirstResponder:_tableView];
        [_fieldsToReset addObject:tf];
    }
    _editRow = -1;
    _editCol = -1;
    _editInitial = nil;

    NSInteger result = row;
    if (row < 0 || (size_t)row >= _table.size()) {
        result = -1;
    } else if (col == kValueCol) {
        if (commit && ![text isEqualToString:initial]) {
            if (_table.setText((size_t)row, WPEUtf8(text))) [self setStatus:@"" error:NO];
        }
        [_refreshRows addIndex:(NSUInteger)row];
    } else if (_table.isPendingName((size_t)row)) {
        size_t at = wpe::npos;
        const wpe::NameResult nr =
            commit ? _table.nameNewRow((size_t)row, WPEUtf8(text), &at) : wpe::NameResult::Invalid;
        if (!commit) _table.discardPendingRow((size_t)row);
        if (nr == wpe::NameResult::Ok) {
            [_refreshRows addIndex:(NSUInteger)row];
            result = (NSInteger)at;
        } else {
            if (nr == wpe::NameResult::Duplicate) {
                [self setStatus:[NSString stringWithFormat:@"%@ already exists.", WPEStr(_table.row(at).label)] error:NO];
                result = (NSInteger)at;
            } else {
                if (commit && trimmedLength(text)) {
                    NSBeep();
                    [self setStatus:@"Field names cannot contain “=”." error:YES];
                }
                result = -1;
            }
            _needsReload = YES;
            _reloadSelect = result >= 0 ? result : std::max<NSInteger>(0, std::min<NSInteger>(row, (NSInteger)_table.size() - 1));
        }
    } else {
        if (commit && ![text isEqualToString:initial]) {
            size_t existing = wpe::npos;
            switch (_table.rename((size_t)row, WPEUtf8(text), &existing)) {
            case wpe::NameResult::Ok: [self setStatus:@"" error:NO]; break;
            case wpe::NameResult::Duplicate:
                NSBeep();
                [self setStatus:[NSString stringWithFormat:@"A field named %@ already exists.",
                                                           WPEStr(_table.row(existing).field)]
                          error:YES];
                break;
            case wpe::NameResult::Invalid:
                NSBeep();
                [self setStatus:@"Field names cannot be empty or contain “=”." error:YES];
                break;
            default: break;
            }
        }
        [_refreshRows addIndex:(NSUInteger)row];
    }

    if (focusTable) [self flushUI];
    else [self scheduleFlush];
    [self schedulePendingReload];
    return result;
}

- (void)scheduleEditRow:(NSInteger)row column:(NSInteger)col {
    _pendingRow = row;
    _pendingCol = col;
    __weak WPEPropertiesWindowController* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf runPendingEdit:row column:col];
    });
}

- (void)runPendingEdit:(NSInteger)row column:(NSInteger)col {
    if (_pendingRow != row || _pendingCol != col) return;
    [self beginEditRow:row column:col key:nil];
}

// Commits the current edit and opens the Value editor `delta` rows away (wrapping when asked).
- (void)advanceBy:(NSInteger)delta wrap:(BOOL)wrap {
    const NSInteger row = _editRow, col = _editCol;
    const NSInteger count = (NSInteger)_table.size();
    if (!wrap && col == kValueCol && (row + delta < 0 || row + delta >= count)) return;
    const BOOL pendingName = col == kNameCol && row >= 0 && _table.isPendingName((size_t)row);
    const NSInteger at = [self endEditing:YES focusTable:YES];
    if (at < 0) return;
    if (col == kNameCol && (delta > 0 || pendingName)) {
        if (delta > 0) [self scheduleEditRow:at column:kValueCol];
        return;
    }
    const NSInteger n = (NSInteger)_table.size();
    if (n == 0) return;
    NSInteger next = at + delta;
    if (next < 0 || next >= n) {
        if (!wrap) return;
        next = ((next % n) + n) % n;
    }
    [self scheduleEditRow:next column:kValueCol];
}

- (void)switchToMultiline:(NSTextView*)fieldEditor {
    NSString* text = [fieldEditor.string copy];
    const NSRange sel = fieldEditor.selectedRange;
    const NSInteger row = _editRow;
    NSString* initial = [_editInitial copy];
    [self endEditing:NO focusTable:YES];
    __weak WPEPropertiesWindowController* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf openMultilineRow:row text:text initial:initial selection:sel];
    });
}

- (void)openMultilineRow:(NSInteger)row text:(NSString*)text initial:(NSString*)initial selection:(NSRange)sel {
    if (_writing || _loading || _closed || [self isEditing] || row < 0 || (size_t)row >= _table.size()) return;
    [self flushUI];
    [self beginMultilineRow:row text:text initial:initial];
    if (!_mlText) return;
    if (NSMaxRange(sel) <= text.length) _mlText.selectedRange = sel;
    [_mlText insertText:@"\n" replacementRange:_mlText.selectedRange];
}

- (BOOL)handleEditCommand:(SEL)sel textView:(NSTextView*)tv multiline:(BOOL)multiline {
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
        [self endEditing:NO focusTable:YES];
        return YES;
    }
    if (sel == @selector(insertNewlineIgnoringFieldEditor:) || sel == @selector(insertLineBreak:)) {
        if (multiline) {
            [tv insertText:@"\n" replacementRange:tv.selectedRange];
        } else if (_editCol == kValueCol) {
            [self switchToMultiline:tv];
        }
        return YES;
    }
    if (!multiline && (sel == @selector(moveUp:) || sel == @selector(moveDown:))) {
        [self advanceBy:sel == @selector(moveUp:) ? -1 : +1 wrap:NO];
        return YES;
    }
    return NO;
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)sel {
    if (control && control == _rgEditField) return [self rgEditCommand:sel];
    if (control != _editField) return NO;
    return [self handleEditCommand:sel textView:textView multiline:NO];
}

- (void)controlTextDidEndEditing:(NSNotification*)note {
    if (_rgEditField && note.object == _rgEditField) {
        // Focus left the editor (a click elsewhere): an invalid value reopens instead of vanishing.
        const NSInteger row = _rgEditRow;
        NSString* typed = [self rgTypedText];
        if (![self rgEndEdit:YES focus:NO]) [self rgRetryEdit:row text:typed];
    }
    if (_editField && note.object == _editField) [self endEditing:YES focusTable:NO];
}

- (void)controlTextDidChange:(NSNotification*)note {
    if (note.object && (note.object == _formatField || note.object == _formatPattern)) [self updateFormatPreview];
}

- (BOOL)textView:(NSTextView*)textView doCommandBySelector:(SEL)sel {
    if (textView != _mlText) return NO;
    return [self handleEditCommand:sel textView:textView multiline:YES];
}

- (void)textDidEndEditing:(NSNotification*)note {
    if (_mlText && note.object == _mlText) [self endEditing:YES focusTable:NO];
}

#pragma mark Table events

- (NSInteger)focusRow {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 && _table.size() > 0) row = 0;
    return row;
}

- (BOOL)wpeTableMouseDown:(NSEvent*)event {
    _pendingRow = -1;
    const NSPoint p = [_tableView convertPoint:event.locationInWindow fromView:nil];
    // The second click of a double-click goes to the view that took the first one (the table), even when
    // that click opened an editor under the mouse: hand it to the editor so word/line selection works.
    if (event.clickCount > 1) {
        NSView* editor = _mlText ? _mlScroll : _editField;
        NSResponder* target = _mlText ? (NSResponder*)_mlText : (NSResponder*)_editField.currentEditor;
        if (editor && target && NSPointInRect(p, [editor convertRect:editor.bounds toView:_tableView])) {
            [target mouseDown:event];
            return YES;
        }
    }
    if ([self isEditing]) [self endEditing:YES focusTable:YES];
    [self flushUI];
    if (_writing || _loading) return NO;
    const NSInteger row = [_tableView rowAtPoint:p];
    const NSInteger col = [_tableView columnAtPoint:p];
    const NSEventModifierFlags mods =
        event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl);
    if (mods || row < 0 || col < 0) return NO;
    if ([self isAddNewRow:row]) {
        [self addField:nil];
        return YES;
    }
    if (col == kValueCol) {
        [self beginEditRow:row column:kValueCol key:nil];
        return YES;
    }
    if (col == kNameCol && event.clickCount >= 2) {
        // Several tracks: the host's Edit Value sheet, one value per track. One track: rename the
        // field (a standard label edits its value instead).
        if (_table.trackCount() >= 2) [self openValueSheetForRow:row];
        else [self beginEditRow:row column:kNameCol key:nil];
        return YES;
    }
    return NO;
}

- (BOOL)wpeTableKeyDown:(NSEvent*)event {
    const NSEventModifierFlags mods = WPEMods(event);
    const BOOL cmdOrCtrl = (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
    if (cmdOrCtrl) return NO;
    // A key that arrives between committing one cell and opening the next goes to the next editor.
    if (_pendingRow >= 0) {
        [self beginEditRow:_pendingRow column:_pendingCol key:event];
        return YES;
    }
    if (_writing || _loading) return NO;
    const unsigned short code = event.keyCode;
    NSString* chars = event.characters;
    const unichar c = chars.length ? [chars characterAtIndex:0] : 0;

    if (code == kKeyReturn || code == kKeyEnter || c == NSF2FunctionKey) {
        [self beginEditRow:[self focusRow] column:kValueCol key:nil];
        return YES;
    }
    if (code == kKeyBackspace || code == kKeyForwardDelete || c == NSDeleteFunctionKey) {
        [self removeSelected:nil];
        return YES;
    }
    if (code == kKeyHelpInsert || c == NSInsertFunctionKey || c == NSHelpFunctionKey) {
        [self addField:nil];
        return YES;
    }
    if (code == kKeyEscape) {
        [self wpeCancel];
        return YES;
    }
    if (c == NSHomeFunctionKey || c == NSEndFunctionKey || c == NSPageUpFunctionKey || c == NSPageDownFunctionKey) {
        const NSInteger n = (NSInteger)_table.size();
        if (n == 0) return YES;
        const NSInteger cur = std::min([self focusRow], n - 1);
        const NSRange visible = [_tableView rowsInRect:_tableView.visibleRect];
        const NSInteger page = std::max<NSInteger>(1, (NSInteger)visible.length - 1);
        NSInteger target = 0;
        if (c == NSEndFunctionKey) target = n - 1;
        else if (c == NSPageUpFunctionKey) target = std::max<NSInteger>(0, cur - page);
        else if (c == NSPageDownFunctionKey) target = std::min<NSInteger>(n - 1, cur + page);
        NSIndexSet* rows = [NSIndexSet indexSetWithIndex:(NSUInteger)target];
        if (mods & NSEventModifierFlagShift) {
            const NSInteger lo = std::min(cur, target), hi = std::max(cur, target);
            rows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange((NSUInteger)lo, (NSUInteger)(hi - lo + 1))];
        }
        [_tableView selectRowIndexes:rows byExtendingSelection:NO];
        [_tableView scrollRowToVisible:target];
        return YES;
    }
    if (c == '\t' || c == 0x19) return NO;
    const BOOL printable = chars.length == 0 || (c >= 0x20 && c != 0x7F && !(c >= 0xF700 && c <= 0xF8FF));
    if (printable && [self focusRow] >= 0) {
        // On "add new" the typed text starts the new field's name.
        [self beginEditRow:[self focusRow] column:kValueCol key:event];
        return YES;
    }
    return NO;
}

- (NSMenu*)wpeTableMenuForEvent:(NSEvent*)event {
    const BOOL keep = [self prepareCommand];
    const NSPoint p = [_tableView convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [_tableView rowAtPoint:p];
    if ([self isAddNewRow:row]) row = -1;
    _menuRow = row;
    if (row >= 0 && ![_tableView isRowSelected:row])
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    else if (row < 0 && !keep)
        [_tableView deselectAll:nil];
    return _menu;
}

- (std::vector<size_t>)selectedRows {
    std::vector<size_t> rows;
    NSIndexSet* set = _tableView.selectedRowIndexes;
    for (NSUInteger i = set.firstIndex; i != NSNotFound; i = [set indexGreaterThanIndex:i])
        if (i < _table.size()) rows.push_back(i);
    return rows;
}

- (NSPasteboard*)pasteboard {
    return _pasteboard ?: [NSPasteboard generalPasteboard];
}

- (BOOL)wpeCanCopy {
    return ![self selectedRows].empty() && !_loading;
}

- (BOOL)wpeCanPaste {
    return !_writing && !_loading && [[self pasteboard] stringForType:NSPasteboardTypeString] != nil;
}

- (void)wpeCopy {
    [self copyFields:nil];
}

- (void)wpePaste {
    [self pasteFields:nil];
}

- (void)wpeDelete {
    [self removeSelected:nil];
}

- (void)wpeCancel {
    if ([self isEditing]) {
        [self endEditing:NO focusTable:YES];
        return;
    }
    [self cancelPressed:nil];
}

#pragma mark Commands

// Commits any edit before a command. Returns NO when that edit was a new field whose name did not
// become a field (empty, invalid or an existing name): the selection then points at a row the user
// never chose, so commands that act on the selection must stop.
- (BOOL)prepareCommand {
    _pendingRow = -1;
    BOOL keep = [self rgFinishEdit];
    if ([self isEditing]) {
        const BOOL pendingName = _editCol == kNameCol && _editRow >= 0 && _table.isPendingName((size_t)_editRow);
        const size_t before = _table.size();
        [self endEditing:YES focusTable:YES];
        if (pendingName && _table.size() < before) keep = NO;
    }
    [self flushUI];
    return keep;
}

- (void)afterStructuralChangeSelecting:(NSIndexSet*)rows {
    [_tableView reloadData];
    [self refreshRowDecorations:_tableView];
    if (rows.count) {
        [_tableView selectRowIndexes:rows byExtendingSelection:NO];
        [_tableView scrollRowToVisible:(NSInteger)rows.firstIndex];
    }
    if (_tab == kTabMetadata) [self.window makeFirstResponder:_tableView];
    [self updateButtons];
}

- (void)editSelected:(id)sender {
    (void)sender;
    [self prepareCommand];
    [self showMetadataPage];
    [self beginEditRow:[self focusRow] column:kValueCol key:nil];
}

- (void)addField:(id)sender {
    (void)sender;
    [self addFieldWithKey:nil];
}

- (void)addFieldWithKey:(NSEvent*)key {
    [self prepareCommand];
    if (_writing || _loading) return;
    [self showMetadataPage];
    const size_t r = _table.addRow();
    [_tableView insertRowsAtIndexes:[NSIndexSet indexSetWithIndex:r] withAnimation:NSTableViewAnimationEffectNone];
    [self refreshRowDecorations:_tableView];
    [self beginEditRow:(NSInteger)r column:kNameCol key:key];
}

- (void)removeSelected:(id)sender {
    (void)sender;
    if (![self prepareCommand] || _writing || _loading) return;
    const auto rows = [self selectedRows];
    if (rows.empty()) return;
    _table.remove(rows);
    const NSInteger keep = std::min<NSInteger>((NSInteger)rows.front(), (NSInteger)_table.size() - 1);
    [self afterStructuralChangeSelecting:keep >= 0 ? [NSIndexSet indexSetWithIndex:(NSUInteger)keep] : [NSIndexSet indexSet]];
}

- (void)copyFields:(id)sender {
    (void)sender;
    if (![self prepareCommand]) return;
    const std::string text = _table.copyText([self selectedRows]);
    if (text.empty()) return;
    NSPasteboard* pb = [self pasteboard];
    [pb clearContents];
    [pb setString:WPEStr(text) forType:NSPasteboardTypeString];
}

- (void)pasteText:(NSString*)s {
    if (![self prepareCommand] || _writing || _loading || !s.length) return;
    std::vector<size_t> touched;
    if (!_table.paste(WPEUtf8(s), [self selectedRows], &touched)) {
        if (touched.empty()) NSBeep();
        [self afterStructuralChangeSelecting:_tableView.selectedRowIndexes];
        return;
    }
    NSMutableIndexSet* sel = [NSMutableIndexSet indexSet];
    for (size_t i : touched) [sel addIndex:i];
    [self afterStructuralChangeSelecting:sel];
}

- (void)pasteFields:(id)sender {
    (void)sender;
    [self pasteText:[[self pasteboard] stringForType:NSPasteboardTypeString]];
}

- (void)capitalizeSelected:(id)sender {
    (void)sender;
    if (![self prepareCommand] || _writing || _loading) return;
    const auto rows = [self selectedRows];
    _table.capitalize(rows, WPECapitalize);
    for (size_t r : rows) [self refreshRow:(NSInteger)r];
    [self updateButtons];
}

- (void)autoTrackNumber:(id)sender {
    (void)sender;
    [self prepareCommand];
    if (_writing || _loading) return;
    [self showMetadataPage];
    NSIndexSet* sel = _tableView.selectedRowIndexes;
    _table.autoTrackNumber();
    [self afterStructuralChangeSelecting:sel];
}

// The row a context-menu command acts on: the row that was right-clicked, else the first selected one.
- (NSInteger)menuTargetRow {
    NSInteger row = _menuRow;
    if (row < 0 || (size_t)row >= _table.size()) {
        const auto rows = [self selectedRows];
        row = rows.empty() ? -1 : (NSInteger)rows.front();
    }
    if (row >= 0 && _table.isPendingName((size_t)row)) return -1;
    return row;
}

- (void)editValuesPerTrack:(id)sender {
    (void)sender;
    if (![self prepareCommand] || _writing || _loading) return;
    const NSInteger row = [self menuTargetRow];
    _menuRow = -1;
    [self openValueSheetForRow:row];
}

- (void)renameField:(id)sender {
    (void)sender;
    if (![self prepareCommand] || _writing || _loading) return;
    const NSInteger row = [self menuTargetRow];
    _menuRow = -1;
    if (row < 0 || _table.row((size_t)row).standard) {
        NSBeep();
        return;
    }
    [self showMetadataPage];
    [self beginEditRow:row column:kNameCol key:nil];
}

#pragma mark Edit Value

// The host's "Edit Value : <field>" sheet for one row: each track's own value, edited separately. OK
// stages the values here (per track); nothing is written before OK or Apply in this window.
- (void)openValueSheetForRow:(NSInteger)row {
    if (_valueSheet || _writing || _loading || _closed || _table.trackCount() < 2) return;
    if (row < 0 || (size_t)row >= _table.size() || _table.isPendingName((size_t)row)) return;
    if (self.window.attachedSheet) {  // another sheet (an error report) is still up
        NSBeep();
        return;
    }
    [self showMetadataPage];
    [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [_tableView scrollRowToVisible:row];

    wpe::PerTrackEdit edit(_table, (size_t)row);
    NSString* title = [@"Edit Value : " stringByAppendingString:WPEStr(edit.label())];
    const std::vector<std::string> titles = _backend->trackTitles();
    const std::vector<std::string> paths = _backend->trackPaths();
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    NSMutableArray<NSString*>* tips = [NSMutableArray array];
    for (size_t t = 0; t < _table.trackCount(); ++t) {
        [names addObject:t < titles.size() ? WPEStr(titles[t]) : @""];
        std::string path = t < paths.size() ? paths[t] : std::string();
        if (path.rfind("file://", 0) == 0) path = path.substr(7);
        [tips addObject:WPEStr(path)];
    }
    const NSSize parent = self.window.contentView.bounds.size;
    const NSSize size = NSMakeSize(std::clamp<CGFloat>(std::round(parent.width * 0.62), 480, 720),
                                   std::clamp<CGFloat>(std::round(parent.height * 0.62), 330, 520));
    __weak WPEPropertiesWindowController* weakSelf = self;
    _valueSheet = [[WPEEditValueSheet alloc] initWithEdit:std::move(edit)
                                                    title:title
                                                    names:names
                                                 toolTips:tips
                                                     size:size
                                                     done:[weakSelf](bool ok) { [weakSelf valueSheetEnded:ok]; }];
    [_valueSheet beginForWindow:(_show && self.window.visible) ? self.window : nil];
}

- (void)valueSheetEnded:(BOOL)ok {
    WPEEditValueSheet* sheet = _valueSheet;
    _valueSheet = nil;
    if (!sheet) return;
    // The sheet is still running the event that ended it: release it on the next pass.
    dispatch_async(dispatch_get_main_queue(), ^{
        (void)sheet;
    });
    if (_closed) return;
    if (ok) {
        size_t row = wpe::npos;
        if ([sheet edit].apply(_table, &row)) [self setStatus:@"" error:NO];
        if (row != wpe::npos) {
            [self refreshRow:(NSInteger)row];
            [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
            [_tableView scrollRowToVisible:(NSInteger)row];
        }
    }
    [self.window makeFirstResponder:_tableView];
    [self updateButtons];
    [self schedulePendingReload];
}

#pragma mark Tools

// Before the Tools menu opens: an open edit is committed, so its items act on what is on screen. A
// ReplayGain value that does not parse keeps the menu closed (its editor reopens with the text).
- (BOOL)prepareTools {
    if (_closed || ![self rgFinishEdit]) return NO;
    [self prepareCommand];
    return YES;
}

// Every field as FIELD=value lines (the same format as Copy).
- (void)copyAllFields:(id)sender {
    (void)sender;
    [self prepareCommand];
    if (_loading) return;
    const std::string text = _table.copyText(_table.valueRows());
    if (text.empty()) {
        NSBeep();
        return;
    }
    NSPasteboard* pb = [self pasteboard];
    [pb clearContents];
    [pb setString:WPEStr(text) forType:NSPasteboardTypeString];
}

// FIELD=value lines from the clipboard: each named field is set (added when new); others are kept.
- (void)pasteAllFields:(id)sender {
    (void)sender;
    if (![self rgFinishEdit]) return;
    [self prepareCommand];
    if (_writing || _loading) return;
    NSString* s = [[self pasteboard] stringForType:NSPasteboardTypeString];
    std::vector<size_t> touched;
    if (!s.length || !_table.paste(WPEUtf8(s), {}, &touched)) {
        if (touched.empty()) {
            NSBeep();
            [self setStatus:@"The clipboard holds no FIELD=value lines." error:NO];
        }
    }
    [self showMetadataPage];
    NSMutableIndexSet* sel = [NSMutableIndexSet indexSet];
    for (size_t i : touched) [sel addIndex:i];
    [self afterStructuralChangeSelecting:sel.count ? sel : _tableView.selectedRowIndexes];
}

- (void)removeAllFields:(id)sender {
    (void)sender;
    [self prepareCommand];
    if (_writing || _loading) return;
    _table.removeAll();
    [self showMetadataPage];
    [self afterStructuralChangeSelecting:_table.size() ? [NSIndexSet indexSetWithIndex:0] : [NSIndexSet indexSet]];
}

- (NSTextField*)formLabel:(NSString*)text {
    NSTextField* l = [NSTextField labelWithString:text];
    l.alignment = NSTextAlignmentRight;
    return l;
}

- (void)formatFromOtherFields:(id)sender {
    (void)sender;
    [self prepareCommand];
    if (_writing || _loading || _table.trackCount() == 0) return;
    if (!self.window.visible || self.window.attachedSheet) {
        NSBeep();
        return;
    }
    NSTextField* field = [NSTextField textFieldWithString:_lastFormatField ?: @"TITLE"];
    NSTextField* pattern = [NSTextField textFieldWithString:_lastFormatPattern ?: @""];
    pattern.placeholderString = @"%artist% - %title%";
    NSTextField* preview = [NSTextField wrappingLabelWithString:@""];
    preview.textColor = NSColor.secondaryLabelColor;
    preview.preferredMaxLayoutWidth = 300;
    for (NSTextField* f in @[ field, pattern ]) {
        f.delegate = self;
        [f.widthAnchor constraintEqualToConstant:300].active = YES;
    }
    NSGridView* grid = [NSGridView gridViewWithViews:@[
        @[ [self formLabel:@"Field:"], field ], @[ [self formLabel:@"Pattern:"], pattern ],
        @[ [self formLabel:@"Preview:"], preview ]
    ]];
    grid.rowSpacing = 8;
    grid.columnSpacing = 8;
    grid.frame = NSMakeRect(0, 0, 380, 90);

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Format from other fields";
    alert.informativeText = @"Sets the field on every track from a title formatting pattern, evaluated with that "
                            @"track's values in this window (including changes not written yet).";
    alert.accessoryView = grid;
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    _formatField = field;
    _formatPattern = pattern;
    _formatPreview = preview;
    [self updateFormatPreview];
    alert.window.initialFirstResponder = pattern;
    __weak WPEPropertiesWindowController* weakSelf = self;
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
                      [weakSelf formatSheetEnded:response field:field.stringValue pattern:pattern.stringValue];
                  }];
}

- (void)formatSheetEnded:(NSModalResponse)response field:(NSString*)field pattern:(NSString*)pattern {
    _formatField = _formatPattern = _formatPreview = nil;
    if (response == NSAlertFirstButtonReturn) [self formatField:field pattern:pattern];
}

- (std::vector<wpe::TrackFields>)stagedFields:(size_t)limit {
    std::vector<wpe::TrackFields> out;
    for (size_t t = 0; t < _table.trackCount() && t < limit; ++t) out.push_back(_table.currentFields(t));
    return out;
}

- (void)updateFormatPreview {
    if (!_formatPreview) return;
    std::vector<std::string> out;
    std::string error;
    if (!_formatPattern.stringValue.length) {
        _formatPreview.stringValue = @"";
    } else if (_backend->formatFields(WPEUtf8(_formatPattern.stringValue), [self stagedFields:1], out, error) && !out.empty()) {
        _formatPreview.stringValue = WPEStr(wpe::single_line(out.front()));
    } else {
        _formatPreview.stringValue = WPEStr(error);
    }
}

- (BOOL)formatField:(NSString*)field pattern:(NSString*)pattern {
    [self prepareCommand];
    if (_writing || _loading || _table.trackCount() == 0) return NO;
    const std::string name = wpe::upper_ascii(wpe::trim(WPEUtf8(field)));
    if (!wpe::valid_field_name(name)) {
        NSBeep();
        [self setStatus:@"Field names cannot be empty or contain “=”." error:YES];
        return NO;
    }
    std::vector<std::string> out;
    std::string error;
    if (!_backend->formatFields(WPEUtf8(pattern), [self stagedFields:_table.trackCount()], out, error) ||
        out.size() != _table.trackCount()) {
        NSBeep();
        [self setStatus:WPEStr(error.empty() ? std::string("The pattern could not be evaluated.") : error) error:YES];
        return NO;
    }
    _lastFormatField = [field copy];
    _lastFormatPattern = [pattern copy];
    size_t row = wpe::npos;
    const bool changed = _table.setFormatted(name, out, &row);
    [self showMetadataPage];
    [self afterStructuralChangeSelecting:row != wpe::npos ? [NSIndexSet indexSetWithIndex:row] : [NSIndexSet indexSet]];
    if (changed) [self setStatus:@"" error:NO];
    return changed;
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
    const SEL a = item.action;
    const BOOL busy = _writing || _loading;
    const BOOL hasSel = ![self selectedRows].empty();
    const BOOL metadata = _tab == kTabMetadata || item.menu == _menu;
    if (a == @selector(editSelected:)) return !busy && metadata && _table.size() > 0;
    if (a == @selector(editValuesPerTrack:)) return !busy && _table.trackCount() >= 2 && [self menuTargetRow] >= 0;
    if (a == @selector(renameField:)) {
        const NSInteger row = [self menuTargetRow];
        return !busy && row >= 0 && !_table.row((size_t)row).standard;
    }
    if (a == @selector(addField:)) return !busy;
    if (a == @selector(removeSelected:) || a == @selector(capitalizeSelected:)) return !busy && metadata && hasSel;
    if (a == @selector(copyFields:)) return metadata && [self wpeCanCopy];
    if (a == @selector(pasteFields:)) return metadata && [self wpeCanPaste];
    if (a == @selector(autoTrackNumber:) || a == @selector(formatFromOtherFields:)) return !busy && _table.trackCount() > 0;
    if (a == @selector(copyAllFields:)) return !_loading && !_table.valueRows().empty();
    if (a == @selector(pasteAllFields:)) return [self wpeCanPaste];
    if (a == @selector(removeAllFields:)) return !busy && !_table.fieldRows().empty();
    if (a == @selector(artImport:) || a == @selector(artExport:) || a == @selector(artCopy:) || a == @selector(artPaste:) ||
        a == @selector(artRemove:))
        return [self artMenuRow] >= 0 && [self wpeArtValidate:a];
    if (a == @selector(detailsCopy:)) return [self wpePage:_detailsTable validate:@selector(copy:)];
    if (a == @selector(detailsSelectAll:)) return !_details.empty();
    if (a == @selector(rgCopy:)) return [self wpePage:_rgTable validate:@selector(copy:)];
    if (a == @selector(rgClearSelected:)) return [self wpePage:_rgTable validate:@selector(delete:)];
    if (a == @selector(rgEditSelected:)) return [self canEditReplayGain] && _rgTable.selectedRow >= 0;
    return YES;
}

#pragma mark Details

- (void)ensureDetailsLoaded {
    if (_detailsRequested || _closed) return;
    _detailsRequested = YES;
    [self startDetailsLoad];
}

- (void)startDetailsLoad {
    const uint64_t generation = ++_detailsGeneration;
    _detailsLoading = YES;
    _detailsReloadPending = NO;
    _detailsStale = NO;
    __weak WPEPropertiesWindowController* weakSelf = self;
    _backend->loadDetails([weakSelf, generation](std::vector<details::Entry> entries) {
        [weakSelf finishDetailsLoad:entries generation:generation];
    });
    if (_detailsLoading && generation == _detailsGeneration) [self updateStatus];
}

- (void)finishDetailsLoad:(const std::vector<details::Entry>&)entries generation:(uint64_t)generation {
    if (generation != _detailsGeneration || _closed) return;
    _detailsLoading = NO;
    // Keep the selected lines (by section and name) and the scroll position across a refresh.
    std::vector<std::pair<std::string, std::string>> selected;
    for (size_t i : [self selectedDetailRows]) selected.emplace_back(_details[i].group, _details[i].name);
    const NSPoint scroll = _detailsScroll.contentView.bounds.origin;
    _details = details::group_lines(entries);
    [_detailsTable reloadData];
    [self refreshRowDecorations:_detailsTable];
    NSMutableIndexSet* sel = [NSMutableIndexSet indexSet];
    for (size_t i = 0; i < _details.size(); ++i)
        for (auto& s : selected)
            if (!_details[i].header && _details[i].group == s.first && _details[i].name == s.second) [sel addIndex:i];
    [_detailsTable selectRowIndexes:sel byExtendingSelection:NO];
    [_detailsScroll.contentView scrollToPoint:scroll];
    [_detailsScroll reflectScrolledClipView:_detailsScroll.contentView];
    [self updateStatus];
    if (_detailsReloadPending) [self detailsChangedOutside];
}

// The tracks changed (tags, or only display info such as playback statistics): the Details page is
// read again, at once when it is showing, otherwise when it is next shown. Bursts are coalesced.
- (void)detailsChangedOutside {
    if (!_detailsRequested || _closed) return;
    if (_detailsLoading) {
        _detailsReloadPending = YES;
        return;
    }
    if (_tab != kTabDetails) {
        _detailsStale = YES;
        return;
    }
    if (_detailsReloadScheduled) return;
    _detailsReloadScheduled = YES;
    __weak WPEPropertiesWindowController* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf runDetailsReload];
    });
}

- (void)runDetailsReload {
    _detailsReloadScheduled = NO;
    if (_closed) return;
    if (_detailsLoading) {
        _detailsReloadPending = YES;
        return;
    }
    [self startDetailsLoad];
}

- (NSView*)detailsViewForColumn:(NSTableColumn*)column row:(NSInteger)row {
    if (row < 0 || (size_t)row >= _details.size()) return nil;
    const details::Line& line = _details[(size_t)row];
    if (line.header) {
        NSTableCellView* cell = [_detailsTable makeViewWithIdentifier:kWPEDetailsHeader owner:self];
        if (!cell) {
            cell = [self makeCell:kWPEDetailsHeader];
            cell.textField.font = WPEGroupFont();
        }
        // Mac group-row style: 11 pt semibold in the secondary label colour, on an opaque band that
        // stays at the top (floating) while the section's lines scroll under it.
        WPESetListText(cell.textField, WPEStr(line.name), NSColor.secondaryLabelColor);
        cell.textField.toolTip = nil;
        return cell;
    }
    if (!column) return nil;
    const BOOL name = [column.identifier isEqualToString:kWPENameColumn];
    NSTableCellView* cell = [_detailsTable makeViewWithIdentifier:column.identifier owner:self];
    if (!cell) cell = [self makeCell:column.identifier];
    NSString* text = WPEStr(wpe::single_line(name ? line.name : line.value));
    WPESetListText(cell.textField, text, NSColor.labelColor);
    cell.textField.toolTip = name ? nil : WPEStr(line.value);
    return cell;
}

- (std::vector<size_t>)selectedDetailRows {
    std::vector<size_t> rows;
    NSIndexSet* set = _detailsTable.selectedRowIndexes;
    for (NSUInteger i = set.firstIndex; i != NSNotFound; i = [set indexGreaterThanIndex:i])
        if (i < _details.size() && !_details[i].header) rows.push_back(i);
    return rows;
}

- (void)copyString:(const std::string&)text {
    if (text.empty()) {
        NSBeep();
        return;
    }
    NSPasteboard* pb = [self pasteboard];
    [pb clearContents];
    [pb setString:WPEStr(text) forType:NSPasteboardTypeString];
}

- (void)detailsCopy:(id)sender {
    (void)sender;
    [self copyString:details::copy_text(_details, [self selectedDetailRows])];
}

- (void)detailsSelectAll:(id)sender {
    (void)sender;
    [_detailsTable selectAll:nil];
}

#pragma mark ReplayGain

- (BOOL)canEditReplayGain {
    return !_writing && !_loading && !_closed && _rg.trackCount() > 0;
}

- (void)configureReplayGainCell:(NSTableCellView*)cell column:(NSInteger)col row:(NSInteger)row {
    NSTextField* tf = cell.textField;
    if (!tf || tf == _rgEditField || row < 0 || row >= (NSInteger)rg::FieldCount) return;
    if (col == kNameCol) {
        WPESetListText(tf, WPEStr(rg::field_label((size_t)row)), NSColor.labelColor);
        return;
    }
    const rg::Display d = _rg.display((size_t)row);
    WPESetListText(tf, WPEStr(d.text), d.mixed ? NSColor.secondaryLabelColor : NSColor.labelColor);
}

- (void)refreshReplayGainRows {
    for (NSInteger row = 0; row < std::min<NSInteger>(_rgTable.numberOfRows, (NSInteger)rg::FieldCount); ++row)
        for (NSInteger col = 0; col < 2; ++col) {
            NSTableCellView* cell = [_rgTable viewAtColumn:col row:row makeIfNecessary:NO];
            if (cell) [self configureReplayGainCell:cell column:col row:row];
        }
    [self updateButtons];
}

- (std::vector<size_t>)selectedReplayGainRows {
    std::vector<size_t> rows;
    NSIndexSet* set = _rgTable.selectedRowIndexes;
    for (NSUInteger i = set.firstIndex; i != NSNotFound; i = [set indexGreaterThanIndex:i])
        if (i < rg::FieldCount) rows.push_back(i);
    return rows;
}

// Opens the Value editor of a ReplayGain row with its text selected (or with `text`, after a value
// that did not parse). A non-nil key event is replayed into it, so typing replaces the value.
- (void)rgBeginEdit:(NSInteger)row key:(NSEvent*)key text:(NSString*)text {
    if (_rgEditField && ![self rgFinishEdit]) return;
    _rgPendingRow = -1;
    _rgRetryText = nil;
    if (![self canEditReplayGain] || row < 0 || row >= (NSInteger)rg::FieldCount) return;
    [self flushUI];
    [_rgTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [_rgTable scrollRowToVisible:row];
    NSTableCellView* cell = [_rgTable viewAtColumn:kValueCol row:row makeIfNecessary:YES];
    NSTextField* tf = cell.textField;
    if (!tf) return;
    NSString* initial = WPEStr(_rg.editText((size_t)row));
    _rgEditField = tf;
    _rgEditRow = row;
    _rgEditInitial = initial;
    tf.stringValue = text ?: initial;
    WPEBeginInlineEdit(tf);
    if (![self.window makeFirstResponder:tf]) {
        _rgEditField = nil;
        _rgEditRow = -1;
        _rgEditInitial = nil;
        [self resetEditorField:tf];
        [self configureReplayGainCell:cell column:kValueCol row:row];
        return;
    }
    NSTextView* fe = (NSTextView*)tf.currentEditor;
    [self disableSubstitutions:fe];
    [fe selectAll:nil];
    if (key) {
        NSResponder* fr = self.window.firstResponder;
        if (fr && fr != _rgTable) [fr keyDown:key];
    }
}

// Ends the ReplayGain edit. Returns NO when the committed text is not a valid value: nothing is then
// staged and the status line says why.
- (BOOL)rgEndEdit:(BOOL)commit focus:(BOOL)focus {
    if (!_rgEditField) return YES;
    NSTextField* tf = _rgEditField;
    const NSInteger row = _rgEditRow;
    NSString* initial = _rgEditInitial ?: @"";
    _rgEditField = nil;
    _rgEditRow = -1;
    _rgEditInitial = nil;
    NSText* fe = tf.currentEditor;
    NSString* text = fe ? [fe.string copy] : [tf.stringValue copy];
    if (focus && fe) [self.window makeFirstResponder:_rgTable];
    [_fieldsToReset addObject:tf];
    BOOL ok = YES;
    if (commit && ![text isEqualToString:initial] && row >= 0) {
        switch (_rg.setText((size_t)row, WPEUtf8(text))) {
        case rg::Edit::Changed: [self setStatus:@"" error:NO]; break;
        case rg::Edit::Invalid:
            NSBeep();
            [self setStatus:WPEStr(rg::invalid_message((size_t)row, wpe::trim(WPEUtf8(text)))) error:YES];
            ok = NO;
            break;
        case rg::Edit::Unchanged: break;
        }
    }
    _rgNeedsRefresh = YES;
    if (focus) [self flushUI];
    else [self scheduleFlush];
    [self schedulePendingReload];
    return ok;
}

// Commits an open ReplayGain edit before anything else happens (tab switch, click, Tools, OK...).
// Returns NO when the typed value does not parse: the editor then reopens with that text, and the
// caller must stop. Also NO while such a reopen is still on its way.
- (BOOL)rgFinishEdit {
    if (_rgRetryText && _rgPendingRow >= 0) return NO;
    _rgPendingRow = -1;
    _rgRetryText = nil;
    if (!_rgEditField) return YES;
    const NSInteger row = _rgEditRow;
    NSString* typed = [self rgTypedText];
    if ([self rgEndEdit:YES focus:YES]) return YES;
    [self rgRetryEdit:row text:typed];
    return NO;
}

- (NSString*)rgTypedText {
    if (!_rgEditField) return nil;
    return _rgEditField.currentEditor ? [_rgEditField.currentEditor.string copy] : [_rgEditField.stringValue copy];
}

- (void)rgRetryEdit:(NSInteger)row text:(NSString*)text {
    if (_closed || row < 0) return;
    _rgRetryText = [text copy] ?: @"";
    [self rgScheduleEdit:row text:_rgRetryText];
}

- (void)rgScheduleEdit:(NSInteger)row text:(NSString*)text {
    _rgPendingRow = row;
    __weak WPEPropertiesWindowController* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf rgRunPendingEdit:row text:text];
    });
}

- (void)rgRunPendingEdit:(NSInteger)row text:(NSString*)text {
    if (_rgPendingRow != row) return;
    _rgRetryText = nil;
    [self rgBeginEdit:row key:nil text:text];
}

// Return/Tab (wrapping) and the arrows (not wrapping) commit and move on, as on the Metadata page.
// A value that does not parse keeps its editor open, with the typed text, so it can be corrected.
- (void)rgAdvanceBy:(NSInteger)delta wrap:(BOOL)wrap {
    const NSInteger row = _rgEditRow;
    const NSInteger n = (NSInteger)rg::FieldCount;
    if (!wrap && (row + delta < 0 || row + delta >= n)) return;
    NSString* typed = [self rgTypedText];
    if (![self rgEndEdit:YES focus:YES]) {
        [self rgRetryEdit:row text:typed];
        return;
    }
    [self rgScheduleEdit:((row + delta) % n + n) % n text:nil];
}

- (BOOL)rgEditCommand:(SEL)sel {
    NSEvent* ev = ((WPEWindow*)self.window).currentKeyEvent ?: NSApp.currentEvent;
    const BOOL shift = ev.type == NSEventTypeKeyDown && (ev.modifierFlags & NSEventModifierFlagShift) != 0;
    if (sel == @selector(insertTab:)) [self rgAdvanceBy:+1 wrap:YES];
    else if (sel == @selector(insertBacktab:)) [self rgAdvanceBy:-1 wrap:YES];
    else if (sel == @selector(insertNewline:)) [self rgAdvanceBy:shift ? -1 : +1 wrap:YES];
    else if (sel == @selector(moveUp:) || sel == @selector(moveDown:)) [self rgAdvanceBy:sel == @selector(moveUp:) ? -1 : +1 wrap:NO];
    else if (sel == @selector(cancelOperation:) || sel == @selector(complete:)) [self rgEndEdit:NO focus:YES];
    else if (sel == @selector(insertNewlineIgnoringFieldEditor:) || sel == @selector(insertLineBreak:)) {
        // single-line values only
    } else {
        return NO;
    }
    return YES;
}

- (void)rgEditSelected:(id)sender {
    (void)sender;
    const NSInteger row = _rgTable.clickedRow >= 0 ? _rgTable.clickedRow : _rgTable.selectedRow;
    [self rgBeginEdit:row >= 0 ? row : 0 key:nil text:nil];
}

- (void)rgClearSelected:(id)sender {
    (void)sender;
    if (![self rgFinishEdit] || ![self canEditReplayGain]) return;
    bool changed = false;
    for (size_t r : [self selectedReplayGainRows]) changed = _rg.clear(r) || changed;
    if (changed) [self setStatus:@"" error:NO];
    [self refreshReplayGainRows];
}

- (void)rgCopy:(id)sender {
    (void)sender;
    if (![self rgFinishEdit]) return;
    [self copyString:_rg.copyText([self selectedReplayGainRows])];
}

#pragma mark Details and ReplayGain: list events

- (NSView*)wpePageEditingView:(NSTableView*)table {
    return table == _rgTable ? _rgEditField : nil;
}

- (BOOL)wpePage:(NSTableView*)table mouseDown:(NSEvent*)event {
    if (table != _rgTable) return NO;
    const NSPoint p = [_rgTable convertPoint:event.locationInWindow fromView:nil];
    // The second click of a double-click on the cell that the first click opened goes to its editor.
    if (event.clickCount > 1 && _rgEditField && _rgEditField.currentEditor &&
        NSPointInRect(p, [_rgEditField convertRect:_rgEditField.bounds toView:_rgTable])) {
        [_rgEditField.currentEditor mouseDown:event];
        return YES;
    }
    if (![self rgFinishEdit]) return YES;  // the invalid value's editor reopens; the click is dropped
    const NSInteger row = [_rgTable rowAtPoint:p];
    const NSInteger col = [_rgTable columnAtPoint:p];
    const NSEventModifierFlags mods =
        event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl);
    if (mods || row < 0 || col != kValueCol || ![self canEditReplayGain]) return NO;
    [self rgBeginEdit:row key:nil text:nil];
    return YES;
}

- (BOOL)wpePage:(NSTableView*)table keyDown:(NSEvent*)event {
    const NSEventModifierFlags mods = WPEMods(event);
    if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) return NO;
    NSString* chars = event.characters;
    const unichar c = chars.length ? [chars characterAtIndex:0] : 0;
    if (event.keyCode == kKeyEscape) {
        [self wpeCancel];
        return YES;
    }
    if (table != _rgTable) return NO;
    if (_rgPendingRow >= 0) {
        // A key typed before the next editor opens goes to it (after an invalid value, onto its text).
        NSString* text = _rgRetryText;
        const NSInteger row = _rgPendingRow;
        _rgRetryText = nil;
        _rgPendingRow = -1;
        [self rgBeginEdit:row key:event text:text];
        return YES;
    }
    if (![self canEditReplayGain]) return NO;
    const NSInteger row = _rgTable.selectedRow >= 0 ? _rgTable.selectedRow : 0;
    if (event.keyCode == kKeyReturn || event.keyCode == kKeyEnter || c == NSF2FunctionKey) {
        [self rgBeginEdit:row key:nil text:nil];
        return YES;
    }
    if (event.keyCode == kKeyBackspace || event.keyCode == kKeyForwardDelete || c == NSDeleteFunctionKey) {
        [self rgClearSelected:nil];
        return YES;
    }
    if (c == '\t' || c == 0x19) return NO;
    const BOOL printable = chars.length == 0 || (c >= 0x20 && c != 0x7F && !(c >= 0xF700 && c <= 0xF8FF));
    if (printable && !(mods & NSEventModifierFlagOption)) {
        [self rgBeginEdit:row key:event text:nil];
        return YES;
    }
    return NO;
}

- (NSMenu*)wpePage:(NSTableView*)table menuForEvent:(NSEvent*)event {
    if (table == _rgTable && ![self rgFinishEdit]) return nil;
    const NSPoint p = [table convertPoint:event.locationInWindow fromView:nil];
    const NSInteger row = [table rowAtPoint:p];
    if (row >= 0 && ![table isRowSelected:row]) {
        NSIndexSet* proposed = [NSIndexSet indexSetWithIndex:(NSUInteger)row];
        if (table == _detailsTable) proposed = [self tableView:table selectionIndexesForProposedSelection:proposed];
        if (proposed.count) [table selectRowIndexes:proposed byExtendingSelection:NO];
    }
    return table == _rgTable ? _rgMenu : _detailsMenu;
}

- (void)wpePageCopy:(NSTableView*)table {
    if (table == _rgTable) [self rgCopy:nil];
    else [self detailsCopy:nil];
}

- (void)wpePageDelete:(NSTableView*)table {
    if (table == _rgTable) [self rgClearSelected:nil];
}

- (BOOL)wpePage:(NSTableView*)table validate:(SEL)a {
    if (table == _detailsTable) return a == @selector(copy:) && ![self selectedDetailRows].empty();
    const auto rows = [self selectedReplayGainRows];
    if (a == @selector(copy:)) return !rows.empty() && _rg.trackCount() > 0;
    if (a == @selector(delete:)) {
        if (![self canEditReplayGain]) return NO;
        for (size_t r : rows)
            for (size_t t = 0; t < _rg.trackCount(); ++t)
                if (_rg.current(r, t)) return YES;
        return NO;
    }
    return NO;
}

#pragma mark Artwork: loading

- (void)ensureArtLoaded {
    if (_artRequested || _closed) return;
    _artRequested = YES;
    [self startArtLoad];
}

- (void)startArtLoad {
    const uint64_t generation = ++_artGeneration;
    _artLoading = YES;
    _artReloadPending = NO;
    [self updateButtons];
    __weak WPEPropertiesWindowController* weakSelf = self;
    _backend->loadArt([weakSelf, generation](wpe::ArtLoad load) { [weakSelf finishArtLoad:load generation:generation]; });
}

- (void)finishArtLoad:(wpe::ArtLoad&)load generation:(uint64_t)generation {
    if (generation != _artGeneration || _closed) return;
    _artLoading = NO;
    // Never replace staged pictures (or the rows a write is working from): read again once the
    // write has finished, or once the page is clean.
    if (_writing || _art.dirty()) {
        _artReloadPending = YES;
        [self artChanged];
        return;
    }
    load.tracks.resize(_backend->trackCount());
    _art.load(load.tracks);
    _artError = nil;
    if (!load.errors.empty()) {
        std::string path = load.errors.front().first;
        if (path.rfind("file://", 0) == 0) path = path.substr(7);
        _artError = [NSString stringWithFormat:@"Could not read pictures from %@: %@", WPEStr(path), WPEStr(load.errors.front().second)];
    }
    [self artChanged];
    if (_artReloadPending && !_art.dirty() && !_writing) [self startArtLoad];
}

- (void)artChangedOutside {
    if (!_artRequested) return;
    if (_writing || _artLoading) {
        _artReloadPending = YES;
        return;
    }
    if (_art.dirty()) return;  // the user's staged pictures win; Apply rewrites them
    [self startArtLoad];
}

// Redisplays the Artwork rows after a load or a staged change.
- (void)artChanged {
    for (size_t type = 0; type < art::TypeCount; ++type) [self requestThumbnail:type];
    for (size_t type = 0; type < art::TypeCount; ++type) [self refreshArtRow:(NSInteger)type];
    [self updateButtons];
    [self reloadQuickLook];
}

- (void)refreshArtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)art::TypeCount) return;
    for (NSInteger col = 0; col < _artTable.numberOfColumns; ++col) {
        NSView* v = [_artTable viewAtColumn:col row:row makeIfNecessary:NO];
        if ([v isKindOfClass:[NSTableCellView class]]) [self configureArtCell:(NSTableCellView*)v column:col row:row];
    }
}

// Thumbnails are decoded with ImageIO off the main thread, at the cell's pixel size.
- (void)requestThumbnail:(size_t)type {
    const art::Picture pic = _art.slot(type).picture();
    WPEThumb& th = _thumbs[type];
    if (!pic) {
        th = WPEThumb();
        return;
    }
    if (th.key == pic) return;
    th = WPEThumb();
    th.key = pic;
    const CGFloat scale = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 2;
    const CGFloat maxPixels = std::ceil(kArtRowHeight * std::max<CGFloat>(scale, 2));
    __weak WPEPropertiesWindowController* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSImage* image = nil;
        art::Dimensions dims;
        CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, pic->data(), (CFIndex)pic->size(), kCFAllocatorNull);
        CGImageSourceRef src = data ? CGImageSourceCreateWithData(data, nullptr) : nullptr;
        if (src) {
            NSDictionary* props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, nullptr));
            dims.width = [props[(__bridge NSString*)kCGImagePropertyPixelWidth] unsignedIntValue];
            dims.height = [props[(__bridge NSString*)kCGImagePropertyPixelHeight] unsignedIntValue];
            NSDictionary* options = @{
                (__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
                (__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform : @YES,
                (__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize : @(maxPixels),
            };
            CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)options);
            if (cg) {
                image = [[NSImage alloc] initWithCGImage:cg size:NSZeroSize];
                CGImageRelease(cg);
            }
            CFRelease(src);
        }
        if (data) CFRelease(data);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf thumbnailReady:image dimensions:dims type:type picture:pic];
        });
    });
}

- (void)thumbnailReady:(NSImage*)image dimensions:(art::Dimensions)dims type:(size_t)type picture:(art::Picture)pic {
    if (_closed || type >= art::TypeCount || _thumbs[type].key != pic) return;
    _thumbs[type].image = image;
    _thumbs[type].dims = dims;
    [self refreshArtRow:(NSInteger)type];
}

#pragma mark Artwork: cells

- (WPEArtCell*)makeArtCell:(NSString*)identifier {
    WPEArtCell* cell = [[WPEArtCell alloc] initWithFrame:NSMakeRect(0, 0, kArtRowHeight, kArtRowHeight)];
    cell.identifier = identifier;
    if ([identifier isEqualToString:kWPEArtPictureColumn]) {
        // The thumbnail is inset and rounded with a hairline edge (WPEThumbView draws it).
        WPEThumbView* iv = [[WPEThumbView alloc] initWithFrame:cell.bounds];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.imageScaling = NSImageScaleProportionallyUpOrDown;
        iv.imageAlignment = NSImageAlignCenter;
        iv.editable = NO;
        iv.animates = NO;
        cell.imageView = iv;
        NSButton* plus = [WPEGlyphButton symbol:@"plus.circle" label:@"Add picture" target:self action:@selector(artPlusPressed:)];
        plus.toolTip = @"Import from file…";
        cell.button = plus;
        for (NSView* v in @[ iv, plus ]) {
            [cell addSubview:v];
            [NSLayoutConstraint activateConstraints:@[
                [v.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
                [v.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
                [v.topAnchor constraintEqualToAnchor:cell.topAnchor],
                [v.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor],
            ]];
        }
        return cell;
    }
    if ([identifier isEqualToString:kWPEArtRemoveColumn]) {
        // Always shown where there is a picture (not only on hover), so removing is discoverable.
        NSButton* x = [WPEGlyphButton symbol:@"xmark.circle.fill" label:@"Remove picture" target:self action:@selector(artRemovePressed:)];
        x.toolTip = @"Remove";
        cell.button = x;
        [cell addSubview:x];
        [NSLayoutConstraint activateConstraints:@[
            [x.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
            [x.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
            [x.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [x.heightAnchor constraintEqualToConstant:kRowHeight],
        ]];
        return cell;
    }
    if (![identifier isEqualToString:kWPEArtDetailsColumn]) {
        // Name: a list text field filling the cell, optically centred like every list row's text.
        NSTextField* tf = WPEListTextField(_font, nil);
        [cell addSubview:tf];
        cell.textField = tf;
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
            [tf.topAnchor constraintEqualToAnchor:cell.topAnchor],
            [tf.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor],
        ]];
        return cell;
    }
    // Details: up to three lines, centred as a block (configureArtCell lifts the glyphs so the block's
    // capitals are centred).
    NSTextField* tf = [NSTextField wrappingLabelWithString:@""];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.font = _font;
    tf.lineBreakMode = NSLineBreakByTruncatingTail;
    tf.selectable = NO;
    tf.maximumNumberOfLines = 3;
    [tf setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [cell addSubview:tf];
    cell.textField = tf;
    [NSLayoutConstraint activateConstraints:@[
        [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:kCellInset],
        [tf.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-kCellInset],
        [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
    return cell;
}

- (NSView*)artViewForColumn:(NSTableColumn*)column row:(NSInteger)row {
    NSString* ident = column.identifier;
    WPEArtCell* cell = [_artTable makeViewWithIdentifier:ident owner:self];
    if (!cell) cell = [self makeArtCell:ident];
    const NSInteger col = [_artTable.tableColumns indexOfObject:column];
    [self configureArtCell:cell column:col row:row];
    return cell;
}

- (void)configureArtCell:(NSTableCellView*)view column:(NSInteger)col row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)art::TypeCount || ![view isKindOfClass:[WPEArtCell class]]) return;
    WPEArtCell* cell = (WPEArtCell*)view;
    const size_t type = (size_t)row;
    const art::Slot& slot = _art.slot(type);
    const art::State state = _art.loaded() ? slot.state() : art::State::Absent;
    switch (col) {
    case kArtNameCol:
        WPESetListText(cell.textField, WPEStr(art::type_label(type)), NSColor.labelColor);
        break;
    case kArtPictureCol: {
        NSImage* image = state == art::State::Present ? _thumbs[type].image : nil;
        cell.imageView.image = image;
        cell.imageView.hidden = image == nil;
        // VoiceOver: "Front Cover, 600×600 PNG, 302 KB".
        cell.imageView.accessibilityLabel = _art.loaded() ? WPEStr(_art.description(type, _thumbs[type].dims)) : nil;
        cell.imageView.accessibilityHelp = @"Space shows it in Quick Look; double-click imports a picture from a file";
        cell.button.hidden = !_art.loaded() || state != art::State::Absent;
        cell.button.enabled = [self canEditArt];
        break;
    }
    case kArtDetailsCol: {
        if (!_art.loaded()) {
            cell.textField.stringValue = @"";
            break;
        }
        const art::Details d = _art.details(type, _thumbs[type].dims);
        NSMutableArray* lines = [NSMutableArray array];
        for (auto& l : d.lines) [lines addObject:WPEStr(l)];
        NSFont* font = _font;
        if (d.pending) font = [[NSFontManager sharedFontManager] convertFont:_font toHaveTrait:NSItalicFontMask];
        NSMutableParagraphStyle* para = [[NSMutableParagraphStyle alloc] init];
        para.lineBreakMode = NSLineBreakByTruncatingTail;
        para.minimumLineHeight = para.maximumLineHeight = kArtDetailsLineHeight;
        // The fixed line pitch puts its extra leading above the glyphs; the lift centres the block's capitals
        // on the cell's centre line, one line or three.
        NSDictionary* attrs = @{
            NSFontAttributeName : font,
            NSForegroundColorAttributeName : d.mixed ? NSColor.secondaryLabelColor : NSColor.labelColor,
            NSParagraphStyleAttributeName : para,
            NSBaselineOffsetAttributeName : @(WPEFixedLineCapLift(font, kArtDetailsLineHeight, WPEDeviceScale(_artTable, NO))),
        };
        cell.textField.attributedStringValue = [[NSAttributedString alloc] initWithString:[lines componentsJoinedByString:@"\n"]
                                                                               attributes:attrs];
        cell.textField.toolTip = d.pending ? @"Pending: written when you press OK or Apply" : nil;
        break;
    }
    case kArtRemoveCol:
        cell.button.hidden = !_art.loaded() || state == art::State::Absent;
        cell.button.enabled = [self canEditArt];
        break;
    default: break;
    }
}

#pragma mark Artwork: commands

- (NSInteger)artRowForView:(NSView*)view {
    const NSInteger row = [_artTable rowForView:view];
    return row >= 0 && row < (NSInteger)art::TypeCount ? row : -1;
}

// The row a context-menu command acts on: the clicked row, else the first selected one.
- (NSInteger)artMenuRow {
    NSInteger row = _artTable.clickedRow;
    if (row < 0) row = _artTable.selectedRow;
    return row >= 0 && row < (NSInteger)art::TypeCount ? row : -1;
}

- (std::vector<size_t>)selectedArtRows {
    std::vector<size_t> rows;
    NSIndexSet* set = _artTable.selectedRowIndexes;
    for (NSUInteger i = set.firstIndex; i != NSNotFound; i = [set indexGreaterThanIndex:i])
        if (i < art::TypeCount) rows.push_back(i);
    return rows;
}

// Pictures can be staged only on a settled page: not while writing, and not while the pictures are
// being (re)read, because the reload replaces the rows and would silently drop the new edit.
- (BOOL)canEditArt {
    return _art.loaded() && !_artLoading && !_writing && !_closed;
}

// A staging attempt the page cannot take right now.
- (BOOL)refuseArtEdit {
    if ([self canEditArt]) return NO;
    NSBeep();
    if (_artLoading && !_writing) [self setStatus:@"Pictures are being reloaded; try again in a moment." error:NO];
    return YES;
}

- (void)stageArt:(size_t)type picture:(art::Picture)picture {
    if ([self refuseArtEdit] || !picture) return;
    if (_art.stageSet(type, std::move(picture))) [self setStatus:@"" error:NO];
    [self artChanged];
}

- (void)removeArt:(const std::vector<size_t>&)types {
    if ([self refuseArtEdit]) return;
    bool changed = false;
    for (size_t type : types) changed = _art.stageRemove(type) || changed;
    if (changed) [self setStatus:@"" error:NO];
    [self artChanged];
}

- (void)artPlusPressed:(id)sender {
    const NSInteger row = [self artRowForView:sender];
    if (row < 0) return;
    [_artTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [self importArtForRow:row];
}

- (void)artRemovePressed:(id)sender {
    const NSInteger row = [self artRowForView:sender];
    if (row < 0) return;
    [_artTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [self removeArt:std::vector<size_t>{(size_t)row}];
}

- (void)artDoubleClicked:(id)sender {
    (void)sender;
    const NSInteger row = _artTable.clickedRow;
    if (row < 0 || row >= (NSInteger)art::TypeCount || _artTable.clickedColumn != kArtPictureCol) return;
    [self importArtForRow:row];
}

// What "Import from file…" offers: what foobar2000 attaches (kept byte for byte) plus the formats that
// convert sensibly (WPEPictureFromData): HEIF/HEIC and AVIF photos from Photos or an iPhone (to JPEG) and
// TIFF (to PNG). Camera RAW, PSD and other image types stay greyed out: converted at full size to lossless
// PNG they would put tens of MB into every selected file.
- (NSArray<UTType*>*)importContentTypes {
    NSMutableArray<UTType*>* types =
        [@[ UTTypeJPEG, UTTypePNG, UTTypeGIF, UTTypeWebP, UTTypeBMP, UTTypeHEIF, UTTypeHEIC, UTTypeTIFF ] mutableCopy];
    if (UTType* avif = [UTType typeWithIdentifier:@"public.avif"]) [types addObject:avif];
    return types;
}

- (void)importArtForRow:(NSInteger)row {
    if (row < 0 || [self refuseArtEdit] || !self.window.visible || self.window.attachedSheet) return;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.message = @"Choose Picture File to Attach";
    panel.prompt = @"Attach";
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = [self importContentTypes];
    __weak WPEPropertiesWindowController* weakSelf = self;
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
                      if (response != NSModalResponseOK || !panel.URL) return;
                      [weakSelf importArtFile:panel.URL row:row];
                  }];
}

- (void)importArtFile:(NSURL*)url row:(NSInteger)row {
    NSError* error = nil;
    NSData* data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    art::Picture pic = data ? WPEPictureFromData(data) : nullptr;
    if (!pic) {
        NSBeep();
        [self setStatus:[NSString stringWithFormat:@"%@ is not a picture that can be attached%@", url.lastPathComponent,
                                                   error ? [@": " stringByAppendingString:error.localizedDescription] : @"."]
                  error:YES];
        return;
    }
    [self stageArt:(size_t)row picture:pic];
}

- (void)artImport:(id)sender {
    (void)sender;
    [self importArtForRow:[self artMenuRow]];
}

- (void)artExport:(id)sender {
    (void)sender;
    const NSInteger row = [self artMenuRow];
    if (row < 0 || !self.window.visible) return;
    const art::Picture pic = _art.slot((size_t)row).picture();
    if (!pic) return;
    const art::Format format = art::sniff(*pic);
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = WPEStr(art::file_name((size_t)row, format));
    if (UTType* t = [UTType typeWithIdentifier:WPEStr(art::format_uti(format))]) panel.allowedContentTypes = @[ t ];
    NSData* data = [NSData dataWithBytes:pic->data() length:pic->size()];
    __weak WPEPropertiesWindowController* weakSelf = self;
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
                      if (response != NSModalResponseOK || !panel.URL) return;
                      NSError* error = nil;
                      if (![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error])
                          [weakSelf setStatus:[@"Export failure: " stringByAppendingString:error.localizedDescription ?: @""] error:YES];
                  }];
}

// Copies the picture's own bytes (and a TIFF rendition for apps that only read TIFF).
- (void)copyArtRow:(NSInteger)row {
    if (row < 0) return;
    const art::Picture pic = _art.slot((size_t)row).picture();
    if (!pic) {
        NSBeep();
        return;
    }
    NSData* data = [NSData dataWithBytes:pic->data() length:pic->size()];
    NSString* uti = WPEStr(art::format_uti(art::sniff(*pic)));
    NSPasteboardItem* item = [[NSPasteboardItem alloc] init];
    if (uti.length) [item setData:data forType:uti];
    if (![uti isEqualToString:NSPasteboardTypeTIFF]) {
        NSData* tiff = [NSBitmapImageRep imageRepWithData:data].TIFFRepresentation;
        if (tiff) [item setData:tiff forType:NSPasteboardTypeTIFF];
    }
    NSPasteboard* pb = [self pasteboard];
    [pb clearContents];
    [pb writeObjects:@[ item ]];
}

- (void)pasteArtRow:(NSInteger)row {
    if (row < 0 || [self refuseArtEdit]) return;
    art::Picture pic = WPEPictureFromPasteboard([self pasteboard]);
    if (!pic) {
        NSBeep();
        [self setStatus:@"The clipboard holds no picture." error:NO];
        return;
    }
    [self stageArt:(size_t)row picture:pic];
}

- (void)artCopy:(id)sender {
    (void)sender;
    [self copyArtRow:[self artMenuRow]];
}

- (void)artPaste:(id)sender {
    (void)sender;
    [self pasteArtRow:[self artMenuRow]];
}

- (void)artRemove:(id)sender {
    (void)sender;
    const NSInteger row = [self artMenuRow];
    if (row >= 0) [self removeArt:std::vector<size_t>{(size_t)row}];
}

- (void)wpeArtCopy {
    [self copyArtRow:_artTable.selectedRow];
}

- (void)wpeArtPaste {
    [self pasteArtRow:_artTable.selectedRow];
}

- (void)wpeArtDelete {
    [self removeArt:[self selectedArtRows]];
}

- (BOOL)wpeArtValidate:(SEL)a {
    NSInteger row = (a == @selector(delete:)) ? _artTable.selectedRow : [self artMenuRow];
    if (a == @selector(copy:) || a == @selector(paste:)) row = _artTable.selectedRow;
    if (row < 0 || !_art.loaded()) return NO;
    const art::Slot& s = _art.slot((size_t)row);
    if (a == @selector(artImport:)) return [self canEditArt];
    if (a == @selector(artExport:) || a == @selector(artCopy:) || a == @selector(copy:))
        return s.state() == art::State::Present;
    if (a == @selector(artPaste:) || a == @selector(paste:)) return [self canEditArt] && WPEPasteboardMayHavePicture([self pasteboard]);
    if (a == @selector(artRemove:)) return [self canEditArt] && s.state() != art::State::Absent;
    if (a == @selector(delete:)) {
        for (size_t r : [self selectedArtRows])
            if (_art.slot(r).state() != art::State::Absent) return [self canEditArt];
        return NO;
    }
    return NO;
}

- (BOOL)wpeArtKeyDown:(NSEvent*)event {
    if (WPEMods(event) & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) return NO;
    NSString* chars = event.characters;
    const unichar c = chars.length ? [chars characterAtIndex:0] : 0;
    if (c == ' ') {
        [self toggleQuickLook];
        return YES;
    }
    if (event.keyCode == kKeyBackspace || event.keyCode == kKeyForwardDelete || c == NSDeleteFunctionKey) {
        [self wpeArtDelete];
        return YES;
    }
    if (event.keyCode == kKeyEscape) {
        [self wpeCancel];
        return YES;
    }
    return NO;
}

- (NSMenu*)wpeArtMenuForEvent:(NSEvent*)event {
    const NSPoint p = [_artTable convertPoint:event.locationInWindow fromView:nil];
    const NSInteger row = [_artTable rowAtPoint:p];
    if (row < 0) return nil;
    if (![_artTable isRowSelected:row])
        [_artTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    return _artMenu;
}

// Drag and drop: an image file or image data dropped on a row replaces that row's picture. A picture
// dragged from another row of this list is copied as it is (never converted); onto its own row it does nothing.
// Several rows dragged together are not dropped back into the list (which picture, and onto which row, would
// be a guess, and their bytes must not go through the import's conversion); they still drag out to Finder.
- (NSDragOperation)tableView:(NSTableView*)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)op {
    (void)op;
    if (tableView != _artTable || ![self canEditArt]) return NSDragOperationNone;
    if (info.draggingSource == _artTable && _dragRow < 0) return NSDragOperationNone;
    const BOOL ownRow = info.draggingSource == _artTable && _dragRow >= 0;
    if (!ownRow && !WPEPasteboardMayHavePicture(info.draggingPasteboard)) return NSDragOperationNone;
    const NSInteger target = std::clamp<NSInteger>(row, 0, (NSInteger)art::TypeCount - 1);
    if (ownRow && target == _dragRow) return NSDragOperationNone;
    [tableView setDropRow:target dropOperation:NSTableViewDropOn];
    return NSDragOperationCopy;
}

- (BOOL)tableView:(NSTableView*)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)op {
    (void)op;
    if (tableView != _artTable || row < 0 || row >= (NSInteger)art::TypeCount) return NO;
    if (info.draggingSource == _artTable) return _dragRow >= 0 && [self dropRow:_dragRow onRow:row];
    return [self dropPasteboard:info.draggingPasteboard row:row];
}

// A row dragged onto another row of the list: that picture, byte for byte.
- (BOOL)dropRow:(NSInteger)from onRow:(NSInteger)row {
    if (![self canEditArt] || from == row || from < 0 || from >= (NSInteger)art::TypeCount || row < 0 ||
        row >= (NSInteger)art::TypeCount)
        return NO;
    art::Picture pic = _art.slot((size_t)from).picture();
    if (!pic) return NO;
    [_artTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [self stageArt:(size_t)row picture:std::move(pic)];
    return YES;
}

// Dragging a picture out: a file promise named like Export to file… does, plus the bytes under their type.
- (id<NSPasteboardWriting>)tableView:(NSTableView*)tableView pasteboardWriterForRow:(NSInteger)row {
    if (tableView != _artTable || row < 0 || row >= (NSInteger)art::TypeCount || !_art.loaded()) return nil;
    const art::Picture pic = _art.slot((size_t)row).picture();
    if (!pic || pic->empty()) return nil;
    const art::Format format = art::sniff(*pic);
    NSString* uti = WPEStr(art::format_uti(format));
    WPEArtPromise* promise = [[WPEArtPromise alloc] initWithFileType:uti.length ? uti : UTTypeData.identifier delegate:self];
    promise.data = [NSData dataWithBytes:pic->data() length:pic->size()];
    promise.uti = uti;
    promise.fileName = WPEStr(art::file_name((size_t)row, format));
    return promise;
}

- (void)tableView:(NSTableView*)tableView
    draggingSession:(NSDraggingSession*)session
   willBeginAtPoint:(NSPoint)screenPoint
      forRowIndexes:(NSIndexSet*)rowIndexes {
    (void)screenPoint;
    if (tableView != _artTable) return;
    _dragRow = rowIndexes.count == 1 ? (NSInteger)rowIndexes.firstIndex : -1;
    // The drag shows the thumbnail where it was, not a picture of the whole row.
    __block NSUInteger index = rowIndexes.firstIndex;
    [session enumerateDraggingItemsWithOptions:NSDraggingItemEnumerationClearNonenumeratedImages
                                       forView:tableView
                                       classes:@[ [NSPasteboardItem class] ]
                                 searchOptions:@{}
                                    usingBlock:^(NSDraggingItem* item, NSInteger idx, BOOL* stop) {
                                        (void)idx;
                                        (void)stop;
                                        if (index == NSNotFound || index >= art::TypeCount) return;
                                        NSImage* thumb = self->_thumbs[index].image;
                                        if (thumb)
                                            [item setDraggingFrame:[tableView frameOfCellAtColumn:kArtPictureCol row:(NSInteger)index]
                                                          contents:thumb];
                                        index = [rowIndexes indexGreaterThanIndex:index];
                                    }];
}

- (void)tableView:(NSTableView*)tableView
    draggingSession:(NSDraggingSession*)session
       endedAtPoint:(NSPoint)screenPoint
          operation:(NSDragOperation)operation {
    (void)session;
    (void)screenPoint;
    (void)operation;
    if (tableView == _artTable) _dragRow = -1;
}

- (NSString*)filePromiseProvider:(NSFilePromiseProvider*)provider fileNameForType:(NSString*)fileType {
    (void)fileType;
    NSString* name = [provider isKindOfClass:[WPEArtPromise class]] ? ((WPEArtPromise*)provider).fileName : nil;
    return name.length ? name : @"Picture";
}

- (void)filePromiseProvider:(NSFilePromiseProvider*)provider
          writePromiseToURL:(NSURL*)url
          completionHandler:(void (^)(NSError* errorOrNil))completionHandler {
    NSData* data = [provider isKindOfClass:[WPEArtPromise class]] ? ((WPEArtPromise*)provider).data : nil;
    NSError* error = nil;
    if (!data) error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil];
    else [data writeToURL:url options:NSDataWritingAtomic error:&error];
    completionHandler(error);
}

#pragma mark Artwork: Quick Look

// The pictures Space shows: the selected rows that have one (all tracks the same), in list order, each as
// a file in this window's temporary folder named like Export to file… names it. A file is written once per
// picture and kept until the window closes (a picture staged since gets a new file).
- (NSArray<NSURL*>*)quickLookItems {
    NSMutableArray<NSURL*>* items = [NSMutableArray array];
    for (size_t type : [self selectedArtRows]) {
        const art::Picture pic = _art.loaded() ? _art.slot(type).picture() : nullptr;
        if (!pic || pic->empty()) continue;
        auto& cached = _qlFiles[type];
        if (cached.second && cached.first == pic) {
            [items addObject:cached.second];
            continue;
        }
        if (cached.second) [[NSFileManager defaultManager] removeItemAtURL:cached.second.URLByDeletingLastPathComponent error:nil];
        cached = {nullptr, nil};
        if (!_qlDir) {
            _qlDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                 [NSString stringWithFormat:@"io.github.metal2050.foo_windows_properties.QuickLook-%@",
                                                                            NSUUID.UUID.UUIDString]];
        }
        // A folder per file: Quick Look caches by URL, and a staged picture keeps its row's name.
        NSString* folder = [_qlDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu", (unsigned long)++_qlSerial]];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil])
            continue;
        NSURL* url = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:WPEStr(art::file_name(type, art::sniff(*pic)))]];
        if (![[NSData dataWithBytes:pic->data() length:pic->size()] writeToURL:url options:NSDataWritingAtomic error:nil]) continue;
        cached = {pic, url};
        [items addObject:url];
    }
    return items;
}

- (void)removeQuickLookFiles {
    _qlItems = nil;
    for (auto& f : _qlFiles) f = {nullptr, nil};
    if (_qlDir) [[NSFileManager defaultManager] removeItemAtPath:_qlDir error:nil];
    _qlDir = nil;
}

// Space: shows the selected pictures in Quick Look, or closes it again.
- (void)toggleQuickLook {
    if (_show && _qlPanel && _qlPanel.visible) {
        [_qlPanel orderOut:nil];
        return;
    }
    _qlItems = [self quickLookItems];
    if (!_show) {  // the tests' windows: the items are prepared, the shared panel (a window) is never shown
        if (!_qlItems.count) NSBeep();
        return;
    }
    if (!_qlItems.count) {
        NSBeep();
        return;
    }
    [[QLPreviewPanel sharedPreviewPanel] makeKeyAndOrderFront:nil];
}

- (void)reloadQuickLook {
    if (!_qlPanel) return;
    _qlItems = [self quickLookItems];
    [_qlPanel reloadData];
}

- (void)wpeArtBeginPreviewPanel:(QLPreviewPanel*)panel {
    _qlPanel = panel;
    panel.dataSource = self;
    panel.delegate = self;
    _qlItems = [self quickLookItems];
    [panel reloadData];
}

- (void)wpeArtEndPreviewPanel:(QLPreviewPanel*)panel {
    if (panel.dataSource == self) panel.dataSource = nil;
    if (panel.delegate == self) panel.delegate = nil;
    _qlPanel = nil;
}

- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel*)panel {
    (void)panel;
    return (NSInteger)_qlItems.count;
}

- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel*)panel previewItemAtIndex:(NSInteger)index {
    (void)panel;
    return index >= 0 && index < (NSInteger)_qlItems.count ? _qlItems[(NSUInteger)index] : nil;
}

// The arrow keys in the panel move the list's selection, as in Finder.
- (BOOL)previewPanel:(QLPreviewPanel*)panel handleEvent:(NSEvent*)event {
    (void)panel;
    if (event.type != NSEventTypeKeyDown) return NO;
    const unichar c = event.charactersIgnoringModifiers.length ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    if (c != NSUpArrowFunctionKey && c != NSDownArrowFunctionKey) return NO;
    [_artTable keyDown:event];
    return YES;
}

- (NSInteger)artRowForPreviewItem:(id<QLPreviewItem>)item {
    for (size_t type = 0; type < art::TypeCount; ++type)
        if (_qlFiles[type].second && [_qlFiles[type].second isEqual:item]) return (NSInteger)type;
    return -1;
}

// Quick Look zooms out of the thumbnail and back into it.
- (NSRect)previewPanel:(QLPreviewPanel*)panel sourceFrameOnScreenForPreviewItem:(id<QLPreviewItem>)item {
    (void)panel;
    const NSInteger row = [self artRowForPreviewItem:item];
    NSTableCellView* cell = row >= 0 ? [_artTable viewAtColumn:kArtPictureCol row:row makeIfNecessary:NO] : nil;
    NSImageView* thumb = [cell isKindOfClass:[NSTableCellView class]] ? cell.imageView : nil;
    if (!thumb || thumb.hidden || !self.window.visible) return NSZeroRect;
    const NSRect image = [thumb isKindOfClass:[WPEThumbView class]] ? [(WPEThumbView*)thumb wpeImageRect] : thumb.bounds;
    const NSRect inTable = [thumb convertRect:image toView:_artTable];
    if (!NSIntersectsRect(inTable, _artTable.visibleRect)) return NSZeroRect;
    return [self.window convertRectToScreen:[_artTable convertRect:inTable toView:nil]];
}

- (id)previewPanel:(QLPreviewPanel*)panel transitionImageForPreviewItem:(id<QLPreviewItem>)item contentRect:(NSRect*)contentRect {
    (void)panel;
    (void)contentRect;
    const NSInteger row = [self artRowForPreviewItem:item];
    return row >= 0 ? _thumbs[(size_t)row].image : nil;
}

- (BOOL)dropPasteboard:(NSPasteboard*)pb row:(NSInteger)row {
    if (![self canEditArt]) return NO;
    art::Picture pic = WPEPictureFromPasteboard(pb);
    if (!pic) return NO;
    [_artTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [self stageArt:(size_t)row picture:pic];
    return YES;
}

#pragma mark Buttons, status and writing

- (void)setStatus:(NSString*)text error:(BOOL)error {
    _statusText = [text copy] ?: @"";
    _statusError = error;
    [self updateStatus];
}

// The status line (in the button bar) shows the last message; otherwise what is going on (reading,
// pending pictures), and nothing when there is no news. A spinner runs beside it while tags, pictures
// or details are being read or written.
- (void)updateStatus {
    NSString* text = _statusText;
    BOOL error = _statusError;
    const BOOL busy = _writing || _loading || (_artLoading && _tab == kTabArtwork) || (_detailsLoading && _tab == kTabDetails);
    if (!text.length) {
        if (_artLoading && _tab == kTabArtwork) {
            text = kWPELoadingArt;
        } else if (_detailsLoading && _tab == kTabDetails) {
            text = kWPEReadingDetails;
        } else if (_art.dirty()) {
            text = [NSString stringWithFormat:@"%@ (pending)", WPEStr(art::type_list(_art.pendingTypes()))];
        } else if (_artError && _tab == kTabArtwork) {
            text = _artError;
            error = YES;
        }
    }
    WPESetStatusText(_status, text, error);
    const BOOL spin = busy && !error;
    if (spin == _spinner.hidden) {
        _spinner.hidden = !spin;
        if (spin) [_spinner startAnimation:nil];
        else [_spinner stopAnimation:nil];
        _statusLeading.constant = kBarSpacing + (spin ? _spinner.intrinsicContentSize.width + kStatusSpinnerGap : 0);
    }
}

- (void)updateButtons {
    const BOOL busy = _writing || _loading;
    const BOOL dirty = _table.dirty() || _art.dirty() || _rg.dirty();
    _ok.enabled = !_writing;
    _apply.enabled = !busy && dirty;
    _tools.enabled = !_writing;
    // A write in progress (tags, then pictures) cannot be cancelled halfway from here: closing now
    // would leave the tags written and the pictures not. The host's progress window can abort it.
    _cancel.enabled = !_writing;
    self.window.documentEdited = dirty;
    [self refreshArtButtons];
    [self updateStatus];
}

- (void)okPressed:(id)sender {
    (void)sender;
    [self writeAndClose:YES];
}

- (void)applyPressed:(id)sender {
    (void)sender;
    [self writeAndClose:NO];
}

- (void)cancelPressed:(id)sender {
    (void)sender;
    if (_writing) {
        NSBeep();
        return;
    }
    _pendingRow = -1;
    [self endEditing:NO focusTable:YES];
    [self.window close];
}

#pragma mark Asking before closing

// The tracks OK/Apply would write now (tags and ReplayGain), as writeAndClose: picks them.
- (std::vector<size_t>)tracksToWrite {
    std::set<size_t> both;
    if (!_loading) {
        for (size_t t : _table.changedTracks()) both.insert(t);
        for (size_t t : _rg.changedTracks()) both.insert(t);
    }
    return std::vector<size_t>(both.begin(), both.end());
}

// The physical files OK/Apply would write now (a CUE image's subsongs count once).
- (size_t)pendingFileCount {
    const std::vector<std::string> paths = _backend->trackPaths();
    return WPEFileCount([self tracksToWrite], _art.plan(paths), paths);
}

// Before closing with the close button, ⌘W or quitting: an open edit is committed, as a click elsewhere
// commits it. Returns whether anything would then be lost: staged tags, ReplayGain values or pictures, or
// a ReplayGain value that does not parse (back in its editor, with the status line saying why).
- (BOOL)commitForClose {
    [self prepareCommand];
    return _table.dirty() || _art.dirty() || _rg.dirty() || (_rgRetryText != nil && _rgPendingRow >= 0);
}

// Whether quitting would lose anything here, without touching the window (the quit guard's
// isDocumentEdited). An open editor or Edit Value sheet counts; the review then commits it and asks only
// if something is really staged.
- (BOOL)needsQuitReview {
    if (_closed || _writing) return NO;
    return _table.dirty() || _art.dirty() || _rg.dirty() || [self isEditing] || _rgEditField != nil ||
           (_rgRetryText != nil && _rgPendingRow >= 0) || _valueSheet != nil || _closeAlert != nil;
}

// "Do you want to apply the changes you made to 3 files?" with Apply (the default, Return), Cancel (Esc)
// and Don't Apply (⌘D): the Mac's save-changes prompt (Save, Cancel, Don't Save) in this window's words.
- (NSAlert*)closeAlert:(BOOL)quitting {
    const size_t files = [self pendingFileCount];
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = files ? [NSString stringWithFormat:@"Do you want to apply the changes you made to %@?", plural(files, @"file")]
                              : @"Do you want to apply the changes you made?";
    alert.informativeText = quitting ? @"foobar2000 is quitting. Your changes will be lost if you don’t apply them."
                                     : @"Your changes will be lost if you don’t apply them.";
    NSButton* apply = [alert addButtonWithTitle:@"Apply"];
    apply.keyEquivalent = @"\r";
    NSButton* cancel = [alert addButtonWithTitle:@"Cancel"];
    cancel.keyEquivalent = @"\033";
    NSButton* discard = [alert addButtonWithTitle:@"Don’t Apply"];
    discard.keyEquivalent = @"d";
    discard.keyEquivalentModifierMask = NSEventModifierFlagCommand;  // as Don't Save
    return alert;
}

// Shows the prompt as a sheet. `reply` (the quit review) learns whether the window closed.
- (void)askBeforeClosing:(BOOL)quitting reply:(void (^)(BOOL closed))reply {
    _closeReply = [reply copy];
    NSAlert* alert = [self closeAlert:quitting];
    _closeAlert = alert;
    if (!_show) return;  // the tests' windows are never shown: wpe_test_answer_close_prompt() answers
    __weak WPEPropertiesWindowController* weakSelf = self;
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
                      [weakSelf closePromptEnded:response alert:alert];
                  }];
}

- (void)closePromptEnded:(NSModalResponse)response alert:(NSAlert*)alert {
    if (!alert || alert != _closeAlert) return;
    _closeAlert = nil;
    void (^reply)(BOOL) = _closeReply;
    _closeReply = nil;
    if (_closed) {
        if (reply) reply(YES);
        return;
    }
    if (response == NSAlertThirdButtonReturn) {  // Don't Apply: as Cancel, nothing is written
        [self cancelPressed:nil];
        if (reply) reply(_closed);
        return;
    }
    if (response != NSAlertFirstButtonReturn) {  // Cancel: back to the window, everything still staged
        if (reply) reply(NO);
        return;
    }
    // Apply: as OK. A quit waits for the files instead of the prompt: it is called off now and asked
    // for again once everything is written (a failure keeps foobar2000 running, the errors shown).
    if (reply) {
        _quitAfterWrite = YES;
        reply(NO);
    }
    [self writeAndClose:YES];
    if (!_writing && !_closed) _quitAfterWrite = NO;  // nothing started (a ReplayGain value that does not parse)
}

// One step of the quit review (WPEQuitGuard): asks this window's question, if it has one. reply(YES)
// when it closed or has nothing to lose (it then closes with the others), reply(NO) to keep foobar2000
// running. Every reply comes synchronously or from the user's answer, never from a later main-queue block:
// -[NSApplication terminate:] waits for it in a modal run loop, maybe inside one.
- (void)reviewForQuit:(void (^)(BOOL closed))reply {
    if (![self needsQuitReview]) {
        reply(YES);
        return;
    }
    if (_closeAlert) {  // already asking (the close button): that answer decides the quit too
        if (_closeReply) reply(NO);
        else _closeReply = [reply copy];
        return;
    }
    // Sheets first. Edit Value ends as OK (its values staged, then asked about with the rest); any other
    // sheet (Format from Other Fields, an Open or Save panel, an error report) is cancelled.
    if (_valueSheet) [_valueSheet finish:YES];
    if (NSWindow* sheet = self.window.attachedSheet) {
        if ([sheet isKindOfClass:[NSSavePanel class]]) [(NSSavePanel*)sheet cancel:nil];
        else [self.window endSheet:sheet returnCode:NSModalResponseCancel];
    }
    if (![self commitForClose]) {
        reply(YES);
        return;
    }
    if (_show) {
        NSWindow* win = self.window;
        const BOOL appHidden = NSApp.hidden;
        if (!WPEQuitCanAsk(win.visible, win.miniaturized, appHidden)) {  // closed with the others (and logged)
            reply(YES);
            return;
        }
        // While foobar2000 is hidden (Cmd-H) every window is ordered out, so it is shown again first; a quit
        // from the Dock or a logout can come while another app is active, so foobar2000 comes forward too.
        if (appHidden) [NSApp unhide:nil];
        if (win.miniaturized) [win deminiaturize:nil];
        if (!NSApp.active) {
            if (@available(macOS 14.0, *)) [NSApp activate];
            else [NSApp activateIgnoringOtherApps:YES];
            [NSApp requestUserAttention:NSCriticalRequest];  // bounces the Dock icon if it did not come forward
        }
        [win makeKeyAndOrderFront:nil];
    }
    [self askBeforeClosing:YES reply:reply];
}

// For foobar2000's console when it quits without having asked (initquit): what this window drops.
- (NSString*)quitNote {
    if (_closed) return nil;
    NSString* title = self.window.title ?: @"Properties";
    if (_writing)
        return [NSString stringWithFormat:@"%@ was closed while writing to %@; some may not have been updated.", title,
                                          plural(_writeFiles, @"file")];
    if (!_table.dirty() && !_art.dirty() && !_rg.dirty() && ![self isEditing] && !_rgEditField && !_valueSheet) return nil;
    const size_t files = [self pendingFileCount];
    return [NSString stringWithFormat:@"%@ was closed with changes that were not applied%@; nothing was written.", title,
                                      files ? [NSString stringWithFormat:@" (%@)", plural(files, @"file")] : @""];
}

// OK and Apply write the tags (metadb_io) and then the pictures (album_art_editor). If either part
// fails the window stays open with that part's changes kept, so pressing Apply again retries it.
- (void)writeAndClose:(BOOL)close {
    if (_writing || _closed) return;
    if (_valueSheet) {  // the sheet is modal for this window; its values are not staged yet
        NSBeep();
        return;
    }
    // A ReplayGain value that does not parse keeps the window open with the error shown and the
    // editor reopened on the typed text.
    if (![self rgFinishEdit]) return;
    [self prepareCommand];
    // While tags are (re)loading the table is clean, but staged pictures may still need writing.
    if (_loading && !_art.dirty()) {
        if (close) [self.window close];
        return;
    }
    // Tags and ReplayGain go to the same tracks in one metadb_io_v2 update.
    const std::vector<size_t> tracks = [self tracksToWrite];
    const std::vector<std::string> paths = _backend->trackPaths();
    std::vector<art::FileOps> artFiles = _art.plan(paths);
    if (tracks.empty() && artFiles.empty()) {
        if (_art.dirty()) {
            _art.discard();  // every file already has the staged pictures
            [self artChanged];
        }
        if (close) [self.window close];
        else [self setStatus:@"Nothing to write." error:NO];
        return;
    }
    std::set<size_t> pictureTypes;
    for (auto& f : artFiles)
        for (auto& op : f.ops) pictureTypes.insert(op.type);
    const size_t fields = tracks.empty() ? 0 : _table.changedFields().size() + _rg.changedFields().size();
    _writeFiles = WPEFileCount(tracks, artFiles, paths);
    _writing = YES;
    _closeAfterWrite = close;
    _writeErrors.clear();
    _writeAborted = NO;
    _didTags = !tracks.empty();
    _didArt = !artFiles.empty();
    _tagsOK = YES;
    _artOK = YES;
    _artSkipped = NO;
    _artFiles = std::move(artFiles);

    NSMutableArray* what = [NSMutableArray array];
    if (fields) [what addObject:plural(fields, @"field")];
    if (!pictureTypes.empty()) [what addObject:plural(pictureTypes.size(), @"picture")];
    [self setStatus:[NSString stringWithFormat:@"Writing %@ to %@…", [what componentsJoinedByString:@" and "],
                                               plural(_writeFiles, @"file")]
              error:NO];
    [self updateButtons];
    if (close && _show) [self.window orderOut:nil];

    if (tracks.empty()) {
        [self startArtWrite];
        return;
    }
    wpe::Plan plan = _table.plan();
    plan.rg = _rg.plan();
    __weak WPEPropertiesWindowController* weakSelf = self;
    _backend->write(plan, tracks, [weakSelf](wpe::WriteResult result) { [weakSelf tagsWritten:result]; });
}

- (void)collectResult:(const wpe::WriteResult&)result ok:(BOOL*)ok {
    if (result.code == wpe::WriteResult::Success && result.errors.empty()) return;
    *ok = NO;
    if (result.code == wpe::WriteResult::Aborted) _writeAborted = YES;
    _writeErrors.insert(_writeErrors.end(), result.errors.begin(), result.errors.end());
}

- (void)tagsWritten:(const wpe::WriteResult&)result {
    [self collectResult:result ok:&_tagsOK];
    if (_closed) {
        _writing = NO;
        return;
    }
    // The user aborted the tag update: do not follow it with a second rewrite of the same files.
    // The pictures stay staged, so Apply can retry them.
    if (result.code == wpe::WriteResult::Aborted && !_artFiles.empty()) {
        _artFiles.clear();
        _artOK = NO;
        _artSkipped = YES;
        [self writeFinished];
        return;
    }
    [self startArtWrite];
}

- (void)startArtWrite {
    if (_closed) {
        _writing = NO;
        return;
    }
    if (_artFiles.empty()) {
        [self writeFinished];
        return;
    }
    std::vector<art::FileOps> files = std::move(_artFiles);
    _artFiles.clear();
    __weak WPEPropertiesWindowController* weakSelf = self;
    _backend->writeArt(std::move(files), [weakSelf](wpe::WriteResult result) { [weakSelf artWritten:result]; });
}

- (void)artWritten:(const wpe::WriteResult&)result {
    [self collectResult:result ok:&_artOK];
    // Every file now has the staged pictures: they stop being pending at once, so nothing (a reload
    // already running, another Apply) can write or drop them again before the files are read back.
    if (_artOK && !_closed) {
        _art.commit();
        [self artChanged];
    }
    [self writeFinished];
}

- (void)writeFinished {
    _writing = NO;
    const BOOL closing = _closeAfterWrite;
    _closeAfterWrite = NO;
    if (_closed) return;
    const BOOL ok = _tagsOK && _artOK;
    if (!ok) _quitAfterWrite = NO;  // Apply in the quit prompt failed: foobar2000 keeps running
    if (ok && closing) {
        [self.window close];
        return;
    }
    if (ok) [self setStatus:[NSString stringWithFormat:@"Updated %@.", plural(_writeFiles, @"file")] error:NO];
    // The part that was written is reloaded from the files; the part that failed keeps its edits.
    if (_didTags && _tagsOK) [self startLoadAfterWrite:YES];
    if (_didArt && _artOK) [self startArtLoad];
    else if (_artReloadPending && !_art.dirty()) [self startArtLoad];
    [self detailsChangedOutside];  // file size, modification time, ReplayGain lines
    [self schedulePendingReload];
    [self updateButtons];
    if (ok) return;
    if (closing && _show) [self.window makeKeyAndOrderFront:nil];
    [self reportWriteErrors];
}

- (void)refreshArtButtons {
    const BOOL editable = [self canEditArt];
    for (NSInteger row = 0; row < (NSInteger)art::TypeCount; ++row) {
        for (NSInteger col : {kArtPictureCol, kArtRemoveCol}) {
            NSView* v = [_artTable viewAtColumn:col row:row makeIfNecessary:NO];
            if ([v isKindOfClass:[WPEArtCell class]]) ((WPEArtCell*)v).button.enabled = editable;
        }
    }
}

- (void)reportWriteErrors {
    // One entry per track for tags (every subsong of a CUE image adds one) and per file for pictures:
    // the count is of physical files, and repeated messages are listed once.
    const art::Errors errs = art::unique_errors(_writeErrors);
    const size_t failed = art::failed_files(errs);
    NSString* skipped = _artSkipped ? @" The pictures were not written." : @"";
    if (_writeAborted) {
        [self setStatus:[NSString stringWithFormat:@"Writing was cancelled; some files may not have been updated.%@ "
                                                   @"Your edits are kept; press Apply to retry.",
                                                   skipped]
                  error:YES];
        if (errs.empty()) return;
    } else if (errs.empty()) {
        [self setStatus:@"Some files could not be updated." error:YES];
        return;
    } else if (failed == 0) {
        [self setStatus:[NSString stringWithFormat:@"Writing failed: %@. Your edits are kept; press Apply to retry.",
                                                   WPEStr(errs.front().second)]
                  error:YES];
    } else {
        [self setStatus:[NSString stringWithFormat:@"%@ could not be updated: %@. Your edits are kept; press Apply to retry.",
                                                   plural(failed, @"file"), WPEStr(errs.front().second)]
                  error:YES];
    }
    if (!self.window.visible) return;
    NSMutableString* details = [NSMutableString string];
    const size_t shown = std::min<size_t>(errs.size(), 12);
    for (size_t i = 0; i < shown; ++i) {
        std::string path = errs[i].first;
        if (path.rfind("file://", 0) == 0) path = path.substr(7);
        if (path.empty()) [details appendFormat:@"%@\n\n", WPEStr(errs[i].second)];
        else [details appendFormat:@"%@\n%@\n\n", WPEStr(path), WPEStr(errs[i].second)];
    }
    if (errs.size() > shown) [details appendFormat:@"…and %zu more.", errs.size() - shown];
    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = failed <= 1 ? @"A file could not be updated" : @"Some files could not be updated";
    alert.informativeText = details;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark Test hooks

- (NSTableView*)wpeTestTable {
    return _tableView;
}
- (NSInteger)wpeTestEditRow {
    return _editRow;
}
- (NSInteger)wpeTestEditCol {
    return _editCol;
}
- (BOOL)wpeTestMultiline {
    return _mlText != nil;
}
- (NSString*)wpeTestEditorText {
    if (_mlText) return [_mlText.string copy];
    if (_editField) return _editField.currentEditor ? [_editField.currentEditor.string copy] : _editField.stringValue;
    return nil;
}
- (NSString*)wpeTestStatus {
    return _status.stringValue;
}
- (BOOL)wpeTestApplyEnabled {
    return _apply.enabled;
}
- (BOOL)wpeTestWriting {
    return _writing;
}
- (NSMenu*)wpeTestMenu {
    return _menu;
}
- (const wpe::Table&)wpeTestModel {
    return _table;
}
- (NSInteger)wpeTestTab {
    return _tab;
}
- (NSSegmentedControl*)wpeTestTabControl {
    return _tabs;
}
- (BOOL)wpeTestStatusBusy {
    return !_spinner.hidden;
}
- (NSArray<NSButton*>*)wpeTestButtons {
    return @[ _tools, _ok, _cancel, _apply ];
}
- (NSMenu*)wpeTestToolsMenu {
    return _toolsMenu;
}
- (NSTableView*)wpeTestArtTable {
    return _artTable;
}
- (NSMenu*)wpeTestArtMenu {
    return _artMenu;
}
- (const art::Table&)wpeTestArtModel {
    return _art;
}
- (BOOL)wpeTestThumbnailReady:(size_t)type {
    return type < art::TypeCount && _thumbs[type].image != nil;
}
- (void)wpeTestSetPasteboard:(NSPasteboard*)pb {
    _pasteboard = pb;
}
- (NSTableView*)wpeTestDetailsTable {
    return _detailsTable;
}
- (const std::vector<details::Line>&)wpeTestDetails {
    return _details;
}
- (NSTableView*)wpeTestReplayGainTable {
    return _rgTable;
}
- (const rg::Table&)wpeTestReplayGain {
    return _rg;
}
- (NSInteger)wpeTestReplayGainEditRow {
    return _rgEditRow;
}
- (NSString*)wpeTestReplayGainEditorText {
    if (!_rgEditField) return nil;
    return _rgEditField.currentEditor ? [_rgEditField.currentEditor.string copy] : _rgEditField.stringValue;
}
- (NSMenu*)wpeTestDetailsMenu {
    return _detailsMenu;
}
- (NSMenu*)wpeTestReplayGainMenu {
    return _rgMenu;
}
- (id)wpeTestValueSheet {
    return _valueSheet;
}
- (NSAlert*)wpeTestClosePrompt {
    return _closeAlert;
}
- (void)wpeTestAnswerClosePrompt:(NSModalResponse)response {
    [self closePromptEnded:response alert:_closeAlert];
}
- (NSArray<NSURL*>*)wpeTestQuickLookItems {
    return _qlItems;
}
- (NSString*)wpeTestQuickLookFolder {
    return _qlDir;
}
- (id<NSPasteboardWriting>)wpeTestArtWriter:(NSInteger)row {
    return [self tableView:_artTable pasteboardWriterForRow:row];
}
- (void)wpeTestArtDragRow:(NSInteger)row {
    _dragRow = row;
}
- (NSArray<UTType*>*)wpeTestImportTypes {
    return [self importContentTypes];
}

@end

#pragma mark - Asking at quit

// Quitting foobar2000 asks each window with unapplied changes, in turn, as closing it would. foobar2000's
// app delegate has no applicationShouldTerminate:, so the one place a quit can still be called off is
// AppKit's document review: -[NSApplication terminate:] asks the document controller, which asks each
// edited document whether it may close, before anything shuts down. This document stands for every
// Properties window; it is never saved, has no window of its own and holds no file.
@interface WPEQuitGuard : NSDocument
@end

static WPEQuitGuard* g_wpeQuitGuard;

// Asks windows[i...] in order; done(NO) at the first that stays open, done(YES) when none does.
static void WPEReviewForQuit(NSArray<WPEPropertiesWindowController*>* windows, NSUInteger i, void (^done)(BOOL)) {
    for (; i < windows.count; ++i) {
        WPEPropertiesWindowController* c = windows[i];
        if (![c needsQuitReview]) continue;
        const NSUInteger next = i + 1;
        [c reviewForQuit:^(BOOL closed) {
            if (closed) WPEReviewForQuit(windows, next, done);
            else done(NO);
        }];
        return;
    }
    done(YES);
}

@implementation WPEQuitGuard

+ (BOOL)autosavesInPlace {
    return NO;
}

+ (BOOL)preservesVersions {
    return NO;
}

- (BOOL)isDocumentEdited {
    for (WPEPropertiesWindowController* c in g_wpeWindows)
        if ([c needsQuitReview]) return YES;
    return NO;
}

- (NSString*)displayName {
    return @"Properties";
}

- (void)canCloseDocumentWithDelegate:(id)delegate shouldCloseSelector:(SEL)shouldCloseSelector contextInfo:(void*)contextInfo {
    WPEQuitGuard* me = self;
    WPEReviewForQuit([g_wpeWindows copy] ?: @[], 0, ^(BOOL ok) {
        if (delegate && shouldCloseSelector)
            ((void (*)(id, SEL, id, BOOL, void*))objc_msgSend)(delegate, shouldCloseSelector, me, ok, contextInfo);
    });
}

- (void)close {
    [super close];
    if (g_wpeQuitGuard == self) g_wpeQuitGuard = nil;
}

@end

// Registered with the first window shown (creating the app's document controller, which foobar2000
// itself does not use); a cancelled quit keeps it, a quit that goes on closes it.
static void WPEInstallQuitGuard() {
    if (g_wpeQuitGuard) return;
    g_wpeQuitGuard = [[WPEQuitGuard alloc] init];
    [[NSDocumentController sharedDocumentController] addDocument:g_wpeQuitGuard];
}

#pragma mark - Entry points

static NSWindow* WPELastVisibleWindow() {
    for (WPEPropertiesWindowController* c in g_wpeWindows.reverseObjectEnumerator)
        if (c.window.visible) return c.window;
    return nil;
}

id wpe_create_properties_window(std::shared_ptr<wpe::Backend> backend, bool show) {
    if (!backend) return nil;
    if (!g_wpeWindows) g_wpeWindows = [NSMutableArray array];
    NSWindow* previous = show ? WPELastVisibleWindow() : nil;
    WPEPropertiesWindowController* controller = [[WPEPropertiesWindowController alloc] initWithBackend:std::move(backend)
                                                                                                  show:show];
    if (!controller) return nil;
    [g_wpeWindows addObject:controller];
    [controller showCascadingFrom:previous];
    return controller;
}

void wpe_show_properties_window(std::shared_ptr<wpe::Backend> backend) {
    if (backend && backend->trackCount() > 0) wpe_create_properties_window(std::move(backend), true);
}

std::vector<std::string> wpe_close_all_windows() {
    std::vector<std::string> notes;
    NSArray<WPEPropertiesWindowController*>* all = [g_wpeWindows copy];
    for (WPEPropertiesWindowController* c in all) {
        if (NSString* note = [c quitNote]) notes.push_back(WPEUtf8(note));
        [c.window close];
    }
    return notes;
}

size_t wpe_open_window_count() {
    return g_wpeWindows.count;
}

#define WPE_C(c) ((WPEPropertiesWindowController*)(c))

NSWindow* wpe_test_window(id c) {
    return [WPE_C(c) window];
}
NSTableView* wpe_test_table(id c) {
    return [WPE_C(c) wpeTestTable];
}
NSInteger wpe_test_edit_row(id c) {
    return [WPE_C(c) wpeTestEditRow];
}
NSInteger wpe_test_edit_col(id c) {
    return [WPE_C(c) wpeTestEditCol];
}
bool wpe_test_multiline(id c) {
    return [WPE_C(c) wpeTestMultiline];
}
NSString* wpe_test_editor_text(id c) {
    return [WPE_C(c) wpeTestEditorText];
}
NSString* wpe_test_status(id c) {
    return [WPE_C(c) wpeTestStatus];
}
bool wpe_test_apply_enabled(id c) {
    return [WPE_C(c) wpeTestApplyEnabled];
}
bool wpe_test_writing(id c) {
    return [WPE_C(c) wpeTestWriting];
}
NSMenu* wpe_test_menu(id c) {
    return [WPE_C(c) wpeTestMenu];
}
const wpe::Table& wpe_test_model(id c) {
    return [WPE_C(c) wpeTestModel];
}
NSInteger wpe_test_tab(id c) {
    return [WPE_C(c) wpeTestTab];
}
void wpe_test_select_tab(id c, NSInteger tab) {
    [WPE_C(c) selectTab:tab];
}
NSSegmentedControl* wpe_test_tab_control(id c) {
    return [WPE_C(c) wpeTestTabControl];
}
NSArray<NSString*>* wpe_test_tab_titles(id c) {
    NSSegmentedControl* t = [WPE_C(c) wpeTestTabControl];
    NSMutableArray* out = [NSMutableArray array];
    for (NSInteger i = 0; i < t.segmentCount; ++i) [out addObject:[t labelForSegment:i] ?: @""];
    return out;
}
bool wpe_test_status_busy(id c) {
    return [WPE_C(c) wpeTestStatusBusy];
}
void wpe_test_set_last_tab(NSInteger tab) {
    g_wpeLastTab = tab;
}
NSArray<NSButton*>* wpe_test_buttons(id c) {
    return [WPE_C(c) wpeTestButtons];
}
NSMenu* wpe_test_tools_menu(id c) {
    return [WPE_C(c) wpeTestToolsMenu];
}
NSTableView* wpe_test_art_table(id c) {
    return [WPE_C(c) wpeTestArtTable];
}
NSMenu* wpe_test_art_menu(id c) {
    return [WPE_C(c) wpeTestArtMenu];
}
const wpe::art::Table& wpe_test_art_model(id c) {
    return [WPE_C(c) wpeTestArtModel];
}
bool wpe_test_art_thumbnail_ready(id c, size_t type) {
    return [WPE_C(c) wpeTestThumbnailReady:type];
}
void wpe_test_set_pasteboard(id c, NSPasteboard* pb) {
    [WPE_C(c) wpeTestSetPasteboard:pb];
}
bool wpe_test_format(id c, NSString* field, NSString* pattern) {
    return [WPE_C(c) formatField:field pattern:pattern];
}
NSTableView* wpe_test_details_table(id c) {
    return [WPE_C(c) wpeTestDetailsTable];
}
const std::vector<wpe::details::Line>& wpe_test_details(id c) {
    return [WPE_C(c) wpeTestDetails];
}
NSMenu* wpe_test_details_menu(id c) {
    return [WPE_C(c) wpeTestDetailsMenu];
}
NSTableView* wpe_test_rg_table(id c) {
    return [WPE_C(c) wpeTestReplayGainTable];
}
const wpe::rg::Table& wpe_test_rg_model(id c) {
    return [WPE_C(c) wpeTestReplayGain];
}
NSInteger wpe_test_rg_edit_row(id c) {
    return [WPE_C(c) wpeTestReplayGainEditRow];
}
NSString* wpe_test_rg_editor_text(id c) {
    return [WPE_C(c) wpeTestReplayGainEditorText];
}
NSMenu* wpe_test_rg_menu(id c) {
    return [WPE_C(c) wpeTestReplayGainMenu];
}
id wpe_test_value_sheet(id c) {
    return [WPE_C(c) wpeTestValueSheet];
}
NSAlert* wpe_test_close_prompt(id c) {
    return [WPE_C(c) wpeTestClosePrompt];
}
void wpe_test_answer_close_prompt(id c, NSModalResponse response) {
    [WPE_C(c) wpeTestAnswerClosePrompt:response];
}
void wpe_test_review_for_quit(void (^done)(bool ok)) {
    WPEReviewForQuit([g_wpeWindows copy] ?: @[], 0, ^(BOOL ok) {
        done(ok);
    });
}
void wpe_test_set_quit_again(void (^quitAgain)(void)) {
    g_wpeQuitAgain = [quitAgain copy];
}
NSDocument* wpe_test_install_quit_guard() {
    WPEInstallQuitGuard();
    return g_wpeQuitGuard;
}
NSArray<NSURL*>* wpe_test_quicklook_items(id c) {
    return [WPE_C(c) wpeTestQuickLookItems];
}
NSString* wpe_test_quicklook_folder(id c) {
    return [WPE_C(c) wpeTestQuickLookFolder];
}
id<NSPasteboardWriting> wpe_test_art_writer(id c, NSInteger row) {
    return [WPE_C(c) wpeTestArtWriter:row];
}
void wpe_test_art_drag_row(id c, NSInteger row) {
    [WPE_C(c) wpeTestArtDragRow:row];
}
bool wpe_test_quit_can_ask(bool visible, bool miniaturized, bool appHidden) {
    return WPEQuitCanAsk(visible, miniaturized, appHidden);
}

NSArray<UTType*>* wpe_test_import_types(id c) {
    return [WPE_C(c) wpeTestImportTypes];
}
