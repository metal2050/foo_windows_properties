#include "wpe_art.h"

#include <algorithm>
#include <cstring>
#include <functional>
#include <iterator>
#include <string_view>
#include <unordered_map>

namespace wpe::art {

const char* const kNotPresent = "\xC2\xAB" "not present" "\xC2\xBB";
const char* const kMultipleValues = "\xC2\xAB" "multiple values" "\xC2\xBB";

namespace {

const char* const kLabels[TypeCount] = {"Front Cover", "Back Cover", "Artist", "Disc", "Icon"};

uint32_t be16(const uint8_t* p) { return (uint32_t(p[0]) << 8) | p[1]; }
uint32_t be32(const uint8_t* p) { return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3]; }
uint32_t le16(const uint8_t* p) { return uint32_t(p[0]) | (uint32_t(p[1]) << 8); }
uint32_t le24(const uint8_t* p) { return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16); }
uint32_t le32(const uint8_t* p) { return le24(p) | (uint32_t(p[3]) << 24); }

bool starts(const uint8_t* p, size_t n, const char* sig, size_t len, size_t at = 0) {
    return n >= at + len && std::memcmp(p + at, sig, len) == 0;
}

Dimensions jpeg_dimensions(const uint8_t* p, size_t n) {
    size_t i = 2;
    while (i < n) {
        if (p[i] != 0xFF) {
            ++i;  // tolerate garbage between segments
            continue;
        }
        while (i < n && p[i] == 0xFF) ++i;  // fill bytes
        if (i >= n) break;
        const uint8_t marker = p[i++];
        if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;  // no length
        if (marker == 0xD9 || marker == 0xDA) break;  // end of image / start of scan: no frame header found
        if (i + 2 > n) break;
        const size_t len = be16(p + i);
        if (len < 2) break;
        const bool sof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
        if (sof) {
            if (i + 7 > n) break;
            return {be16(p + i + 5), be16(p + i + 3)};
        }
        i += len;
    }
    return {};
}

Dimensions webp_dimensions(const uint8_t* p, size_t n) {
    if (starts(p, n, "VP8 ", 4, 12)) {
        if (n < 30 || p[23] != 0x9D || p[24] != 0x01 || p[25] != 0x2A) return {};
        return {le16(p + 26) & 0x3FFF, le16(p + 28) & 0x3FFF};
    }
    if (starts(p, n, "VP8L", 4, 12)) {
        if (n < 25 || p[20] != 0x2F) return {};
        const uint32_t bits = le32(p + 21);
        return {(bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1};
    }
    if (starts(p, n, "VP8X", 4, 12)) {
        if (n < 30) return {};
        return {le24(p + 24) + 1, le24(p + 27) + 1};
    }
    return {};
}

Dimensions bmp_dimensions(const uint8_t* p, size_t n) {
    if (n < 26) return {};
    const uint32_t header = le32(p + 14);
    if (header == 12) return {le16(p + 18), le16(p + 20)};
    if (header < 16) return {};
    const int32_t w = static_cast<int32_t>(le32(p + 18));
    const int32_t h = static_cast<int32_t>(le32(p + 22));  // negative: top-down rows
    auto mag = [](int32_t v) { return v < 0 ? uint32_t(0) - uint32_t(v) : uint32_t(v); };
    return {mag(w), mag(h)};
}

}

const char* type_label(size_t type) { return type < TypeCount ? kLabels[type] : ""; }

Picture make_picture(Bytes bytes) { return std::make_shared<const Bytes>(std::move(bytes)); }

Picture make_picture(const void* data, size_t size) {
    const auto* p = static_cast<const uint8_t*>(data);
    return make_picture(Bytes(p, p + size));
}

bool same(const Picture& a, const Picture& b) {
    if (a == b) return true;
    if (!a || !b) return false;
    return *a == *b;
}

