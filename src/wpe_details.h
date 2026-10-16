#pragma once
// Pure model of the Properties > Details page: what the track_property_provider services report,
// grouped and ordered the way foobar2000 shows it. No SDK, no Cocoa.

#include <cstddef>
#include <functional>
#include <string>
#include <string_view>
#include <vector>

namespace wpe::details {

// One track_property_callback::set_property() call.
struct Entry {
    std::string group;
    double priority = 0;
    std::string name;
    std::string value;
};

// A row of the page: a section header (the group name) or a Name | Value line.
struct Line {
    bool header = false;
    std::string group;
    std::string name;  // header: the group name
    std::string value;
    bool operator==(const Line&) const = default;
};

// The groups the host's own provider fills, in this order; other groups follow sorted by name
// (track_property_callback: "non-standard groups are sorted alphabetically").
extern const char* const kStandardGroups[3];  // "Location", "General", "ReplayGain"
extern const char* const kGeneralGroup;       // "General"

// Groups the entries: standard groups first, the rest by name; inside a group by sort priority,
// then by name. A later entry with the same group and name replaces an earlier one. Entries with an
// empty name are dropped; a group with no entries has no header.
std::vector<Line> group_lines(const std::vector<Entry>& entries);

// "Name: Value" lines for the given rows (headers are skipped).
std::string copy_text(const std::vector<Line>& lines, const std::vector<size_t>& rows);

// Technical info fields of the selected tracks, merged by name (case-insensitive, first spelling kept).
struct TechField {
    std::string name;
    std::vector<std::string> values;  // one per track that has the field, in track order
};
std::vector<TechField> merge_tech(const std::vector<std::vector<std::pair<std::string, std::string>>>& tracks);

// How foobar2000 names an unknown technical info field: "MP3_STEREO_MODE" -> "Mp3 stereo mode".
std::string tech_label(std::string_view field);

// Adds a "General" entry for each technical info field that no provider claims (is_our_tech_info)
// and that no provider already listed under that name. Returns the number of entries added.
size_t add_unclaimed(std::vector<Entry>& entries, const std::vector<TechField>& fields,
                     const std::function<bool(const std::string&)>& claimed);

}
