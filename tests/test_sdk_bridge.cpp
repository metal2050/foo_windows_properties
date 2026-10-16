#include "test.h"
#include "../src/wpe_menu.h"
#include "../src/wpe_sdk.h"

#include <algorithm>
#include <cmath>

#include <cstring>

namespace {

std::string meta(const file_info& fi, const char* name, size_t i = 0) {
    const char* v = fi.meta_get(name, i);
    return v ? v : "<absent>";
}

}

TEST(fields_from_file_info) {
    file_info_impl fi;
    fi.meta_add("Artist", "A");
    fi.meta_add("ARTIST", "B");
    fi.meta_set("title", "T");
    fi.meta_set("MOOD", "m");
    const wpe::TrackFields f = wpe::fields_from_info(fi);
    CHECK_EQ(f.size(), size_t(3));
    CHECK_EQ(f[0].name, std::string("Artist"));
    CHECK_EQ(f[0].values, (wpe::Values{"A", "B"}));
    CHECK_EQ(f[1].name, std::string("title"));
}

TEST(file_info_store_applies_plan) {
    file_info_impl fi;
    fi.meta_add("Artist", "A");
    fi.meta_add("Artist", "B");
    fi.meta_set("title", "T");
    fi.meta_set("Mood", "m");
    fi.meta_set("OLD", "x");
    wpe::Table t;
    t.load({wpe::fields_from_info(fi)}, wpe::Config::defaults());
    CHECK(t.setText(t.find("TITLE"), "New title"));
    CHECK(t.rename(t.find("MOOD"), "feel") == wpe::NameResult::Ok);
    t.remove({t.find("OLD")});
    const size_t r = t.addRow();
    size_t at = wpe::npos;
    CHECK(t.nameNewRow(r, "rating", &at) == wpe::NameResult::Ok);
    CHECK(t.setText(at, "5"));

    wpe::FileInfoStore store(fi);
    const wpe::Plan plan = t.plan();
    CHECK(wpe::apply(plan, 0, store));
    CHECK_EQ(meta(fi, "TITLE"), std::string("New title"));
    CHECK_EQ(meta(fi, "FEEL"), std::string("m"));
    CHECK(fi.meta_find("MOOD") == SIZE_MAX);
    CHECK(fi.meta_find("OLD") == SIZE_MAX);
    CHECK_EQ(meta(fi, "RATING"), std::string("5"));
    CHECK_EQ(fi.meta_get_count_by_name("ARTIST"), size_t(2));
    CHECK_EQ(meta(fi, "ARTIST", 1), std::string("B"));
    CHECK(!wpe::apply(plan, 0, store));
}

TEST(mixed_values_survive_unrelated_edit) {
    file_info_impl a, b;
    a.meta_set("ALBUM", "First");
    a.meta_set("DATE", "1999");
    b.meta_set("ALBUM", "Second");
    b.meta_set("DATE", "1999");
    wpe::Table t;
    t.load({wpe::fields_from_info(a), wpe::fields_from_info(b)}, wpe::Config::defaults());
    CHECK(t.display(t.find("ALBUM")).mixed);
    CHECK(!t.setText(t.find("ALBUM"), t.editText(t.find("ALBUM"))));
    CHECK(t.setText(t.find("DATE"), "2001"));
    const wpe::Plan plan = t.plan();
    wpe::FileInfoStore sa(a), sb(b);
    CHECK(wpe::apply(plan, 0, sa));
    CHECK(wpe::apply(plan, 1, sb));
    CHECK_EQ(meta(a, "ALBUM"), std::string("First"));
    CHECK_EQ(meta(b, "ALBUM"), std::string("Second"));
    CHECK_EQ(meta(a, "DATE"), std::string("2001"));
    CHECK_EQ(meta(b, "DATE"), std::string("2001"));
}