Format sniff(const uint8_t* p, size_t n) {
    if (n >= 3 && p[0] == 0xFF && p[1] == 0xD8 && p[2] == 0xFF) return Format::JPEG;
    if (starts(p, n, "\x89PNG\r\n\x1A\n", 8)) return Format::PNG;
    if (starts(p, n, "GIF87a", 6) || starts(p, n, "GIF89a", 6)) return Format::GIF;
    if (starts(p, n, "RIFF", 4) && starts(p, n, "WEBP", 4, 8)) return Format::WebP;
    if (starts(p, n, "BM", 2) && n >= 26) return Format::BMP;
    if (starts(p, n, "II*\0", 4) || starts(p, n, "MM\0*", 4)) return Format::TIFF;
    if (starts(p, n, "\0\0\1\0", 4) && n >= 6 && le16(p + 4) > 0) return Format::ICO;
    if (starts(p, n, "ftyp", 4, 4) && n >= 12) {
        // ISO base media: the major brand, then compatible brands up to the end of the ftyp box.
        const size_t box = std::min<size_t>(be32(p), n);
        bool avif = false, heif = false;
        for (size_t at = 8; at + 4 <= box; at += 4) {
            if (at == 12) continue;  // minor version
            if (starts(p, n, "avif", 4, at) || starts(p, n, "avis", 4, at)) avif = true;
            if (starts(p, n, "heic", 4, at) || starts(p, n, "heix", 4, at) || starts(p, n, "hevc", 4, at) ||
                starts(p, n, "hevx", 4, at) || starts(p, n, "heim", 4, at) || starts(p, n, "heis", 4, at) ||
                starts(p, n, "mif1", 4, at) || starts(p, n, "msf1", 4, at))
                heif = true;
        }
        if (avif) return Format::AVIF;
        if (heif) return Format::HEIF;
    }
    return Format::Unknown;
}

const char* format_name(Format f) {
    switch (f) {
    case Format::JPEG: return "JPEG";
    case Format::PNG: return "PNG";
    case Format::GIF: return "GIF";
    case Format::WebP: return "WebP";
    case Format::BMP: return "BMP";
    case Format::TIFF: return "TIFF";
    case Format::ICO: return "ICO";
    case Format::HEIF: return "HEIF";
    case Format::AVIF: return "AVIF";
    case Format::Unknown: break;
    }
    return "";
}

const char* format_extension(Format f) {
    switch (f) {
    case Format::JPEG: return "jpg";
    case Format::PNG: return "png";
    case Format::GIF: return "gif";
    case Format::WebP: return "webp";
    case Format::BMP: return "bmp";
    case Format::TIFF: return "tif";
    case Format::ICO: return "ico";
    case Format::HEIF: return "heic";
    case Format::AVIF: return "avif";
    case Format::Unknown: break;
    }
    return "bin";
}

const char* format_uti(Format f) {
    switch (f) {
    case Format::JPEG: return "public.jpeg";
    case Format::PNG: return "public.png";
    case Format::GIF: return "com.compuserve.gif";
    case Format::WebP: return "org.webmproject.webp";
    case Format::BMP: return "com.microsoft.bmp";
    case Format::TIFF: return "public.tiff";
    case Format::ICO: return "com.microsoft.ico";
    case Format::HEIF: return "public.heic";
    case Format::AVIF: return "public.avif";
    case Format::Unknown: break;
    }
    return "";
}

bool attachable(Format f) {
    return f == Format::JPEG || f == Format::PNG || f == Format::GIF || f == Format::WebP || f == Format::BMP;
}

Conversion conversion_for(Format source, bool hasAlpha) {
    if (attachable(source)) return Conversion::Keep;
    if ((source == Format::HEIF || source == Format::AVIF) && !hasAlpha) return Conversion::JPEG;
    return Conversion::PNG;
}

std::string file_name(size_t type, Format f) {
    return std::string(type < TypeCount ? kLabels[type] : "Picture") + "." + format_extension(f);
}

Dimensions dimensions(const uint8_t* p, size_t n) {
    switch (sniff(p, n)) {
    case Format::JPEG: return jpeg_dimensions(p, n);
    case Format::PNG:
        if (n < 24 || !starts(p, n, "IHDR", 4, 12)) return {};
        return {be32(p + 16), be32(p + 20)};
    case Format::GIF:
        if (n < 10) return {};
        return {le16(p + 6), le16(p + 8)};
    case Format::WebP: return webp_dimensions(p, n);
    case Format::BMP: return bmp_dimensions(p, n);
    case Format::ICO:
        if (n < 8) return {};
        return {p[6] ? uint32_t(p[6]) : 256u, p[7] ? uint32_t(p[7]) : 256u};
    default: break;
    }
    return {};
}

