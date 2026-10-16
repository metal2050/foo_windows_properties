#include "wpe_model.h"

#include <algorithm>
#include <unordered_map>

namespace wpe {

const char* const kMultipleValues = "\xC2\xAB" "multiple values" "\xC2\xBB";
const char* const kDifferentValues = "< different values >";
const char* const kDefaultStandardFields =
    "Artist Name=ARTIST;Track Title=TITLE;Album Title=ALBUM;Date=DATE;Genre=GENRE;Composer=COMPOSER;"
    "Performer=PERFORMER;Album Artist=ALBUM ARTIST;Track Number=TRACKNUMBER;Total Tracks=TOTALTRACKS;"
    "Disc Number=DISCNUMBER;Total Discs=TOTALDISCS;Comment=COMMENT;";
const char* const kDefaultMultiLineFields = "COMMENT;LYRICS;BIOGRAPHY;UNSYNCED LYRICS;UNSYNCEDLYRICS";
const char* const kDefaultMultiValueFields = "ARTIST;ALBUM ARTIST;PRODUCER;COMPOSER;PERFORMER;GENRE;STYLE";

namespace {

char up(char c) { return (c >= 'a' && c <= 'z') ? static_cast<char>(c - 'a' + 'A') : c; }
bool is_space(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f'; }
bool is_word_char(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '\'' || c >= 0x80;
}

std::vector<std::string_view> split(std::string_view s, char sep) {
    std::vector<std::string_view> out;
    size_t start = 0;
    for (;;) {
        const size_t p = s.find(sep, start);
        if (p == std::string_view::npos) {
            out.push_back(s.substr(start));
            break;
        }
        out.push_back(s.substr(start, p - start));
        start = p + 1;
    }
    return out;
}

bool contains_ci(const std::vector<std::string>& list, std::string_view name) {
    for (auto& f : list)
        if (iequals(f, name)) return true;
    return false;
}

std::string distinct_join(const std::vector<std::string>& texts) {
    std::vector<std::string> seen;
    for (auto& t : texts) {
        if (t.empty()) continue;
        if (std::find(seen.begin(), seen.end(), t) == seen.end()) seen.push_back(t);
    }
    std::string out;
    for (size_t i = 0; i < seen.size(); ++i) {
        if (i) out += "; ";
        out += seen[i];
    }
    return out;
}

bool put(FieldStore& store, const std::string& name, const Values& vals) {
    const bool present = store.has(name);
    if (vals.empty()) {
        if (!present) return false;
        store.remove(name);
        return true;
    }
    if (present) {
        if (store.get(name) == vals) return false;
        store.remove(name);
    }
    for (auto& v : vals) store.add(name, v);
    return true;
}

std::string bracket(const std::string& field) { return "<" + upper_ascii(field) + ">"; }

}

std::string upper_ascii(std::string_view s) {
    std::string out(s);
    for (auto& c : out) c = up(c);
    return out;
}

bool iequals(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i)
        if (up(a[i]) != up(b[i])) return false;
    return true;
}

int icompare(std::string_view a, std::string_view b) {
    const size_t n = std::min(a.size(), b.size());
    for (size_t i = 0; i < n; ++i) {
        const unsigned char x = static_cast<unsigned char>(up(a[i])), y = static_cast<unsigned char>(up(b[i]));
        if (x != y) return x < y ? -1 : 1;
    }
    if (a.size() == b.size()) return 0;
    return a.size() < b.size() ? -1 : 1;
}

std::string trim(std::string_view s) {
    size_t b = 0, e = s.size();
    while (b < e && is_space(s[b])) ++b;
    while (e > b && is_space(s[e - 1])) --e;
    return std::string(s.substr(b, e - b));
}

std::string join(const Values& v) {
    std::string out;
    for (size_t i = 0; i < v.size(); ++i) {
        if (i) out += "; ";
        out += v[i];
    }
    return out;
}

Values split_multi(std::string_view text) {
    Values out;
    for (auto part : split(text, ';')) {
        std::string t = trim(part);
        if (!t.empty()) out.push_back(std::move(t));
    }
    return out;
}

bool has_newline(std::string_view s) { return s.find('\n') != std::string_view::npos || s.find('\r') != std::string_view::npos; }

std::string single_line(std::string_view s) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        const char c = s[i];
        if (c == '\r' || c == '\n') {
            if (c == '\r' && i + 1 < s.size() && s[i + 1] == '\n') ++i;
            out += " \xE2\x86\xB5 ";
        } else {
            out += c;
        }
    }
    return out;
}

