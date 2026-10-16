#include "test.h"
#include "../src/wpe_details.h"

using namespace wpe::details;

namespace {

std::vector<std::string> rows(const std::vector<Line>& lines) {
    std::vector<std::string> out;
    for (auto& l : lines) out.push_back(l.header ? "[" + l.name + "]" : l.name + "=" + l.value);
    return out;
}

}

TEST(details_groups_standard_sections_first_then_by_name) {
    std::vector<Entry> e = {
        {"Playback statistics", 0, "Play count", "3"},
        {"General", 1, "Items selected", "1"},
        {"Location", 1, "File name", "a.flac"},
        {"ReplayGain", 0, "Track gain", "-6.54 dB"},
        {"Another provider", 0, "Thing", "x"},
        {"General", 2, "Duration", "3:00"},
        {"Location", 0, "File path", "/m/a.flac"},
    };
    CHECK_EQ(rows(group_lines(e)), (std::vector<std::string>{
                                       "[Location]", "File path=/m/a.flac", "File name=a.flac",
                                       "[General]", "Items selected=1", "Duration=3:00",
                                       "[ReplayGain]", "Track gain=-6.54 dB",
                                       "[Another provider]", "Thing=x",
                                       "[Playback statistics]", "Play count=3",
                                   }));
}

TEST(details_equal_priorities_sort_by_name_and_duplicates_replace) {
    std::vector<Entry> e = {
        {"General", 0, "zeta", "1"},
        {"General", 0, "Alpha", "2"},
        {"General", 0, "beta", "3"},
        {"General", 0, "Alpha", "4"},  // same group and name: the later call wins
        {"General", 0, "", "dropped"},
        {"general", 0, "Other case", "own group"},
    };
    CHECK_EQ(rows(group_lines(e)), (std::vector<std::string>{"[General]", "Alpha=4", "beta=3", "zeta=1", "[general]",
                                                              "Other case=own group"}));
    CHECK(group_lines({}).empty());
}

TEST(details_copy_text_is_name_colon_value) {
    const auto lines = group_lines({{"Location", 0, "File name", "a.flac"}, {"General", 0, "Channels", "2"}});
    CHECK_EQ(copy_text(lines, {0, 1, 2, 3}), std::string("File name: a.flac\nChannels: 2\n"));
    CHECK_EQ(copy_text(lines, {3}), std::string("Channels: 2\n"));
    CHECK_EQ(copy_text(lines, {0, 2, 99}), std::string(""));  // headers and out-of-range rows are skipped
}

TEST(details_tech_labels_and_merge) {
    CHECK_EQ(tech_label("MP3_STEREO_MODE"), std::string("Mp3 stereo mode"));
    CHECK_EQ(tech_label("encoder"), std::string("Encoder"));
    const auto merged = merge_tech({{{"codec", "FLAC"}, {"FOO_BAR", "1"}}, {{"CODEC", "FLAC"}}, {{"foo_bar", "2"}}});
    CHECK_EQ(merged.size(), size_t(2));
    CHECK_EQ(merged[0].name, std::string("codec"));
    CHECK_EQ(merged[0].values, (std::vector<std::string>{"FLAC", "FLAC"}));
    CHECK_EQ(merged[1].values, (std::vector<std::string>{"1", "2"}));
}

TEST(details_unclaimed_tech_info_goes_to_general) {
    std::vector<Entry> e = {{"General", 0, "Codec", "FLAC"}, {"General", 1, "Mp3 stereo mode", "joint stereo"}};
    const auto fields = merge_tech({{{"codec", "FLAC"}, {"MP3_STEREO_MODE", "joint stereo"}, {"bitrate", "900"},
                                     {"MY_FIELD", "a"}, {"OTHER", "x"}},
                                    {{"MY_FIELD", "b"}, {"MY_FIELD", "a"}}});
    // bitrate is claimed by a provider (is_our_tech_info); codec and MP3_STEREO_MODE are already listed.
    const size_t added = add_unclaimed(e, fields, [](const std::string& n) { return n == "bitrate"; });
    CHECK_EQ(added, size_t(2));
    CHECK_EQ(rows(group_lines(e)), (std::vector<std::string>{"[General]", "Codec=FLAC", "Mp3 stereo mode=joint stereo",
                                                              "My field=a; b", "Other=x"}));
    CHECK_EQ(add_unclaimed(e, fields, [](const std::string& n) { return n == "bitrate"; }), size_t(0));  // nothing twice
    CHECK_EQ(add_unclaimed(e, fields, nullptr), size_t(1));  // nobody claims bitrate now
}
