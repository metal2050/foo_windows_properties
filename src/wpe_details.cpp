#include "wpe_details.h"

#include "wpe_model.h"

#include <algorithm>
#include <map>

namespace wpe::details {

const char* const kStandardGroups[3] = {"Location", "General", "ReplayGain"};
const char* const kGeneralGroup = "General";

namespace {

// Rank of a group: standard groups by their position, others after them.
size_t group_rank(const std::string& g) {
    for (size_t i = 0; i < std::size(kStandardGroups); ++i)
        if (g == kStandardGroups[i]) return i;
    return std::size(kStandardGroups);
}

// Compares names the way a person reads them: letters case-insensitively, then exact bytes.
bool name_less(const std::string& a, const std::string& b) {
    const int c = icompare(a, b);
    return c != 0 ? c < 0 : a < b;
}

// Lowercase letters and digits only: "MP3_STEREO_MODE", "Mp3 stereo mode" and "mp3stereomode" match.
std::string fold(std::string_view s) {
    std::string out;
    for (char c : s) {
        if (c >= 'A' && c <= 'Z') out += static_cast<char>(c - 'A' + 'a');
        else if (c != ' ' && c != '_' && c != '-' && c != '\t') out += c;
    }
    return out;
}

}

std::vector<Line> group_lines(const std::vector<Entry>& entries) {
    // group -> name -> (priority, value, insertion order)
    struct Item {
        double priority;
        std::string name;
        std::string value;
    };
    std::vector<std::string> groups;
    std::map<std::string, std::vector<Item>> items;
    for (auto& e : entries) {
        if (e.name.empty()) continue;
        auto& list = items[e.group];
        if (list.empty() && std::find(groups.begin(), groups.end(), e.group) == groups.end()) groups.push_back(e.group);
        auto it = std::find_if(list.begin(), list.end(), [&](const Item& i) { return i.name == e.name; });
        if (it != list.end()) *it = Item{e.priority, e.name, e.value};
        else list.push_back(Item{e.priority, e.name, e.value});
    }
    std::stable_sort(groups.begin(), groups.end(), [](const std::string& a, const std::string& b) {
        const size_t ra = group_rank(a), rb = group_rank(b);
        if (ra != rb) return ra < rb;
        return ra == std::size(kStandardGroups) && name_less(a, b);
    });
    std::vector<Line> out;
    for (auto& g : groups) {
        auto& list = items[g];
        std::stable_sort(list.begin(), list.end(), [](const Item& a, const Item& b) {
            if (a.priority != b.priority) return a.priority < b.priority;
            return name_less(a.name, b.name);
        });
        out.push_back(Line{true, g, g, {}});
        for (auto& i : list) out.push_back(Line{false, g, i.name, i.value});
    }
    return out;
}

std::string copy_text(const std::vector<Line>& lines, const std::vector<size_t>& rows) {
    std::string out;
    for (size_t r : rows) {
        if (r >= lines.size() || lines[r].header) continue;
        out += lines[r].name + ": " + lines[r].value + "\n";
    }
    return out;
}

std::vector<TechField> merge_tech(const std::vector<std::vector<std::pair<std::string, std::string>>>& tracks) {
    std::vector<TechField> out;
    for (auto& track : tracks) {
        for (auto& [name, value] : track) {
            auto it = std::find_if(out.begin(), out.end(), [&](const TechField& f) { return iequals(f.name, name); });
            if (it == out.end()) {
                out.push_back(TechField{name, {}});
                it = out.end() - 1;
            }
            it->values.push_back(value);
        }
    }
    return out;
}

std::string tech_label(std::string_view field) {
    std::string out;
    bool first = true;
    for (char c : field) {
        if (c == '_') c = ' ';
        if (first && c >= 'a' && c <= 'z') c = static_cast<char>(c - 'a' + 'A');
        else if (!first && c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
        if (c != ' ') first = false;
        out += c;
    }
    return out;
}

size_t add_unclaimed(std::vector<Entry>& entries, const std::vector<TechField>& fields,
                     const std::function<bool(const std::string&)>& claimed) {
    std::vector<std::string> listed;
    for (auto& e : entries) listed.push_back(fold(e.name));
    size_t added = 0;
    for (auto& f : fields) {
        if (f.name.empty() || (claimed && claimed(f.name))) continue;
        const std::string key = fold(f.name);
        if (std::find(listed.begin(), listed.end(), key) != listed.end()) continue;
        std::vector<std::string> distinct;
        for (auto& v : f.values)
            if (std::find(distinct.begin(), distinct.end(), v) == distinct.end()) distinct.push_back(v);
        std::string value;
        for (size_t i = 0; i < distinct.size(); ++i) value += (i ? "; " : "") + distinct[i];
        // After the provider's own lines (their priorities are small), sorted by name among themselves.
        entries.push_back(Entry{kGeneralGroup, 1e9, tech_label(f.name), value});
        listed.push_back(key);
        ++added;
    }
    return added;
}

}