std::string window_title(size_t tracks, std::string_view title) {
    const std::string prefix = "Properties \xE2\x80\x94 ";  // U+2014 EM DASH
    if (tracks == 1) return prefix + std::string(title);
    return prefix + std::to_string(tracks) + " Tracks";
}

std::string local_file_path(std::string_view location) {
    constexpr std::string_view scheme = "file://";
    if (location.size() <= scheme.size() || location.substr(0, scheme.size()) != scheme) return std::string();
    std::string path(location.substr(scheme.size()));
    return path.front() == '/' ? path : std::string();
}

std::string capitalize_ascii(const std::string& s) {
    std::string out = s;
    bool start = true;
    for (auto& c : out) {
        const unsigned char u = static_cast<unsigned char>(c);
        if (is_word_char(u)) {
            if (start) c = up(c);
            start = false;
        } else {
            start = true;
        }
    }
    return out;
}

std::vector<StandardField> parse_standard_fields(std::string_view spec) {
    std::vector<StandardField> out;
    for (auto part : split(spec, ';')) {
        const size_t eq = part.find('=');
        if (eq == std::string_view::npos) continue;
        StandardField f{trim(part.substr(0, eq)), upper_ascii(trim(part.substr(eq + 1)))};
        if (f.field.empty()) continue;
        if (f.label.empty()) f.label = f.field;
        bool dup = false;
        for (auto& e : out)
            if (iequals(e.field, f.field)) dup = true;
        if (!dup) out.push_back(std::move(f));
    }
    return out;
}

std::vector<std::string> parse_field_list(std::string_view spec) {
    std::vector<std::string> out;
    for (auto part : split(spec, ';')) {
        std::string t = upper_ascii(trim(part));
        if (!t.empty() && !contains_ci(out, t)) out.push_back(std::move(t));
    }
    return out;
}

Config Config::defaults() { return parse(kDefaultStandardFields, kDefaultMultiLineFields, kDefaultMultiValueFields); }

Config Config::parse(std::string_view standard, std::string_view multiLine, std::string_view multiValue) {
    Config c;
    c.standard = parse_standard_fields(standard);
    c.multiLine = parse_field_list(multiLine);
    c.multiValue = parse_field_list(multiValue);
    return c;
}

bool Config::isMultiValue(std::string_view field) const { return contains_ci(multiValue, field); }
bool Config::isMultiLine(std::string_view field) const { return contains_ci(multiLine, field); }

const Values& Row::current(size_t track) const {
    switch (state) {
    case EditState::SetAll: return all;
    case EditState::SetPerTrack: return perTrack[track];
    case EditState::Untouched: break;
    }
    return orig[track];
}

const Values& Op::values(size_t track) const { return perTrack ? tracks[track] : all; }

bool MemoryStore::has(const std::string& name) const {
    for (auto& f : fields)
        if (iequals(f.name, name)) return true;
    return false;
}

Values MemoryStore::get(const std::string& name) const {
    Values out;
    for (auto& f : fields)
        if (iequals(f.name, name)) out.insert(out.end(), f.values.begin(), f.values.end());
    return out;
}

void MemoryStore::remove(const std::string& name) {
    fields.erase(std::remove_if(fields.begin(), fields.end(), [&](const FieldValues& f) { return iequals(f.name, name); }),
                 fields.end());
}

void MemoryStore::add(const std::string& name, const std::string& value) {
    for (auto& f : fields)
        if (iequals(f.name, name)) {
            f.values.push_back(value);
            return;
        }
    fields.push_back({name, {value}});
}

