#pragma once
// Pure C++ model of the Windows-style Properties > Metadata table. No SDK, no Cocoa.

#include "wpe_rg.h"

#include <cstddef>
#include <functional>
#include <string>
#include <string_view>
#include <vector>

namespace wpe {

using Values = std::vector<std::string>;
struct FieldValues {
    std::string name;
    Values values;
};
using TrackFields = std::vector<FieldValues>;

constexpr size_t npos = static_cast<size_t>(-1);

std::string upper_ascii(std::string_view s);
bool iequals(std::string_view a, std::string_view b);
int icompare(std::string_view a, std::string_view b);
std::string trim(std::string_view s);
std::string join(const Values& v);
Values split_multi(std::string_view text);
bool has_newline(std::string_view s);
std::string single_line(std::string_view s);
std::string capitalize_ascii(const std::string& s);

// The Properties window's title, Mac style: "Properties — <title>" for one track (its title display
// text), "Properties — N Tracks" for any other count.
std::string window_title(size_t tracks, std::string_view title);
// The POSIX path of a foobar2000 location on the local file system ("file:///Music/a.flac" ->
// "/Music/a.flac"); empty for any other location (archives, streams, CD tracks, ...).
std::string local_file_path(std::string_view location);

// Typed text -> values: multi-value fields are split on ';' (trimmed, empty parts dropped); any other
// field takes the text as one value. Blank text is no value (the field is removed).
Values parse_value_text(std::string_view text, bool multiValue);

extern const char* const kMultipleValues;
// The host's "Common value" text when the tracks differ (FB2KPropertiesEditMulti).
extern const char* const kDifferentValues;
extern const char* const kDefaultStandardFields;
extern const char* const kDefaultMultiLineFields;
extern const char* const kDefaultMultiValueFields;

struct StandardField {
    std::string label;
    std::string field;
};

std::vector<StandardField> parse_standard_fields(std::string_view spec);
std::vector<std::string> parse_field_list(std::string_view spec);

struct Config {
    std::vector<StandardField> standard;
    std::vector<std::string> multiValue;
    std::vector<std::string> multiLine;

    static Config defaults();
    static Config parse(std::string_view standard, std::string_view multiLine, std::string_view multiValue);
    bool isMultiValue(std::string_view field) const;
    bool isMultiLine(std::string_view field) const;
};

enum class EditState { Untouched, SetAll, SetPerTrack };

struct Row {
    std::string label;
    std::string field;
    std::string origField;
    bool standard = false;
    bool loadedMultiValue = false;
    std::vector<Values> orig;
    EditState state = EditState::Untouched;
    Values all;
    std::vector<Values> perTrack;

    bool isNew() const { return origField.empty(); }
    bool renamed() const { return !origField.empty() && field != origField; }
    const Values& current(size_t track) const;
};

struct Display {
    std::string text;
    bool mixed = false;
};

struct Op {
    enum Kind { Remove, Move, Set };
    Kind kind = Set;
    std::string from;
    std::string to;
    bool explicitValues = false;
    bool perTrack = false;
    Values all;
    std::vector<Values> tracks;
    // perTrack only: true for a track whose staged value is the one it was loaded with. That track's
    // field is left as the file has it when the tags are written (a Move just moves it), so a track
    // the user did not change never gets a stale snapshot of its value written back.
    std::vector<bool> keep;
    const Values& values(size_t track) const;
    bool keeps(size_t track) const { return perTrack && track < keep.size() && keep[track]; }
};

struct Plan {
    std::vector<Op> ops;
    rg::Plan rg;  // ReplayGain changes, written together with the tags (not applied by apply() below)
    bool empty() const { return ops.empty() && rg.empty(); }
};

class FieldStore {
public:
    virtual ~FieldStore() = default;
    virtual bool has(const std::string& name) const = 0;
    virtual Values get(const std::string& name) const = 0;
    virtual void remove(const std::string& name) = 0;
    virtual void add(const std::string& name, const std::string& value) = 0;
};

class MemoryStore : public FieldStore {
public:
    MemoryStore() = default;
    explicit MemoryStore(TrackFields f) : fields(std::move(f)) {}
    bool has(const std::string& name) const override;
    Values get(const std::string& name) const override;
    void remove(const std::string& name) override;
    void add(const std::string& name, const std::string& value) override;
    TrackFields fields;
};

bool apply(const Plan& plan, size_t track, FieldStore& store);

enum class NameResult { Ok, Unchanged, Invalid, Duplicate, NotAllowed };
bool valid_field_name(std::string_view name);

class Table {
public:
    void load(const std::vector<TrackFields>& tracks, const Config& cfg);

