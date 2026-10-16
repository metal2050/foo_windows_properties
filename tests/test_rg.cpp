#include "test.h"
#include "../src/wpe_model.h"
#include "../src/wpe_rg.h"

using namespace wpe::rg;

namespace {

const std::string kMV = std::string("\xC2\xAB" "multiple values" "\xC2\xBB") + " ";

Info info(Value tg, Value tp = std::nullopt, Value ag = std::nullopt, Value ap = std::nullopt) {
    Info i;
    i.values = {tg, tp, ag, ap};
    return i;
}

float parsed(size_t field, const char* text) {
    float v = -12345;
    CHECK(parse(field, text, v) == Parse::Ok);
    return v;
}

bool invalid(size_t field, const char* text) {
    float v = 0;
    return parse(field, text, v) == Parse::Invalid;
}

}

TEST(rg_labels_in_windows_order) {
    CHECK_EQ(std::string(field_label(TrackGain)), std::string("Track Gain"));
    CHECK_EQ(std::string(field_label(TrackPeak)), std::string("Track Peak"));
    CHECK_EQ(std::string(field_label(AlbumGain)), std::string("Album Gain"));
    CHECK_EQ(std::string(field_label(AlbumPeak)), std::string("Album Peak"));
    CHECK(is_gain(TrackGain) && is_gain(AlbumGain) && !is_gain(TrackPeak) && !is_gain(AlbumPeak));
}

TEST(rg_formats_like_foobar2000) {
    CHECK_EQ(format_gain(-6.54f), std::string("-6.54 dB"));
    CHECK_EQ(format_gain(1.2f), std::string("+1.20 dB"));
    CHECK_EQ(format_gain(0.0f), std::string("0.00 dB"));
    CHECK_EQ(format_gain(-0.001f), std::string("-0.00 dB"));  // pfc::float_to_string keeps the sign
    CHECK_EQ(format_gain(-12.345678f), std::string("-12.35 dB"));
    CHECK_EQ(format_peak(0.987654f), std::string("0.987654"));
    CHECK_EQ(format_peak(1.0f), std::string("1.000000"));
    CHECK_EQ(format_peak(0.0000004f), std::string("0.000000"));
    CHECK_EQ(format_peak(1.2345678f), std::string("1.234568"));
    CHECK_EQ(format(TrackGain, std::nullopt), std::string(""));
    CHECK_EQ(format(AlbumPeak, 0.5f), std::string("0.500000"));
}

TEST(rg_parses_typed_values) {
    CHECK_EQ(parsed(TrackGain, "+1.2"), 1.2f);
    CHECK_EQ(parsed(TrackGain, "-6.54 dB"), -6.54f);
    CHECK_EQ(parsed(TrackGain, "-6,54"), -6.54f);
    CHECK_EQ(parsed(AlbumGain, "  -6.54dB "), -6.54f);
    CHECK_EQ(parsed(AlbumGain, "-6.54 DB"), -6.54f);
    CHECK_EQ(parsed(TrackGain, "3"), 3.0f);
    CHECK_EQ(parsed(TrackGain, ".5"), 0.5f);
    CHECK_EQ(parsed(TrackGain, "-0"), 0.0f);
    CHECK_EQ(parsed(TrackPeak, "0.987654"), 0.987654f);
    CHECK_EQ(parsed(AlbumPeak, "1,5"), 1.5f);
    // The same float foobar2000's own parser produces (0.2 and 0.200000 alike).
    CHECK_EQ(parsed(TrackPeak, "0.2"), parsed(TrackPeak, "0.200000"));
    float v = 0;
    CHECK(parse(TrackGain, "", v) == Parse::Empty);
    CHECK(parse(TrackPeak, "   ", v) == Parse::Empty);
    CHECK(invalid(TrackGain, "loud"));
    CHECK(invalid(TrackGain, "1.2.3"));
    CHECK(invalid(TrackGain, "dB"));
    CHECK(invalid(TrackGain, "-"));
    CHECK(invalid(TrackGain, "1e5"));
    CHECK(invalid(TrackGain, "1000"));
    CHECK(invalid(TrackPeak, "-0.5"));
    CHECK(invalid(TrackPeak, "0.9 dB"));  // dB is for gains only
    CHECK(invalid(AlbumPeak, "abc"));
    CHECK(invalid_message(TrackGain, "loud").find("not a valid gain") != std::string::npos);
    CHECK(invalid_message(TrackPeak, "x").find("not a valid peak") != std::string::npos);
}