bool apply(const Plan& plan, size_t track, FieldStore& store) {
    bool changed = false;
    for (auto& op : plan.ops)
        if (op.kind == Op::Remove && store.has(op.from)) {
            store.remove(op.from);
            changed = true;
        }

    struct Pending {
        const Op* op;
        bool present;
        bool explicitValues;
        Values vals;
    };
    std::vector<Pending> moves;
    for (auto& op : plan.ops) {
        if (op.kind != Op::Move) continue;
        const bool explicitValues = op.explicitValues && !op.keeps(track);
        Pending p{&op, store.has(op.from), explicitValues, {}};
        if (explicitValues) p.vals = op.values(track);
        else if (p.present) p.vals = store.get(op.from);
        moves.push_back(std::move(p));
    }
    for (auto& p : moves)
        if (p.present && store.has(p.op->from)) {
            store.remove(p.op->from);
            changed = true;
        }
    for (auto& p : moves) {
        if (!p.explicitValues && !p.present) continue;
        if (put(store, p.op->to, p.vals)) changed = true;
    }

    for (auto& op : plan.ops)
        if (op.kind == Op::Set && !op.keeps(track) && put(store, op.to, op.values(track))) changed = true;
    return changed;
}

bool valid_field_name(std::string_view name) {
    if (name.empty()) return false;
    for (char c : name) {
        const unsigned char u = static_cast<unsigned char>(c);
        if (c == '=' || u < 0x20 || u == 0x7F) return false;
    }
    return true;
}

void Table::load(const std::vector<TrackFields>& tracks, const Config& cfg) {
    m_cfg = cfg;
    m_tracks = tracks.size();
    m_rows.clear();
    m_removed.clear();

    std::unordered_map<std::string, size_t> standardIndex;
    for (auto& sf : cfg.standard) {
        Row r;
        r.label = sf.label;
        r.field = r.origField = sf.field;
        r.standard = true;
        r.orig.assign(m_tracks, {});
        standardIndex[upper_ascii(sf.field)] = m_rows.size();
        m_rows.push_back(std::move(r));
    }
    std::vector<bool> standardSeen(m_rows.size(), false);

    std::vector<Row> others;
    std::unordered_map<std::string, size_t> otherIndex;
    for (size_t t = 0; t < m_tracks; ++t) {
        for (auto& fv : tracks[t]) {
            if (fv.name.empty()) continue;
            const std::string key = upper_ascii(fv.name);
            Row* r = nullptr;
            if (auto it = standardIndex.find(key); it != standardIndex.end()) {
                r = &m_rows[it->second];
                if (!standardSeen[it->second]) {
                    standardSeen[it->second] = true;
                    r->field = r->origField = fv.name;
                }
            } else if (auto jt = otherIndex.find(key); jt != otherIndex.end()) {
                r = &others[jt->second];
            } else {
                Row n;
                n.field = n.origField = fv.name;
                n.label = bracket(fv.name);
                n.orig.assign(m_tracks, {});
                otherIndex[key] = others.size();
                others.push_back(std::move(n));
                r = &others.back();
            }
            auto& dst = r->orig[t];
            dst.insert(dst.end(), fv.values.begin(), fv.values.end());
        }
    }
    std::stable_sort(others.begin(), others.end(), [](const Row& a, const Row& b) { return icompare(a.field, b.field) < 0; });
    for (auto& r : others) m_rows.push_back(std::move(r));
    for (auto& r : m_rows)
        for (auto& v : r.orig)
            if (v.size() > 1) r.loadedMultiValue = true;
}

size_t Table::find(std::string_view field) const {
    if (field.empty()) return npos;
    for (size_t i = 0; i < m_rows.size(); ++i)
        if (iequals(m_rows[i].field, field)) return i;
    return npos;
}

// Text shown for a row across all tracks; returns true when the tracks differ. Multi-value rows
// list each distinct value once, so editing a mixed row never duplicates values.
bool Table::merged(size_t row, std::string& text) const {
    const Row& r = m_rows[row];
    text.clear();
    if (m_tracks == 0) return false;
    bool same = true;
    for (size_t t = 1; t < m_tracks && same; ++t)
        if (r.current(t) != r.current(0)) same = false;
    if (same) {
        text = join(r.current(0));
        return false;
    }
    if (usesMultiValue(row)) {
        Values distinct;
        for (size_t t = 0; t < m_tracks; ++t)
            for (auto& v : r.current(t))
                if (std::find(distinct.begin(), distinct.end(), v) == distinct.end()) distinct.push_back(v);
        text = join(distinct);
    } else {
        std::vector<std::string> texts;
        for (size_t t = 0; t < m_tracks; ++t) texts.push_back(join(r.current(t)));
        text = distinct_join(texts);
    }
    return true;
}