TEST(filter_object_uses_track_index_and_collects_errors) {
    file_info_impl fi;
    fi.meta_set("TITLE", "Old");
    wpe::Table t;
    t.load({wpe::fields_from_info(fi)}, wpe::Config::defaults());
    CHECK(t.setText(t.find("TITLE"), "Fresh"));
    auto job = std::make_shared<wpe::WriteJob>();
    job->plan = t.plan();
    job->trackIndex[nullptr] = 0;
    auto errors = std::make_shared<wpe::WriteErrors>();
    file_info_filter::ptr filter = wpe::make_filter(job, errors);
    CHECK(filter->apply_filter(metadb_handle_ptr(), filestats_invalid, fi));
    CHECK_EQ(meta(fi, "TITLE"), std::string("Fresh"));
    CHECK(!filter->apply_filter(metadb_handle_ptr(), filestats_invalid, fi));

    file_info_filter_v2::ptr v2;
    CHECK(filter->service_query_t(v2));
    if (v2.is_valid()) {
        CHECK(v2->filter_error("file:///x.flac", "Access denied"));
        auto taken = errors->take();
        CHECK_EQ(taken.size(), size_t(1));
        if (!taken.empty()) CHECK_EQ(taken[0].second, std::string("Access denied"));
        CHECK(errors->take().empty());
    }

    auto other = std::make_shared<wpe::WriteJob>();
    other->plan = t.plan();
    file_info_filter::ptr unrelated = wpe::make_filter(other, errors);
    CHECK(!unrelated->apply_filter(metadb_handle_ptr(), filestats_invalid, fi));
}

namespace {

// The children of contextmenu_groups::root that foobar2000 for Mac 2.26 registers, as
// (name, priority, GUID of the group or of item 0, shown in the default context menu).
// Read from the host binary; groups are shown in brackets.
struct RootChild {
    std::string name;
    double priority;
    GUID guid;
    bool shownByDefault;
};

std::vector<RootChild> host_root_children() {
    namespace P = contextmenu_priorities;
    return {
        {"Add to playback queue", P::root_queue, {0x6a8212b3, 0x203a, 0x4b4f, {0xa6, 0x34, 0xbe, 0x09, 0x5f, 0x60, 0x95, 0xce}}, true},
        {"Play", P::root_main, {0xd42f8412, 0x634c, 0x4686, {0xbf, 0xd3, 0x0a, 0x1f, 0xbf, 0xdc, 0xe1, 0xde}}, true},
        {"Open containing folder", P::root_main, {0xefc1e9c8, 0xeeef, 0x427a, {0x8f, 0x42, 0xe5, 0x78, 0x16, 0x05, 0x84, 0x6d}}, true},
        {"[tagging]", P::root_tagging, contextmenu_groups::tagging, true},
        {"[fileoperations]", P::root_fileoperations, contextmenu_groups::fileoperations, true},
        {"[convert]", P::root_convert, contextmenu_groups::convert, true},
        {"[utilities]", P::root_utilities, contextmenu_groups::utilities, true},
        {"[replaygain]", P::root_replaygain, contextmenu_groups::replaygain, true},
        {"[playbackstatistics]", P::root_playbackstatistics, contextmenu_groups::playbackstatistics, true},
        {"Copy name(s)", 0, {0xffe18008, 0xbca2, 0x4b29, {0xab, 0x88, 0x88, 0x16, 0xb4, 0x92, 0xc4, 0x34}}, false},
        {"Properties", wpe::menu::kHostPropertiesPriority, wpe::menu::kHostPropertiesGuid, true},
        {"Play on", 0, {0x231a8a9f, 0x501b, 0x4082, {0x97, 0x8f, 0x23, 0x06, 0x6d, 0x13, 0xd9, 0x00}}, true},
        {"[legacy]", P::root_legacy, contextmenu_groups::legacy, true},
        {"[properties]", P::root_properties, contextmenu_groups::properties, true},
    };
}

std::vector<std::string> shown_order(std::vector<RootChild> children) {
    std::sort(children.begin(), children.end(), [](const RootChild& a, const RootChild& b) {
        return wpe::menu::sorts_before(a.priority, a.guid, b.priority, b.guid);
    });
    std::vector<std::string> out;
    for (auto& c : children)
        if (c.shownByDefault) out.push_back(c.name);
    return out;
}

}

TEST(context_item_shares_parent_with_builtin_properties) {
    CHECK(wpe::menu::context_item_parent() == contextmenu_groups::root);
    CHECK(wpe::menu::context_item_parent() != contextmenu_groups::properties);
    CHECK(wpe::menu::kContextItemGuid ==
          (GUID{0xf17421f8, 0xdcde, 0x4b32, {0x89, 0xa4, 0xbc, 0x47, 0x82, 0x3d, 0x4d, 0xde}}));
}