    size_t trackCount() const { return m_tracks; }
    size_t size() const { return m_rows.size(); }
    const Row& row(size_t i) const { return m_rows[i]; }
    const Config& config() const { return m_cfg; }
    size_t find(std::string_view field) const;

    Display display(size_t row) const;
    std::string editText(size_t row) const;
    bool isMultiline(size_t row) const;
    bool usesMultiValue(size_t row) const;
    Values parseText(size_t row, std::string_view text) const;

    bool setText(size_t row, std::string_view text);
    bool setValues(size_t row, const Values& values);
    bool setPerTrack(size_t row, std::vector<Values> values);
    NameResult rename(size_t row, std::string_view name, size_t* existing = nullptr);

    size_t addRow();
    NameResult nameNewRow(size_t row, std::string_view name, size_t* resultRow);
    bool isPendingName(size_t row) const { return row < m_rows.size() && m_rows[row].field.empty(); }
    void discardPendingRow(size_t row);

    size_t remove(std::vector<size_t> rows);
    size_t capitalize(const std::vector<size_t>& rows, const std::function<std::string(const std::string&)>& fn);
    bool autoTrackNumber();

    // Tools menu (all of them only stage changes).
    std::vector<size_t> fieldRows() const;  // every row that names a field (not a new row still being named)
    std::vector<size_t> valueRows() const;  // field rows with a value on at least one track ("Copy all fields")
    size_t removeAll();                     // removes every field; standard rows are cleared
    // Sets `field` on each track from one text per track, parsed like typed text (multi-value fields
    // are split on ';'). Adds the row when needed; `row` receives its index. False when nothing changed.
    bool setFormatted(std::string_view field, const std::vector<std::string>& texts, size_t* row = nullptr);

    std::string copyText(const std::vector<size_t>& rows) const;
    bool paste(std::string_view text, const std::vector<size_t>& selected, std::vector<size_t>* touched = nullptr);

    bool dirty() const;
    Plan plan() const;
    std::vector<size_t> changedTracks() const;
    std::vector<std::string> changedFields() const;
    TrackFields loadedFields(size_t track) const;
    // The track's fields with the staged edits applied.
    TrackFields currentFields(size_t track) const;

private:
    size_t ensureRow(const std::string& field);
    void normalize(Row& r) const;
    bool merged(size_t row, std::string& text) const;

    Config m_cfg;
    size_t m_tracks = 0;
    std::vector<Row> m_rows;
    std::vector<Row> m_removed;
};

// The "Edit Value : <field>" sheet: one row's value on each track, as the text the Metadata list would
// show for that track alone (values joined with "; ", empty when absent), edited one track at a time and
// staged back into the table as per-track values.
class PerTrackEdit {
public:
    PerTrackEdit() = default;
    // Starts from the row's staged values (what the list shows now).
    PerTrackEdit(const Table& table, size_t row);

    const std::string& field() const { return m_field; }
    const std::string& label() const { return m_label; }  // as the Name column shows it
    size_t size() const { return m_text.size(); }
    bool multiValue() const { return m_multiValue; }  // ';' separates values
    bool multiline(size_t track) const;              // a multi-line field, or that text has a line break
    const std::string& text(size_t track) const { return m_text[track]; }
    const std::string& original(size_t track) const { return m_orig[track]; }

    bool setText(size_t track, std::string_view text);  // false when the text already is that
    bool changed(size_t track) const;                    // the text differs from the original
    bool dirty() const;
    std::vector<size_t> changedTracks() const;

    // The Common value page, as the host does it: the text every track shares, or kDifferentValues.
    bool allSame() const;
    std::string commonText() const;
    // Gives every track `text`, unless it still is kDifferentValues. False when nothing changed.
    bool setCommon(std::string_view text);

    // The values to stage: a track whose text changed is parsed like typed text (multi-value fields
    // split on ';'); every other track keeps the values it had. A track whose staged value is still the one
    // it was loaded with is marked Op::keep in the plan, so writing never touches that field on it.
    std::vector<Values> values() const;
    // Stages values() on the table's row for field(). False when that changes nothing or the row is gone.
    bool apply(Table& table, size_t* row = nullptr) const;

private:
    std::string m_field;
    std::string m_label;
    bool m_multiValue = false;
    bool m_multiLineField = false;
    std::vector<Values> m_values;  // per track, as staged when the edit started
    std::vector<std::string> m_orig;
    std::vector<std::string> m_text;
};

}
