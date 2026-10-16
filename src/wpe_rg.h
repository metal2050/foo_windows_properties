#pragma once
// Pure model of the Properties > ReplayGain page: the ReplayGain values of N tracks merged into four
// rows, staged edits, parsing/formatting like foobar2000, and what to write. No SDK, no Cocoa.

#include <array>
#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace wpe::rg {

// The rows of the page, in the order foobar2000 for Windows shows them.
enum Field : size_t { TrackGain = 0, TrackPeak, AlbumGain, AlbumPeak, FieldCount };
const char* field_label(size_t field);  // "Track Gain", "Track Peak", "Album Gain", "Album Peak"
inline bool is_gain(size_t field) { return field == TrackGain || field == AlbumGain; }

// A value as foobar2000 stores it (replaygain_info keeps floats); nullopt = not set.
using Value = std::optional<float>;

struct Info {
    std::array<Value, FieldCount> values{};
    bool operator==(const Info&) const = default;
};

// foobar2000's own text: replaygain_info::g_format_gain ("-6.54 dB", "+1.20 dB", "0.00 dB") and
// g_format_peak ("0.987654"). Both round half up at 2 resp. 6 decimals, like pfc::float_to_string.
std::string format_gain(float gain);
std::string format_peak(float peak);
std::string format(size_t field, const Value& v);  // "" when not set

// Typed text: optional sign, digits with '.' or ',' as the decimal separator, and for gains an
// optional "dB" suffix ("+1.2", "-6.54 dB", "-6,54"). Empty text means "not set". Peaks cannot be
// negative; values must be finite and gains within ±999 dB.
enum class Parse { Ok, Empty, Invalid };
Parse parse(size_t field, std::string_view text, float& out);
std::string invalid_message(size_t field, std::string_view text);

// One staged change: every track gets `value` (nullopt removes the field).
struct Op {
    bool touched = false;
    Value value;
    bool operator==(const Op&) const = default;
};

struct Plan {
    std::array<Op, FieldCount> ops{};
    bool empty() const;
    size_t fieldCount() const;
    bool operator==(const Plan&) const = default;
};

// Applies the touched fields only; returns true when `info` changed.
bool apply(const Plan& plan, Info& info);

struct Display {
    std::string text;
    bool mixed = false;  // the tracks disagree: text starts with «multiple values»
};

enum class Edit { Unchanged, Changed, Invalid };

class Table {
public:
    void load(std::vector<Info> tracks);

    size_t trackCount() const { return m_tracks.size(); }
    const Info& loaded(size_t track) const { return m_tracks[track]; }
    Value current(size_t field, size_t track) const;

    Display display(size_t field) const;
    // The text an editor starts with: the common value, or the tracks' distinct values joined by "; ".
    std::string editText(size_t field) const;

    // Text left as editText() keeps every track's own value. Anything else must parse: it then sets
    // that value on every track (empty text removes the field). Invalid text changes nothing.
    Edit setText(size_t field, std::string_view text);
    bool clear(size_t field);

    bool isStaged(size_t field) const { return field < FieldCount && m_staged[field].touched; }
    bool dirty() const;
    Plan plan() const;
    std::vector<size_t> changedTracks() const;
    std::vector<size_t> changedFields() const;
    // "Track Gain: -6.54 dB" lines (the displayed text, «multiple values» included).
    std::string copyText(const std::vector<size_t>& fields) const;
    void discard();

private:
    bool stage(size_t field, const Value& v);

    std::vector<Info> m_tracks;
    std::array<Op, FieldCount> m_staged{};
};

}