TEST(context_item_priority_is_just_below_builtin_properties) {
    using namespace wpe::menu;
    CHECK(kContextItemPriority < kHostPropertiesPriority);
    CHECK(std::isnormal(kContextItemPriority));
    // Every host root child sorted before "Properties" stays before this item.
    CHECK(kContextItemPriority > double(contextmenu_priorities::root_playbackstatistics));
    // Whole-number priorities from other components (-1, -10, ...) stay before it too.
    CHECK(kContextItemPriority > -1.0);
    CHECK(sorts_before(kContextItemPriority, kContextItemGuid, kHostPropertiesPriority, kHostPropertiesGuid));
    // At the same priority the GUID decides, and this item's GUID sorts after the built-in one, so
    // an equal priority is not enough.
    CHECK(!sorts_before(kHostPropertiesPriority, kContextItemGuid, kHostPropertiesPriority, kHostPropertiesGuid));
}

TEST(context_item_sits_directly_above_builtin_properties) {
    auto children = host_root_children();
    auto before = shown_order(children);
    CHECK_EQ(before.back(), std::string("[properties]"));

    children.push_back({"Properties (Windows style)", wpe::menu::kContextItemPriority, wpe::menu::kContextItemGuid, true});
    auto order = shown_order(children);
    auto at = std::find(order.begin(), order.end(), std::string("Properties (Windows style)"));
    CHECK(at != order.end());
    CHECK(at + 1 != order.end());
    if (at != order.end() && at + 1 != order.end()) {
        CHECK_EQ(*(at + 1), std::string("Properties"));
        CHECK_EQ(*(at - 1), std::string("[playbackstatistics]"));
    }

    // The old placement (inside the properties group, priority 100 under root) came after "Play on"
    // and the legacy group, behind a separator.
    auto oldAt = std::find(before.begin(), before.end(), std::string("Properties"));
    CHECK_EQ(*(oldAt + 1), std::string("Play on"));
}

TEST(art_types_map_to_album_art_ids_in_row_order) {
    CHECK_EQ(album_art_ids::num_types(), size_t(wpe::art::TypeCount));
    CHECK(wpe::art_guid(wpe::art::FrontCover) == album_art_ids::cover_front);
    CHECK(wpe::art_guid(wpe::art::BackCover) == album_art_ids::cover_back);
    CHECK(wpe::art_guid(wpe::art::Artist) == album_art_ids::artist);
    CHECK(wpe::art_guid(wpe::art::Disc) == album_art_ids::disc);
    CHECK(wpe::art_guid(wpe::art::Icon) == album_art_ids::icon);
    CHECK(wpe::art_guid(wpe::art::TypeCount) == pfc::guid_null);
    // The row labels are the SDK's own capitalized names.
    for (size_t t = 0; t < wpe::art::TypeCount; ++t)
        CHECK_EQ(std::string(wpe::art::type_label(t)), std::string(album_art_ids::query_capitalized_name(t)));
}

TEST(art_data_round_trips_through_album_art_data) {
    const wpe::art::Picture p = wpe::art::make_picture(wpe::art::Bytes{0x89, 'P', 'N', 'G', 1, 2, 3});
    album_art_data::ptr d = wpe::data_from(p);
    CHECK(d.is_valid());
    if (d.is_valid()) {
        CHECK_EQ(d->size(), p->size());
        CHECK(std::memcmp(d->data(), p->data(), p->size()) == 0);
        CHECK(wpe::art::same(wpe::picture_from(d), p));
    }
    CHECK(wpe::data_from(nullptr).is_empty());
    CHECK(!wpe::picture_from(album_art_data::ptr()));
}

TEST(set_meta_replaces_tags_and_keeps_technical_info) {
    file_info_impl fi;
    fi.meta_set("TITLE", "old");
    fi.meta_set("MOOD", "calm");
    fi.info_set("codec", "FLAC");
    fi.set_length(12.5);
    wpe::set_meta(fi, {{"ARTIST", {"A", "B"}}, {"TITLE", {"new"}}});
    CHECK_EQ(meta(fi, "TITLE"), std::string("new"));
    CHECK_EQ(fi.meta_get_count_by_name("ARTIST"), size_t(2));
    CHECK(fi.meta_find("MOOD") == SIZE_MAX);
    CHECK_EQ(std::string(fi.info_get("codec")), std::string("FLAC"));
    CHECK(fi.get_length() == 12.5);
}