Display Table::display(size_t row) const {
    Display d;
    std::string text;
    d.mixed = merged(row, text);
    d.text = d.mixed ? std::string(kMultipleValues) + " " + single_line(text) : single_line(text);
    return d;
}

std::string Table::editText(size_t row) const {
    std::string text;
    merged(row, text);
    return text;
}

bool Table::isMultiline(size_t row) const {
    const Row& r = m_rows[row];
    if (!r.field.empty() && m_cfg.isMultiLine(r.field)) return true;
    for (size_t t = 0; t < m_tracks; ++t)
        for (auto& v : r.current(t))
            if (has_newline(v)) return true;
    return false;
}

bool Table::usesMultiValue(size_t row) const {
    const Row& r = m_rows[row];
    return r.loadedMultiValue || (!r.field.empty() && m_cfg.isMultiValue(r.field));
}

Values parse_value_text(std::string_view text, bool multiValue) {
    if (multiValue) return split_multi(text);
    if (trim(text).empty()) return {};
    return {std::string(text)};
}

Values Table::parseText(size_t row, std::string_view text) const { return parse_value_text(text, usesMultiValue(row)); }

void Table::normalize(Row& r) const {
    if (r.state == EditState::Untouched) return;
    for (size_t t = 0; t < m_tracks; ++t)
        if (r.current(t) != r.orig[t]) return;
    r.state = EditState::Untouched;
    r.all.clear();
    r.perTrack.clear();
}

bool Table::setText(size_t row, std::string_view text) {
    if (row >= m_rows.size() || m_tracks == 0) return false;
    if (text == editText(row)) return false;
    return setValues(row, parseText(row, text));
}

bool Table::setValues(size_t row, const Values& values) {
    if (row >= m_rows.size() || m_tracks == 0) return false;
    Row& r = m_rows[row];
    std::vector<Values> before;
    for (size_t t = 0; t < m_tracks; ++t) before.push_back(r.current(t));
    r.state = EditState::SetAll;
    r.all = values;
    r.perTrack.clear();
    normalize(r);
    for (size_t t = 0; t < m_tracks; ++t)
        if (before[t] != r.current(t)) return true;
    return false;
}

bool Table::setPerTrack(size_t row, std::vector<Values> values) {
    if (row >= m_rows.size() || values.size() != m_tracks || m_tracks == 0) return false;
    Row& r = m_rows[row];
    bool changed = false;
    for (size_t t = 0; t < m_tracks; ++t)
        if (values[t] != r.current(t)) changed = true;
    r.state = EditState::SetPerTrack;
    r.perTrack = std::move(values);
    r.all.clear();
    normalize(r);
    return changed;
}

NameResult Table::rename(size_t row, std::string_view name, size_t* existing) {
    if (row >= m_rows.size()) return NameResult::Invalid;
    Row& r = m_rows[row];
    if (r.standard) return NameResult::NotAllowed;
    const std::string n = upper_ascii(trim(name));
    if (!valid_field_name(n)) return NameResult::Invalid;
    if (n == r.field) return NameResult::Unchanged;
    const size_t idx = find(n);
    if (idx != npos && idx != row) {
        if (existing) *existing = idx;
        return NameResult::Duplicate;
    }
    r.field = n;
    r.label = bracket(n);
    return NameResult::Ok;
}

size_t Table::addRow() {
    Row r;
    r.orig.assign(m_tracks, {});
    m_rows.push_back(std::move(r));
    return m_rows.size() - 1;
}

NameResult Table::nameNewRow(size_t row, std::string_view name, size_t* resultRow) {
    if (resultRow) *resultRow = npos;
    if (!isPendingName(row)) return NameResult::Invalid;
    const std::string n = upper_ascii(trim(name));
    if (!valid_field_name(n)) {
        m_rows.erase(m_rows.begin() + static_cast<std::ptrdiff_t>(row));
        return NameResult::Invalid;
    }
    size_t idx = find(n);
    if (idx != npos) {
        m_rows.erase(m_rows.begin() + static_cast<std::ptrdiff_t>(row));
        if (idx > row) --idx;
        if (resultRow) *resultRow = idx;
        return NameResult::Duplicate;
    }
    m_rows[row].field = n;
    m_rows[row].label = bracket(n);
    if (resultRow) *resultRow = row;
    return NameResult::Ok;
}

