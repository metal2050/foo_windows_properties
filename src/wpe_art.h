#pragma once
// Pure model of the Properties > Artwork page: the embedded pictures of N tracks merged into five
// rows, staged edits, what to write per physical file, and picture format/size details.
// No SDK, no Cocoa.

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace wpe::art {

// The rows of the Artwork page, in the order foobar2000 for Windows shows them. The order is also
// the SDK's album_art_ids::query_type() order (front cover, back cover, artist, disc, icon).
enum Type : size_t { FrontCover = 0, BackCover, Artist, Disc, Icon, TypeCount };
const char* type_label(size_t type);  // "Front Cover", "Back Cover", "Artist", "Disc", "Icon"

using Bytes = std::vector<uint8_t>;
// Picture data shared between the model, the UI and the writer. Null means "no picture".
using Picture = std::shared_ptr<const Bytes>;
Picture make_picture(Bytes bytes);
Picture make_picture(const void* data, size_t size);
// Both absent, or the same bytes.
bool same(const Picture& a, const Picture& b);

extern const char* const kNotPresent;      // «not present»
extern const char* const kMultipleValues;  // «multiple values»

enum class Format { Unknown, JPEG, PNG, GIF, WebP, BMP, TIFF, ICO, HEIF, AVIF };
Format sniff(const uint8_t* data, size_t size);
inline Format sniff(const Bytes& b) { return sniff(b.data(), b.size()); }
const char* format_name(Format f);       // "JPEG", "PNG", ... ("" for Unknown)
const char* format_extension(Format f);  // "jpg", "png", ... ("bin" for Unknown)
const char* format_uti(Format f);        // "public.jpeg", "public.png", ... ("" for Unknown)
// Whether foobar2000's own attach dialog offers this format (*.jpg;*.jpeg;*.png;*.bmp;*.gif;*.webp).
bool attachable(Format f);

// How a picture brought in from outside (Import from file…, paste, drop) is attached. Pictures already on
// the tracks are never converted: OK/Apply write their bytes as they are.
//   Keep  an attachable format: the file's own bytes, byte for byte
//   JPEG  a HEIF or AVIF photo without transparency (already lossy; a PNG would be several times larger)
//   PNG   anything else macOS can decode (TIFF, PDF, ICO, ...) and every picture with transparency: lossless
enum class Conversion { Keep, JPEG, PNG };
Conversion conversion_for(Format source, bool hasAlpha);
constexpr double kJPEGQuality = 0.92;  // the JPEG compression quality of a converted photo

// The file name a picture is exported, dragged out or previewed as: "Front Cover.jpg".
std::string file_name(size_t type, Format f);

struct Dimensions {
    uint32_t width = 0;
    uint32_t height = 0;
    bool valid() const { return width > 0 && height > 0; }
    bool operator==(const Dimensions&) const = default;
};
// Read from the file header without decoding (JPEG, PNG, GIF, WebP, BMP, ICO); invalid otherwise.
Dimensions dimensions(const uint8_t* data, size_t size);
inline Dimensions dimensions(const Bytes& b) { return dimensions(b.data(), b.size()); }

// Windows style: whole KB below 1 MB (rounded up, so any non-empty picture is at least 1 KB), then
// MB/GB with three significant digits ("489 KB", "1.43 MB", "12.3 MB").
std::string size_text(uint64_t bytes);
std::string dimensions_text(Dimensions d);  // "600x600", "" when unknown

enum class State { Absent, Present, Mixed };

struct TrackArt {
    std::array<Picture, TypeCount> pictures;
};

struct Slot {
    enum class Pending { None, Set, Remove };

    State loaded = State::Absent;
    Picture loadedPicture;  // the picture shared by all tracks when loaded == Present
    Pending pending = Pending::None;
    Picture pendingPicture;  // when pending == Set

    State state() const;
    Picture picture() const;  // what the row shows, null unless state() == Present
    bool isPending() const { return pending != Pending::None; }
};

struct Details {
    std::vector<std::string> lines;  // {"489 KB", "600x600", "PNG"}, {"«not present»"} or {"«multiple values»"}
    bool mixed = false;
    bool absent = false;
    bool pending = false;
};

struct Op {
    size_t type = 0;
    Picture picture;  // null: remove
};

// One physical file and the changes it needs. `tracks` are the load-order indices of every track
// stored in that file (several for CUE sheets and other multi-subsong files).
struct FileOps {
    std::string path;
    std::vector<size_t> tracks;
    std::vector<Op> ops;
};

struct FileGroup {
    std::string path;
    std::vector<size_t> tracks;
};
// Tracks grouped by physical file, in order of first appearance.
std::vector<FileGroup> group_by_file(const std::vector<std::string>& trackPaths);

class Table {
public:
    void load(const std::vector<TrackArt>& tracks);  // replaces everything, drops staged edits
    void clear();
    bool loaded() const { return m_loaded; }
    size_t trackCount() const { return m_tracks.size(); }
    const Slot& slot(size_t type) const { return m_slots[type]; }
    const TrackArt& track(size_t i) const { return m_tracks[i]; }

    // `fallback` fills in dimensions the header parser could not read (TIFF, HEIF, ...).
    Details details(size_t type, Dimensions fallback = {}) const;
    // What VoiceOver reads for the row's picture: "Front Cover, 600×600 PNG, 302 KB" (", pending" while
    // staged), "Back Cover, multiple values", "Disc, not present".
    std::string description(size_t type, Dimensions fallback = {}) const;

    // Staging. Each returns false when nothing changed (same picture again, removing nothing...).
    bool stageSet(size_t type, Picture picture);
    bool stageRemove(size_t type);
    bool unstage(size_t type);
    void discard();
    // The staged edits were written to every file: they become the loaded state (no longer pending),
    // so a later reload, or a reload that was already running, starts from a clean table.
    void commit();
    bool dirty() const;
    std::vector<size_t> pendingTypes() const;

    // The per-file work for the staged edits. Files that already match are left out, and only the
    // staged types are ever touched. `trackPaths` is indexed like the loaded tracks.
    std::vector<FileOps> plan(const std::vector<std::string>& trackPaths) const;

private:
    std::vector<TrackArt> m_tracks;
    std::array<Slot, TypeCount> m_slots;
    bool m_loaded = false;
};

// "Front Cover, Back Cover"
std::string type_list(const std::vector<size_t>& types);

// Write errors (location, message) as they are reported: one entry per track for tags (every subsong
// of a CUE image or multi-subsong file adds its own) and one per file for pictures.
using Errors = std::vector<std::pair<std::string, std::string>>;
// How many physical files the errors are about: distinct non-empty locations ("file://" ignored).
size_t failed_files(const Errors& errors);
// The errors with exact repeats (same location and message) left out, first appearance kept.
Errors unique_errors(const Errors& errors);

// Makes identical pictures share one buffer: the tracks of an album usually carry the same cover,
// and a large selection would otherwise hold one copy per file.
class PictureCache {
public:
    Picture intern(Picture p);
    size_t size() const;

private:
    std::unordered_map<size_t, std::vector<Picture>> m_byHash;
};

}