TEST(rg_merges_tracks_into_rows) {
    Table t;
    t.load({info(-6.54f, 0.98f, -7.0f), info(-6.54f, 0.5f, -7.0f), info(-6.54f, std::nullopt, -7.0f)});
    CHECK_EQ(t.display(TrackGain).text, std::string("-6.54 dB"));
    CHECK(!t.display(TrackGain).mixed);
    CHECK_EQ(t.display(AlbumGain).text, std::string("-7.00 dB"));
    CHECK(t.display(TrackPeak).mixed);
    CHECK_EQ(t.display(TrackPeak).text, kMV + "0.980000; 0.500000");
    CHECK_EQ(t.editText(TrackPeak), std::string("0.980000; 0.500000"));
    CHECK_EQ(t.display(AlbumPeak).text, std::string(""));  // not set anywhere
    CHECK(!t.display(AlbumPeak).mixed);
    CHECK(!t.dirty());
    CHECK(t.plan().empty());
}

TEST(rg_editing_stages_values_for_all_tracks) {
    Table t;
    t.load({info(-6.54f, 0.98f), info(-3.0f, 0.5f)});
    // Leaving «multiple values» as it was keeps each track's own value.
    CHECK(t.setText(TrackGain, t.editText(TrackGain)) == Edit::Unchanged);
    CHECK(!t.dirty());
    CHECK(t.setText(TrackGain, "-5 dB") == Edit::Changed);
    CHECK_EQ(t.display(TrackGain).text, std::string("-5.00 dB"));
    CHECK(t.dirty());
    CHECK_EQ(t.changedTracks(), (std::vector<size_t>{0, 1}));
    CHECK_EQ(t.changedFields(), (std::vector<size_t>{TrackGain}));
    // Invalid text changes nothing.
    CHECK(t.setText(TrackPeak, "0.9x") == Edit::Invalid);
    CHECK(t.display(TrackPeak).mixed);
    // Clearing removes the field everywhere.
    CHECK(t.setText(TrackPeak, "") == Edit::Changed);
    CHECK_EQ(t.display(TrackPeak).text, std::string(""));
    const Plan p = t.plan();
    CHECK_EQ(p.fieldCount(), size_t(2));
    CHECK(p.ops[TrackGain].touched && p.ops[TrackGain].value == Value(-5.0f));
    CHECK(p.ops[TrackPeak].touched && !p.ops[TrackPeak].value);
    CHECK(!p.ops[AlbumGain].touched);
}

TEST(rg_retyping_the_current_value_is_no_change) {
    Table t;
    t.load({info(-6.54f), info(-6.54f)});
    CHECK(t.setText(TrackGain, "-6.54") == Edit::Unchanged);
    CHECK(t.setText(TrackGain, "-6,540 dB") == Edit::Unchanged);
    CHECK(!t.dirty());
    CHECK(t.setText(TrackGain, "-6") == Edit::Changed);
    CHECK(t.setText(TrackGain, "-6.54") == Edit::Changed);  // back to what the files have
    CHECK(!t.dirty());
    CHECK(t.plan().empty());
    CHECK(!t.clear(AlbumGain));  // already not set
    CHECK(!t.dirty());
}

TEST(rg_apply_touches_only_staged_fields) {
    Table t;
    t.load({info(-6.54f, 0.98f, -7.0f, 0.99f), info(-3.0f, 0.5f, -7.0f, 0.99f)});
    CHECK(t.setText(AlbumGain, "-8") == Edit::Changed);
    const Plan p = t.plan();
    Info a = t.loaded(0), b = t.loaded(1);
    CHECK(apply(p, a));
    CHECK(apply(p, b));
    CHECK(a == info(-6.54f, 0.98f, -8.0f, 0.99f));
    CHECK(b == info(-3.0f, 0.5f, -8.0f, 0.99f));
    CHECK(!apply(p, a));  // idempotent
    t.discard();
    CHECK(!t.dirty());
    CHECK_EQ(t.display(AlbumGain).text, std::string("-7.00 dB"));
}

TEST(rg_changed_tracks_skip_tracks_that_already_match) {
    Table t;
    t.load({info(-6.0f), info(std::nullopt), info(-6.0f)});
    CHECK(t.setText(TrackGain, "-6") == Edit::Changed);
    CHECK_EQ(t.changedTracks(), (std::vector<size_t>{1}));
    CHECK_EQ(t.copyText({TrackGain, AlbumPeak}), std::string("Track Gain: -6.00 dB\nAlbum Peak: \n"));
}

TEST(rg_plan_travels_with_the_tag_plan) {
    wpe::Plan p;
    CHECK(p.empty());
    p.rg.ops[TrackGain] = Op{true, -1.0f};
    CHECK(!p.empty());
    CHECK(p.ops.empty());
}