void Table::discardPendingRow(size_t row) {
    if (isPendingName(row)) m_rows.erase(m_rows.begin() + static_cast<std::ptrdiff_t>(row));
}

size_t Table::remove(std::vector<size_t> rows) {
    std::sort(rows.begin(), rows.end());
    rows.erase(std::unique(rows.begin(), rows.end()), rows.end());
    size_t count = 0;
    for (auto it = rows.rbegin(); it != rows.rend(); ++it) {
        const size_t i = *it;
        if (i >= m_rows.size()) continue;
        Row& r = m_rows[i];
        if (r.standard) {
            if (setValues(i, {})) ++count;
            continue;
        }
        if (!r.isNew()) m_removed.push_back(std::move(r));
        m_rows.erase(m_rows.begin() + static_cast<std::ptrdiff_t>(i));
        ++count;
    }
    return count;
}

size_t Table::capitalize(const std::vector<size_t>& rows, const std::function<std::string(const std::string&)>& fn) {
    size_t count = 0;
    for (size_t i : rows) {
        if (i >= m_rows.size() || m_rows[i].field.empty()) continue;
        std::vector<Values> next;
        for (size_t t = 0; t < m_tracks; ++t) {
            Values v = m_rows[i].current(t);
            for (auto& s : v) s = fn(s);
            next.push_back(std::move(v));
        }
        if (setPerTrack(i, std::move(next))) ++count;
    }
    return count;
}

size_t Table::ensureRow(const std::string& field) {
    const size_t idx = find(field);
    if (idx != npos) return idx;
    Row r;
    r.field = field;
    r.label = bracket(field);
    r.orig.assign(m_tracks, {});
    m_rows.push_back(std::move(r));
    return m_rows.size() - 1;
}

bool Table::autoTrackNumber() {
    if (m_tracks == 0) return false;
    const size_t num = ensureRow("TRACKNUMBER");
    std::vector<Values> numbers;
    for (size_t t = 0; t < m_tracks; ++t) numbers.push_back({std::to_string(t + 1)});
    bool changed = setPerTrack(num, std::move(numbers));
    const size_t total = ensureRow("TOTALTRACKS");
    if (setValues(total, {std::to_string(m_tracks)})) changed = true;
    return changed;
}

// One FIELD=value line per row. Continuation lines of multi-line values start with a tab, and rows
// whose tracks differ are marked so that pasting them never overwrites every track with the merged text.
std::string Table::copyText(const std::vector<size_t>& rows) const {
    std::string out;
    for (size_t i : rows) {
        if (i >= m_rows.size() || m_rows[i].field.empty()) continue;
        std::string text;
        const bool mixed = merged(i, text);
        if (!out.empty()) out += "\n";
        out += m_rows[i].field + "=";
        if (mixed) out += std::string(kMultipleValues) + " ";
        for (char c : text) {
            out += c;
            if (c == '\n') out += '\t';
        }
    }
    return out;
}

namespace {

// Pasted names must look like tag names, so ordinary text such as a URL with "?v=" stays a value.
bool looks_like_tag_name(std::string_view name) {
    if (!valid_field_name(name)) return false;
    for (char c : name) {
        const unsigned char u = static_cast<unsigned char>(c);
        const bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || u >= 0x80 ||
                        std::string_view(" _-.+#&'()[]").find(c) != std::string_view::npos;
        if (!ok) return false;
    }
    return true;
}

bool parse_field_line(const std::string& line, std::string& name, size_t& eq) {
    eq = line.find('=');
    if (eq == std::string::npos || eq == 0 || is_space(line[0])) return false;
    name = upper_ascii(trim(line.substr(0, eq)));
    return looks_like_tag_name(name);
}

}