std::string size_text(uint64_t bytes) {
    constexpr uint64_t kKB = 1024, kMB = kKB * kKB;
    if (bytes < kMB) return std::to_string((bytes + kKB - 1) / kKB) + " KB";
    static const char* const units[] = {"MB", "GB", "TB"};
    uint64_t scale = kMB;
    size_t unit = 0;
    while (unit + 1 < std::size(units) && bytes / 1024 >= scale) {
        scale *= 1024;
        ++unit;
    }
    // Three significant digits, truncated, trailing zeros dropped (pfc::format_file_size_short).
    std::string out = std::to_string(bytes / scale);
    if (out.size() < 3) {
        size_t digits = 3 - out.size();
        uint64_t mask = 1;
        for (size_t i = 0; i < digits; ++i) mask *= 10;
        uint64_t rest = (bytes % scale) * mask / scale;
        while (digits > 0 && rest % 10 == 0) {
            rest /= 10;
            --digits;
        }
        if (digits > 0) {
            std::string r = std::to_string(rest);
            if (r.size() < digits) r.insert(0, digits - r.size(), '0');
            out += "." + r;
        }
    }
    return out + " " + units[unit];
}

std::string dimensions_text(Dimensions d) {
    if (!d.valid()) return {};
    return std::to_string(d.width) + "x" + std::to_string(d.height);
}

State Slot::state() const {
    switch (pending) {
    case Pending::Set: return State::Present;
    case Pending::Remove: return State::Absent;
    case Pending::None: break;
    }
    return loaded;
}

Picture Slot::picture() const {
    switch (pending) {
    case Pending::Set: return pendingPicture;
    case Pending::Remove: return nullptr;
    case Pending::None: break;
    }
    return loaded == State::Present ? loadedPicture : nullptr;
}

std::vector<FileGroup> group_by_file(const std::vector<std::string>& trackPaths) {
    std::vector<FileGroup> out;
    std::unordered_map<std::string, size_t> index;
    for (size_t t = 0; t < trackPaths.size(); ++t) {
        auto [it, fresh] = index.emplace(trackPaths[t], out.size());
        if (fresh) out.push_back({trackPaths[t], {}});
        out[it->second].tracks.push_back(t);
    }
    return out;
}

void Table::clear() {
    m_tracks.clear();
    m_slots = {};
    m_loaded = false;
}

void Table::load(const std::vector<TrackArt>& tracks) {
    m_tracks = tracks;
    m_slots = {};
    m_loaded = true;
    for (size_t type = 0; type < TypeCount; ++type) {
        Slot& s = m_slots[type];
        if (m_tracks.empty()) continue;
        const Picture& first = m_tracks[0].pictures[type];
        bool mixed = false;
        for (size_t t = 1; t < m_tracks.size() && !mixed; ++t)
            if (!same(m_tracks[t].pictures[type], first)) mixed = true;
        if (mixed) {
            s.loaded = State::Mixed;
        } else if (first) {
            s.loaded = State::Present;
            s.loadedPicture = first;
        }
    }
}

Details Table::details(size_t type, Dimensions fallback) const {
    Details d;
    if (type >= TypeCount) return d;
    const Slot& s = m_slots[type];
    d.pending = s.isPending();
    switch (s.state()) {
    case State::Absent:
        d.absent = true;
        d.lines.push_back(kNotPresent);
        break;
    case State::Mixed:
        d.mixed = true;
        d.lines.push_back(kMultipleValues);
        break;
    case State::Present: {
        const Picture p = s.picture();
        const Bytes empty;
        const Bytes& b = p ? *p : empty;
        d.lines.push_back(size_text(b.size()));
        Dimensions dim = dimensions(b);
        if (!dim.valid()) dim = fallback;
        if (dim.valid()) d.lines.push_back(dimensions_text(dim));
        if (const Format f = sniff(b); f != Format::Unknown) d.lines.push_back(format_name(f));
        break;
    }
    }
    return d;
}

std::string Table::description(size_t type, Dimensions fallback) const {
    if (type >= TypeCount) return std::string();
    std::string out = kLabels[type];
    const Slot& s = m_slots[type];
    switch (s.state()) {
    case State::Absent: out += ", not present"; break;
    case State::Mixed: out += ", multiple values"; break;
    case State::Present: {
        const Picture p = s.picture();
        const Bytes empty;
        const Bytes& b = p ? *p : empty;
        Dimensions dim = dimensions(b);
        if (!dim.valid()) dim = fallback;
        std::string what;
        if (dim.valid()) what = std::to_string(dim.width) + "\xC3\x97" + std::to_string(dim.height);  // ×
        if (const Format f = sniff(b); f != Format::Unknown) what += (what.empty() ? "" : " ") + std::string(format_name(f));
        if (!what.empty()) out += ", " + what;
        out += ", " + size_text(b.size());
        break;
    }
    }
    if (s.isPending()) out += ", pending";
    return out;
}

