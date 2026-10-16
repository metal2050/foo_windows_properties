#include "wpe_rg.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace wpe::rg {

namespace {

const char* const kMultipleValuesRG = "\xC2\xAB" "multiple values" "\xC2\xBB";

bool space(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

// pfc::exp_int(10, e): repeated squaring, reciprocal for negative exponents.
double exp10_int(int e) {
    unsigned n = static_cast<unsigned>(e < 0 ? -e : e);
    double v = 1.0, mul = 10.0;
    while (n) {
        if (n & 1) v *= mul;
        n >>= 1;
        if (n) mul *= mul;
    }
    return e < 0 ? 1.0 / v : v;
}

// pfc::float_to_string(out, max, value, precision, sign).
std::string float_text(double val, unsigned precision, bool sign) {
    std::string out;
    if (val < 0) {
        out += '-';
        val = -val;
    } else if (val > 0 && sign) {
        out += '+';
    }
    const int64_t scaled = static_cast<int64_t>(std::floor(val * std::pow(10.0, static_cast<double>(precision)) + 0.5));
    const std::string digits = std::to_string(scaled);
    if (digits.size() <= precision) {
        out += "0.";
        out.append(precision - digits.size(), '0');
        out += digits;
    } else {
        out += digits.substr(0, digits.size() - precision);
        if (precision) out += "." + digits.substr(digits.size() - precision);
    }
    return out;
}

std::string distinct(const std::vector<std::string>& texts) {
    std::vector<std::string> seen;
    for (auto& t : texts)
        if (!t.empty() && std::find(seen.begin(), seen.end(), t) == seen.end()) seen.push_back(t);
    std::string out;
    for (size_t i = 0; i < seen.size(); ++i) out += (i ? "; " : "") + seen[i];
    return out;
}

}

const char* field_label(size_t field) {
    static const char* const labels[FieldCount] = {"Track Gain", "Track Peak", "Album Gain", "Album Peak"};
    return field < FieldCount ? labels[field] : "";
}

std::string format_gain(float gain) { return float_text(gain, 2, true) + " dB"; }

std::string format_peak(float peak) { return float_text(peak, 6, false); }

std::string format(size_t field, const Value& v) {
    if (!v) return {};
    return is_gain(field) ? format_gain(*v) : format_peak(*v);
}

Parse parse(size_t field, std::string_view text, float& out) {
    size_t b = 0, e = text.size();
    while (b < e && space(text[b])) ++b;
    while (e > b && space(text[e - 1])) --e;
    std::string_view s = text.substr(b, e - b);
    if (s.empty()) return Parse::Empty;
    if (is_gain(field) && s.size() >= 2) {
        const std::string_view tail = s.substr(s.size() - 2);
        if ((tail[0] == 'd' || tail[0] == 'D') && (tail[1] == 'b' || tail[1] == 'B')) {
            s.remove_suffix(2);
            while (!s.empty() && space(s.back())) s.remove_suffix(1);
        }
    }
    size_t i = 0;
    bool neg = false;
    if (i < s.size() && (s[i] == '+' || s[i] == '-')) neg = s[i++] == '-';
    // Same arithmetic as pfc::string_to_float, so a typed value equals what foobar2000 would parse.
    int64_t val = 0;
    int div = 0, digits = 0;
    bool dot = false;
    for (; i < s.size(); ++i) {
        const char c = s[i];
        if (c >= '0' && c <= '9') {
            if (digits >= 17) return Parse::Invalid;
            if (val || c != '0') ++digits;
            val = val * 10 + (c - '0');
            if (dot) --div;
        } else if ((c == '.' || c == ',') && !dot) {
            dot = true;
        } else {
            return Parse::Invalid;
        }
    }
    const bool anyDigit = std::any_of(s.begin(), s.end(), [](char c) { return c >= '0' && c <= '9'; });
    if (!anyDigit) return Parse::Invalid;
    if (neg) val = -val;
    if (val != 0)
        while (val % 10 == 0) {
            val /= 10;
            ++div;
        }
    const double d = static_cast<double>(val) * exp10_int(div);
    if (!std::isfinite(d)) return Parse::Invalid;
    if (is_gain(field)) {
        if (std::fabs(d) > 999) return Parse::Invalid;
    } else if (d < 0 || d > 1e6) {
        return Parse::Invalid;
    }
    out = static_cast<float>(d);
    if (out == 0) out = 0;  // no negative zero
    return Parse::Ok;
}

std::string invalid_message(size_t field, std::string_view text) {
    return "\xE2\x80\x9C" + std::string(text) + "\xE2\x80\x9D is not a valid " + (is_gain(field) ? "gain" : "peak") +
           (is_gain(field) ? " (for example -6.54 dB)." : " (for example 0.987654).");
}

bool Plan::empty() const { return fieldCount() == 0; }

size_t Plan::fieldCount() const {
    return static_cast<size_t>(std::count_if(ops.begin(), ops.end(), [](const Op& o) { return o.touched; }));
}

bool apply(const Plan& plan, Info& info) {
    bool changed = false;
    for (size_t f = 0; f < FieldCount; ++f) {
        const Op& op = plan.ops[f];
        if (!op.touched || info.values[f] == op.value) continue;
        info.values[f] = op.value;
        changed = true;
    }
    return changed;
}

void Table::load(std::vector<Info> tracks) {
    m_tracks = std::move(tracks);
    m_staged = {};
}

Value Table::current(size_t field, size_t track) const {
    if (field >= FieldCount || track >= m_tracks.size()) return std::nullopt;
    return m_staged[field].touched ? m_staged[field].value : m_tracks[track].values[field];
}

Display Table::display(size_t field) const {
    Display d;
    if (field >= FieldCount || m_tracks.empty()) return d;
    std::vector<std::string> texts;
    bool same = true;
    for (size_t t = 0; t < m_tracks.size(); ++t) {
        texts.push_back(format(field, current(field, t)));
        if (current(field, t) != current(field, 0)) same = false;
    }
    if (same) {
        d.text = texts.front();
        return d;
    }
    d.mixed = true;
    d.text = std::string(kMultipleValuesRG) + " " + distinct(texts);
    return d;
}

std::string Table::editText(size_t field) const {
    if (field >= FieldCount || m_tracks.empty()) return {};
    std::vector<std::string> texts;
    for (size_t t = 0; t < m_tracks.size(); ++t) texts.push_back(format(field, current(field, t)));
    return distinct(texts);
}

bool Table::stage(size_t field, const Value& v) {
    const Op before = m_staged[field];
    Op op{true, v};
    // A value every track already has is no change at all.
    if (std::all_of(m_tracks.begin(), m_tracks.end(), [&](const Info& i) { return i.values[field] == v; })) op = Op();
    m_staged[field] = op;
    return !(before == op);
}

Edit Table::setText(size_t field, std::string_view text) {
    if (field >= FieldCount || m_tracks.empty()) return Edit::Unchanged;
    if (std::string(text) == editText(field)) return Edit::Unchanged;
    float v = 0;
    switch (parse(field, text, v)) {
    case Parse::Invalid: return Edit::Invalid;
    case Parse::Empty: return stage(field, std::nullopt) ? Edit::Changed : Edit::Unchanged;
    case Parse::Ok: break;
    }
    return stage(field, v) ? Edit::Changed : Edit::Unchanged;
}

bool Table::clear(size_t field) {
    if (field >= FieldCount || m_tracks.empty()) return false;
    return stage(field, std::nullopt);
}

bool Table::dirty() const { return !changedTracks().empty(); }

Plan Table::plan() const {
    Plan p;
    p.ops = m_staged;
    return p;
}

std::vector<size_t> Table::changedTracks() const {
    std::vector<size_t> out;
    const Plan p = plan();
    for (size_t t = 0; t < m_tracks.size(); ++t) {
        Info copy = m_tracks[t];
        if (apply(p, copy)) out.push_back(t);
    }
    return out;
}

std::vector<size_t> Table::changedFields() const {
    std::vector<size_t> out;
    for (size_t f = 0; f < FieldCount; ++f) {
        if (!m_staged[f].touched) continue;
        for (auto& i : m_tracks)
            if (i.values[f] != m_staged[f].value) {
                out.push_back(f);
                break;
            }
    }
    return out;
}

std::string Table::copyText(const std::vector<size_t>& fields) const {
    std::string out;
    for (size_t f : fields) {
        if (f >= FieldCount) continue;
        out += std::string(field_label(f)) + ": " + display(f).text + "\n";
    }
    return out;
}

void Table::discard() { m_staged = {}; }

}