bool Table::paste(std::string_view text, const std::vector<size_t>& selected, std::vector<size_t>* touched) {
    struct Group {
        std::string name;
        Values raw;
        bool mixed = false;
    };
    std::vector<Group> groups;
    std::vector<std::string> lines;
    for (auto lineView : split(text, '\n')) {
        std::string line(lineView);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        lines.push_back(std::move(line));
    }
    bool fieldMode = false;
    for (auto& line : lines) {
        if (trim(line).empty()) continue;
        std::string name;
        size_t eq = 0;
        fieldMode = parse_field_line(line, name, eq);
        break;
    }
    if (fieldMode) {
        size_t last = npos;
        for (auto& line : lines) {
            std::string name;
            size_t eq = 0;
            if (parse_field_line(line, name, eq)) {
                last = npos;
                for (size_t g = 0; g < groups.size(); ++g)
                    if (iequals(groups[g].name, name)) last = g;
                if (last == npos) {
                    groups.push_back({name, {}, false});
                    last = groups.size() - 1;
                }
                std::string value = line.substr(eq + 1);
                if (value.rfind(kMultipleValues, 0) == 0) groups[last].mixed = true;
                groups[last].raw.push_back(std::move(value));
            } else if (last != npos) {
                groups[last].raw.back() += "\n" + (!line.empty() && line[0] == '\t' ? line.substr(1) : line);
            }
        }
    }
    if (!fieldMode) {
        if (selected.size() != 1 || selected[0] >= m_rows.size() || m_rows[selected[0]].field.empty()) return false;
        std::string t(text);
        while (!t.empty() && (t.back() == '\n' || t.back() == '\r')) t.pop_back();
        const bool changed = setText(selected[0], t);
        if (changed && touched) touched->push_back(selected[0]);
        return changed;
    }
    bool changed = false;
    for (auto& g : groups) {
        if (g.mixed) continue;
        const size_t idx = ensureRow(g.name);
        Values vals;
        if (usesMultiValue(idx)) {
            for (auto& v : g.raw) {
                Values parts = split_multi(v);
                vals.insert(vals.end(), parts.begin(), parts.end());
            }
        } else {
            for (auto& v : g.raw)
                if (!trim(v).empty()) vals.push_back(v);
        }
        if (setValues(idx, vals)) changed = true;
        if (touched) touched->push_back(idx);
    }
    return changed;
}

bool Table::dirty() const {
    if (!m_removed.empty()) return true;
    for (auto& r : m_rows) {
        if (r.field.empty()) continue;
        if (r.renamed() || r.state != EditState::Untouched) return true;
    }
    return false;
}

Plan Table::plan() const {
    Plan p;
    for (auto& r : m_removed) {
        Op op;
        op.kind = Op::Remove;
        op.from = r.origField;
        p.ops.push_back(std::move(op));
    }
    auto fill = [](Op& op, const Row& r) {
        op.perTrack = r.state == EditState::SetPerTrack;
        if (op.perTrack) {
            op.tracks = r.perTrack;
            op.keep.resize(op.tracks.size());
            for (size_t t = 0; t < op.tracks.size(); ++t) op.keep[t] = t < r.orig.size() && op.tracks[t] == r.orig[t];
        } else {
            op.all = r.all;
        }
    };
    for (auto& r : m_rows) {
        if (r.field.empty()) continue;
        if (r.isNew()) {
            if (r.state == EditState::Untouched) continue;
            Op op;
            op.kind = Op::Set;
            op.to = r.field;
            fill(op, r);
            p.ops.push_back(std::move(op));
        } else if (r.renamed()) {
            Op op;
            op.kind = Op::Move;
            op.from = r.origField;
            op.to = r.field;
            op.explicitValues = r.state != EditState::Untouched;
            if (op.explicitValues) fill(op, r);
            p.ops.push_back(std::move(op));
        } else if (r.state != EditState::Untouched) {
            Op op;
            op.kind = Op::Set;
            op.to = r.field;
            fill(op, r);
            p.ops.push_back(std::move(op));
        }
    }
    return p;
}

std::vector<size_t> Table::fieldRows() const {
    std::vector<size_t> out;
    for (size_t i = 0; i < m_rows.size(); ++i)
        if (!m_rows[i].field.empty()) out.push_back(i);
    return out;
}

std::vector<size_t> Table::valueRows() const {
    std::vector<size_t> out;
    for (size_t i : fieldRows())
        for (size_t t = 0; t < m_tracks; ++t)
            if (!m_rows[i].current(t).empty()) {
                out.push_back(i);
                break;
            }
    return out;
}

size_t Table::removeAll() { return remove(fieldRows()); }