TEST(replaygain_info_round_trip_and_filter) {
    file_info_impl fi;
    fi.meta_set("TITLE", "T");
    replaygain_info rgi;
    rgi.m_track_gain = -6.54f;
    rgi.m_track_peak = 0.987654f;
    rgi.m_album_gain = -7.0f;
    fi.set_replaygain(rgi);
    const wpe::rg::Info loaded = wpe::rg_from(fi.get_replaygain());
    CHECK(loaded.values[wpe::rg::TrackGain] == wpe::rg::Value(-6.54f));
    CHECK(loaded.values[wpe::rg::TrackPeak] == wpe::rg::Value(0.987654f));
    CHECK(loaded.values[wpe::rg::AlbumGain] == wpe::rg::Value(-7.0f));
    CHECK(!loaded.values[wpe::rg::AlbumPeak]);
    // Formatting matches the SDK's own replaygain_info::g_format_gain / g_format_peak.
    replaygain_info::t_text_buffer buf;
    for (float g : {-6.54f, 1.2f, 0.0f, -0.004f, 12.345f, -99.999f}) {
        replaygain_info::g_format_gain(g, buf);
        CHECK_EQ(wpe::rg::format_gain(g), std::string(buf));
    }
    for (float pk : {0.987654f, 1.0f, 0.0f, 1.2345678f, 0.0000005f}) {
        replaygain_info::g_format_peak(pk, buf);
        CHECK_EQ(wpe::rg::format_peak(pk), std::string(buf));
    }
    // Parsing matches pfc::string_to_float, so retyped values compare equal.
    for (const char* t : {"-6.54", "0.987654", "1.2", "-12.3456", "0.2", "0.200000", "+3,25"}) {
        float v = 0;
        CHECK(wpe::rg::parse(wpe::rg::TrackPeak, t[0] == '-' ? t + 1 : t, v) == wpe::rg::Parse::Ok);
        CHECK_EQ(v, (float)pfc::string_to_float(t[0] == '-' ? t + 1 : t));
    }

    wpe::rg::Table t;
    t.load({loaded});
    CHECK(t.setText(wpe::rg::AlbumGain, "-8 dB") == wpe::rg::Edit::Changed);
    CHECK(t.setText(wpe::rg::TrackPeak, "") == wpe::rg::Edit::Changed);
    auto job = std::make_shared<wpe::WriteJob>();
    job->plan.rg = t.plan();  // ReplayGain only: no tag ops
    job->trackIndex[nullptr] = 0;
    auto errors = std::make_shared<wpe::WriteErrors>();
    file_info_filter::ptr filter = wpe::make_filter(job, errors);
    CHECK(filter->apply_filter(metadb_handle_ptr(), filestats_invalid, fi));
    const replaygain_info after = fi.get_replaygain();
    CHECK(after.m_album_gain == -8.0f);
    CHECK(!after.is_track_peak_present());
    CHECK(after.m_track_gain == -6.54f);  // untouched fields keep the file's values
    CHECK(!after.is_album_peak_present());
    CHECK_EQ(std::string(fi.meta_get("TITLE", 0)), std::string("T"));
    CHECK(!filter->apply_filter(metadb_handle_ptr(), filestats_invalid, fi));  // already applied
}