bool Table::stageSet(size_t type, Picture picture) {
    if (type >= TypeCount || !picture || !m_loaded) return false;
    Slot& s = m_slots[type];
    if (s.loaded == State::Present && same(s.loadedPicture, picture)) return unstage(type);
    if (s.pending == Slot::Pending::Set && same(s.pendingPicture, picture)) return false;
    s.pending = Slot::Pending::Set;
    s.pendingPicture = std::move(picture);
    return true;
}

bool Table::stageRemove(size_t type) {
    if (type >= TypeCount || !m_loaded) return false;
    Slot& s = m_slots[type];
    if (s.loaded == State::Absent) return unstage(type);
    if (s.pending == Slot::Pending::Remove) return false;
    s.pending = Slot::Pending::Remove;
    s.pendingPicture.reset();
    return true;
}

bool Table::unstage(size_t type) {
    if (type >= TypeCount) return false;
    Slot& s = m_slots[type];
    if (!s.isPending()) return false;
    s.pending = Slot::Pending::None;
    s.pendingPicture.reset();
    return true;
}

void Table::discard() {
    for (size_t type = 0; type < TypeCount; ++type) unstage(type);
}

void Table::commit() {
    if (!m_loaded || !dirty()) return;
    std::vector<TrackArt> tracks = m_tracks;
    for (size_t type = 0; type < TypeCount; ++type) {
        const Slot& s = m_slots[type];
        if (!s.isPending()) continue;
        const Picture p = s.pending == Slot::Pending::Set ? s.pendingPicture : nullptr;
        for (auto& t : tracks) t.pictures[type] = p;
    }
    load(tracks);
}

bool Table::dirty() const {
    for (auto& s : m_slots)
        if (s.isPending()) return true;
    return false;
}

std::vector<size_t> Table::pendingTypes() const {
    std::vector<size_t> out;
    for (size_t type = 0; type < TypeCount; ++type)
        if (m_slots[type].isPending()) out.push_back(type);
    return out;
}

std::vector<FileOps> Table::plan(const std::vector<std::string>& trackPaths) const {
    std::vector<FileOps> out;
    const auto types = pendingTypes();
    if (!m_loaded || types.empty()) return out;
    for (auto& g : group_by_file(trackPaths)) {
        FileOps f{g.path, g.tracks, {}};
        for (size_t type : types) {
            const Slot& s = m_slots[type];
            bool needed = false;
            for (size_t t : g.tracks) {
                if (t >= m_tracks.size()) continue;
                const Picture& now = m_tracks[t].pictures[type];
                if (s.pending == Slot::Pending::Set ? !same(now, s.pendingPicture) : now != nullptr) needed = true;
            }
            if (needed) f.ops.push_back({type, s.pending == Slot::Pending::Set ? s.pendingPicture : nullptr});
        }
        if (!f.ops.empty()) out.push_back(std::move(f));
    }
    return out;
}

Picture PictureCache::intern(Picture p) {
    if (!p) return p;
    const size_t h = std::hash<std::string_view>()(std::string_view(reinterpret_cast<const char*>(p->data()), p->size()));
    auto& bucket = m_byHash[h];
    for (auto& known : bucket)
        if (same(known, p)) return known;
    bucket.push_back(p);
    return p;
}

size_t PictureCache::size() const {
    size_t n = 0;
    for (auto& [h, bucket] : m_byHash) n += bucket.size();
    return n;
}

std::string type_list(const std::vector<size_t>& types) {
    std::string out;
    for (size_t type : types) {
        if (!out.empty()) out += ", ";
        out += type_label(type);
    }
    return out;
}

namespace {
std::string_view without_scheme(std::string_view location) {
    constexpr std::string_view kFile = "file://";
    if (location.substr(0, kFile.size()) == kFile) location.remove_prefix(kFile.size());
    return location;
}
}

size_t failed_files(const Errors& errors) {
    std::vector<std::string_view> seen;
    for (auto& e : errors) {
        const std::string_view loc = without_scheme(e.first);
        if (loc.empty() || std::find(seen.begin(), seen.end(), loc) != seen.end()) continue;
        seen.push_back(loc);
    }
    return seen.size();
}

Errors unique_errors(const Errors& errors) {
    Errors out;
    for (auto& e : errors)
        if (std::find(out.begin(), out.end(), e) == out.end()) out.push_back(e);
    return out;
}

}