bool Table::setFormatted(std::string_view field, const std::vector<std::string>& texts, size_t* row) {
    if (row) *row = npos;
    const std::string name = upper_ascii(trim(field));
    if (!valid_field_name(name) || texts.size() != m_tracks || m_tracks == 0) return false;
    const size_t idx = ensureRow(name);
    if (row) *row = idx;
    std::vector<Values> values;
    values.reserve(m_tracks);
    for (auto& t : texts) values.push_back(parseText(idx, t));
    return setPerTrack(idx, std::move(values));
}

TrackFields Table::currentFields(size_t track) const {
    MemoryStore s(loadedFields(track));
    apply(plan(), track, s);
    return s.fields;
}

TrackFields Table::loadedFields(size_t track) const {
    TrackFields out;
    auto take = [&](const Row& r) {
        if (r.isNew() || track >= r.orig.size() || r.orig[track].empty()) return;
        out.push_back({r.origField, r.orig[track]});
    };
    for (auto& r : m_rows) take(r);
    for (auto& r : m_removed) take(r);
    return out;
}

std::vector<size_t> Table::changedTracks() const {
    std::vector<size_t> out;
    const Plan p = plan();
    if (p.empty()) return out;
    for (size_t t = 0; t < m_tracks; ++t) {
        MemoryStore s(loadedFields(t));
        if (apply(p, t, s)) out.push_back(t);
    }
    return out;
}

std::vector<std::string> Table::changedFields() const {
    std::vector<std::string> out;
    auto add = [&](const std::string& name) {
        if (name.empty()) return;
        for (auto& e : out)
            if (iequals(e, name)) return;
        out.push_back(upper_ascii(name));
    };
    for (auto& op : plan().ops) {
        if (op.kind != Op::Set) add(op.from);
        if (op.kind != Op::Remove) add(op.to);
    }
    return out;
}

PerTrackEdit::PerTrackEdit(const Table& table, size_t row) {
    if (row >= table.size()) return;
    const Row& r = table.row(row);
    m_field = r.field;
    m_label = r.label;
    m_multiValue = table.usesMultiValue(row);
    m_multiLineField = !r.field.empty() && table.config().isMultiLine(r.field);
    for (size_t t = 0; t < table.trackCount(); ++t) {
        m_values.push_back(r.current(t));
        m_orig.push_back(join(m_values.back()));
    }
    m_text = m_orig;
}

bool PerTrackEdit::multiline(size_t track) const { return m_multiLineField || (track < size() && has_newline(m_text[track])); }

bool PerTrackEdit::setText(size_t track, std::string_view text) {
    if (track >= size() || m_text[track] == text) return false;
    m_text[track] = std::string(text);
    return true;
}

bool PerTrackEdit::changed(size_t track) const { return track < size() && m_text[track] != m_orig[track]; }

bool PerTrackEdit::dirty() const { return !changedTracks().empty(); }

std::vector<size_t> PerTrackEdit::changedTracks() const {
    std::vector<size_t> out;
    for (size_t t = 0; t < size(); ++t)
        if (changed(t)) out.push_back(t);
    return out;
}

bool PerTrackEdit::allSame() const {
    for (size_t t = 1; t < size(); ++t)
        if (m_text[t] != m_text[0]) return false;
    return true;
}

std::string PerTrackEdit::commonText() const {
    if (m_text.empty()) return {};
    return allSame() ? m_text[0] : std::string(kDifferentValues);
}

bool PerTrackEdit::setCommon(std::string_view text) {
    if (text == kDifferentValues) return false;
    bool changed = false;
    for (size_t t = 0; t < size(); ++t)
        if (setText(t, text)) changed = true;
    return changed;
}

std::vector<Values> PerTrackEdit::values() const {
    std::vector<Values> out;
    out.reserve(size());
    for (size_t t = 0; t < size(); ++t) out.push_back(changed(t) ? parse_value_text(m_text[t], m_multiValue) : m_values[t]);
    return out;
}

bool PerTrackEdit::apply(Table& table, size_t* row) const {
    if (row) *row = npos;
    const size_t idx = table.find(m_field);
    if (idx == npos || table.trackCount() != size()) return false;
    if (row) *row = idx;
    if (!dirty()) return false;
    return table.setPerTrack(idx, values());
}

}