namespace {

// One provider per interface revision; each records which entry point the helper used.
std::vector<std::string> g_calls;

class provider_v1 : public track_property_provider {
public:
    void enumerate_properties(trackListRef, track_property_callback& out) override {
        g_calls.push_back("v1");
        out.set_property("Old", 0, "From v1", "1");
    }
    bool is_our_tech_info(const char* name) override { return std::strcmp(name, "v1_field") == 0; }
};

class provider_v2 : public track_property_provider_v2 {
public:
    void enumerate_properties(trackListRef, track_property_callback&) override { g_calls.push_back("v2 via v1"); }
    void enumerate_properties_v2(trackListRef, track_property_callback_v2& out) override {
        g_calls.push_back("v2");
        if (out.is_group_wanted("General")) out.set_property("General", 5, "From v2", "2");
    }
    bool is_our_tech_info(const char*) override { return false; }
};

class provider_v3 : public track_property_provider_v3 {
public:
    void enumerate_properties_v3(trackListRef, track_property_provider_v3_info_source&, track_property_callback_v2& out) override {
        g_calls.push_back("v3");
        out.set_property("Location", 1, "From v3", "3");
    }
    bool is_our_tech_info(const char*) override { return false; }
};

class provider_v4 : public track_property_provider_v4 {
public:
    void enumerate_properties_v4(trackListRef, track_property_provider_v3_info_source&, track_property_callback_v2& out,
                                 abort_callback& abort) override {
        g_calls.push_back("v4");
        abort.check();
        out.set_property("General", 1, "From v4", "4");
    }
    bool is_our_tech_info(const char* name) override { return std::strcmp(name, "v4_field") == 0; }
};

class provider_v5 : public track_property_provider_v5 {
public:
    void enumerate_properties_v5(trackListRef, track_property_provider_v5_info_source&, track_property_callback_v2& out,
                                 abort_callback&) override {
        g_calls.push_back("v5");
        out.set_property("Playback statistics", 0, "From v5", "5");
    }
    bool is_our_tech_info(const char*) override { return false; }
};

class provider_failing : public track_property_provider_v4 {
public:
    void enumerate_properties_v4(trackListRef, track_property_provider_v3_info_source&, track_property_callback_v2&,
                                 abort_callback&) override {
        g_calls.push_back("failing");
        throw std::runtime_error("broken provider");
    }
    bool is_our_tech_info(const char*) override { return false; }
};

// abort_callback_impl needs the host; this one is simply always aborted.
class always_aborted : public abort_callback {
public:
    bool is_aborting() const override { return true; }
    abort_callback_event get_abort_event() const override { return abort_callback_event(); }
};

class empty_v5_source : public track_property_provider_v5_info_source {
public:
    metadb_v2_rec_t get_info(size_t) override { return metadb_v2_rec_t(); }
};

}

TEST(details_use_the_newest_provider_interface_and_tech_claims) {
    g_calls.clear();
    std::vector<track_property_provider::ptr> all = {
        fb2k::service_new<provider_v1>(), fb2k::service_new<provider_v2>(), fb2k::service_new<provider_v3>(),
        fb2k::service_new<provider_failing>(), fb2k::service_new<provider_v4>(), fb2k::service_new<provider_v5>()};
    metadb_handle_list none;
    empty_v5_source source;
    std::vector<wpe::details::Entry> entries;
    wpe::enumerate_details(all, none, &source, fb2k::noAbort, entries);
    CHECK_EQ(g_calls, (std::vector<std::string>{"v1", "v2", "v3", "failing", "v4", "v5"}));
    std::vector<std::string> lines;
    for (auto& l : wpe::details::group_lines(entries)) lines.push_back(l.header ? "[" + l.name + "]" : l.name + "=" + l.value);
    CHECK_EQ(lines, (std::vector<std::string>{"[Location]", "From v3=3", "[General]", "From v4=4", "From v2=2", "[Old]",
                                              "From v1=1", "[Playback statistics]", "From v5=5"}));

    // The window's split: v4 and later may run off the main thread.
    wpe::DetailsProviders split;
    for (auto& p : all) {
        track_property_provider_v4::ptr v4;
        (v4 &= p) ? split.anyThread.push_back(p) : split.mainThread.push_back(p);
    }
    CHECK_EQ(split.mainThread.size(), size_t(3));
    CHECK_EQ(split.anyThread.size(), size_t(3));
    CHECK(wpe::tech_claimed(split, "v1_field"));
    CHECK(wpe::tech_claimed(split, "v4_field"));
    CHECK(!wpe::tech_claimed(split, "bitrate"));

    // An abort stops the enumeration.
    always_aborted aborted;
    entries.clear();
    bool threw = false;
    try {
        wpe::enumerate_details(split.anyThread, none, &source, aborted, entries);
    } catch (exception_aborted const&) {
        threw = true;
    }
    CHECK(threw);
}

int main() { return wpetest::run_all(); }
